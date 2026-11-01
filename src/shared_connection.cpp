#include "../inst/include/duckdb_shared_connection.h"

#include "rapi.hpp"
#include "signal.hpp"

#include <algorithm>
#include <map>
#include <mutex>
#include <vector>

using namespace duckdb;

namespace duckdb {

struct SharedConnectionExport {
	duckdb_shared_connection api;
	ConnWrapper *connection;
	std::shared_ptr<DBWrapper> database;
	SEXP connection_ref;
	SEXP environment;
	SEXP retained;
	std::string abi = SharedConnectionABI();
	std::string error;
	unique_ptr<ScopedInterruptHandler> operation;
	unique_ptr<RCallbackScope> callbacks;
	bool closing = false;
	std::recursive_mutex subscribers_lock;
	uint64_t next_subscription = 0;
	struct Subscriber {
		duckdb_shared_connection_close_callback callback;
		void *consumer;
	};
	std::map<uint64_t, Subscriber> subscribers;

	SharedConnectionExport(ConnWrapper *connection_p, SEXP connection_ref_p, SEXP environment_p, SEXP retained_p)
	    : connection(connection_p), database(connection_p->db), connection_ref(connection_ref_p),
	      environment(environment_p), retained(retained_p) {
		api = {DUCKDB_SHARED_CONNECTION_VERSION,
		       sizeof(duckdb_shared_connection),
		       abi.c_str(),
		       this,
		       GetConnection,
		       GetDatabase,
		       IsValid,
		       Close,
		       BeginOperation,
		       EndOperation,
		       SubscribeClose,
		       UnsubscribeClose};
	}

	static SharedConnectionExport &Get(void *context) {
		return *static_cast<SharedConnectionExport *>(context);
	}

	static void *GetConnection(void *context) {
		auto &self = Get(context);
		return IsValid(context) ? self.connection->conn.get() : nullptr;
	}

	static void *GetDatabase(void *context) {
		auto &self = Get(context);
		return IsValid(context) ? self.database->db.get() : nullptr;
	}

	static int IsValid(void *context) {
		auto &self = Get(context);
		return OnRThread() && self.connection && self.connection->conn && !self.closing;
	}

	template <class FUNCTION>
	static const char *Try(void *context, FUNCTION function) {
		auto &self = Get(context);
		try {
			if (!OnRThread()) {
				throw std::runtime_error("Shared R connections must be used on R's owning thread");
			}
			if (!self.connection || !self.connection->conn || self.closing) {
				throw std::runtime_error("Shared R connection is closed");
			}
			function(self);
			return nullptr;
		} catch (const std::exception &error) {
			self.error = error.what();
		} catch (...) {
			self.error = "Shared R connection operation failed";
		}
		return self.error.c_str();
	}

	static const char *Close(void *context) {
		return Try(context, [](SharedConnectionExport &self) {
			auto connection = self.connection;
			CloseSharedConnection(*connection);
			R_ClearExternalPtr(self.connection_ref);
			delete connection;
		});
	}

	static const char *BeginOperation(void *context) {
		return Try(context, [](SharedConnectionExport &self) {
			if (self.operation || self.connection->db->env != R_NilValue) {
				throw std::runtime_error("Shared R connection is already executing an operation");
			}
			RCallbackScope::Drain();
			// Install the same reentrancy and interrupt boundary as an R query.
			// EndOpenResults runs before the foreign engine takes its context lock.
			auto operation = make_uniq<ScopedInterruptHandler>(self.connection->conn->context);
			EndOpenResults(*self.connection->conn->context);
			// A Python UDF can call back into R while the engine holds its lock.
			// Its GC and reentrant calls must defer native handle destruction.
			auto callbacks = make_uniq<RCallbackScope>();
			self.connection->db->env = self.environment;
			self.connection->db->registered_dfs = self.retained;
			self.operation = std::move(operation);
			self.callbacks = std::move(callbacks);
		});
	}

	static void EndOperation(void *context) {
		auto &self = Get(context);
		if (self.operation) {
			self.connection->db->env = R_NilValue;
			self.connection->db->registered_dfs = R_NilValue;
			// Lazy native relations own their scanned frames through dependencies.
			// This list protects only the current bind, not every past query.
			SETCDR(self.retained, R_NilValue);
			self.callbacks.reset();
			self.operation.reset();
		}
	}

	static const char *SubscribeClose(void *context, duckdb_shared_connection_close_callback callback, void *consumer,
	                                  uint64_t *subscription) {
		return Try(context, [&](SharedConnectionExport &self) {
			std::lock_guard<std::recursive_mutex> lock(self.subscribers_lock);
			*subscription = ++self.next_subscription;
			self.subscribers.emplace(*subscription, Subscriber {callback, consumer});
		});
	}

	static void UnsubscribeClose(void *context, uint64_t subscription) {
		auto &self = Get(context);
		// Python may collect a view on another thread. Removing its callback
		// touches native bookkeeping only and waits for an active notification.
		std::lock_guard<std::recursive_mutex> lock(self.subscribers_lock);
		self.subscribers.erase(subscription);
	}

	void NotifyClose() {
		std::lock_guard<std::recursive_mutex> lock(subscribers_lock);
		std::vector<uint64_t> ids;
		for (auto &entry : subscribers) {
			ids.push_back(entry.first);
		}
		// A notification can release another view on this thread. Recheck each
		// subscription after that callback rather than retaining stale consumers.
		for (auto id : ids) {
			auto entry = subscribers.find(id);
			if (entry != subscribers.end()) {
				if (auto error = entry->second.callback(entry->second.consumer)) {
					throw std::runtime_error(error);
				}
			}
		}
	}
};

void CloseSharedConnection(ConnWrapper &connection) {
	std::vector<std::shared_ptr<SharedConnectionExport>> exports;
	for (auto &entry : connection.shared_exports) {
		if (auto exported = entry.lock()) {
			exports.push_back(std::move(exported));
		}
	}
	if (exports.empty()) {
		return;
	}
	if (!OnRThread() || ScopedInterruptHandler::IsActiveFor(*connection.conn->context)) {
		throw std::runtime_error("Cannot close a shared R connection while an operation is running");
	}
	for (auto &exported : exports) {
		if (exported->closing) {
			throw std::runtime_error("Shared R connection is already closing");
		}
	}
	for (auto &exported : exports) {
		exported->closing = true;
	}
	try {
		for (auto &exported : exports) {
			exported->NotifyClose();
		}
		// R streams can retain the client context after disconnection too.
		// End their queries and release locks before deleting the connection.
		ScopedInterruptHandler cleanup(connection.conn->context);
		EndOpenResults(*connection.conn->context);
		if (!connection.conn->IsAutoCommit()) {
			connection.conn->Rollback();
		}
		cleanup.HandleInterrupt();
	} catch (...) {
		for (auto &exported : exports) {
			exported->closing = false;
		}
		throw;
	}
	for (auto &exported : exports) {
		exported->connection = nullptr;
	}
}

} // namespace duckdb

[[cpp11::register]] cpp11::list rapi_export_connection(SEXP connection, SEXP environment) {
	auto reference = R_do_slot(connection, RStrings::get().conn_ref_sym);
	conn_eptr_t native(reference);
	if (!native || !native->conn) {
		cpp11::stop("Cannot export a closed connection");
	}
	cpp11::sexp retained(Rf_cons(R_NilValue, R_NilValue));
	cpp11::writable::list protection = {connection, environment, retained};
	auto exported = std::make_shared<SharedConnectionExport>(native.get(), reference, environment, retained);
	cpp11::external_pointer<std::shared_ptr<SharedConnectionExport>> owner(
	    new std::shared_ptr<SharedConnectionExport>(exported));
	R_SetExternalPtrProtected(owner, protection);
	native->shared_exports.erase(
	    std::remove_if(native->shared_exports.begin(), native->shared_exports.end(),
		               [](const std::weak_ptr<SharedConnectionExport> &entry) { return entry.expired(); }),
	    native->shared_exports.end());
	native->shared_exports.push_back(exported);
	using namespace cpp11::literals;
	return cpp11::writable::list(
	    {"address"_nm = std::to_string(reinterpret_cast<uintptr_t>(&exported->api)), "owner"_nm = owner});
}
