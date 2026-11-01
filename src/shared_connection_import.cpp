#include "../inst/include/duckdb_shared_connection.h"
#include "rapi.hpp"
#include "signal.hpp"
#include "duckdb/parser/parser.hpp"

#include <algorithm>
#include <charconv>
#include <cstring>

namespace duckdb {

struct ImportedContextState : public ClientContextState {
	static const char *Key() {
		return "duckdb_r_imported_connection";
	}
	std::weak_ptr<DBWrapper> database;
	bool borrowed = false;
	bool closed = false;
	unique_ptr<RCallbackScope> callbacks;
	void QueryBegin(ClientContext &) override {
		callbacks = make_uniq<RCallbackScope>();
	}
	void QueryEnd() override {
		callbacks.reset();
	}
};

struct ImportedConnection {
	duckdb_shared_connection *api;
	SEXP exported;
	uint64_t subscription = 0;
	Connection *connection;
	std::vector<ConnWrapper *> views;
	weak_ptr<ImportedContextState> state;
	std::weak_ptr<ImportedConnection> self;
	std::string error;

	ImportedConnection(duckdb_shared_connection *api_p, SEXP exported_p, Connection *connection_p)
	    : api(api_p), exported(exported_p), connection(connection_p) {
		R_PreserveObject(exported);
	}
	~ImportedConnection() {
		if (subscription) {
			api->unsubscribe_close(api->context, subscription);
		}
		ReleasePreservedRObject(exported);
	}
	static const char *BeforeClose(void *consumer) {
		auto retained = static_cast<std::weak_ptr<ImportedConnection> *>(consumer)->lock();
		if (!retained) {
			return nullptr;
		}
		// Draining parked statements can release the final R view of this lease.
		auto &self = *retained;
		try {
			if (!OnRThread()) {
				throw std::runtime_error("An R-imported connection must close on R's owning thread");
			}
			if (self.connection && ScopedInterruptHandler::IsActiveFor(*self.connection->context)) {
				throw std::runtime_error("Cannot close an imported connection while R is executing a query");
			}
			if (self.connection) {
				EndOpenResults(*self.connection->context);
			}
			if (auto state = self.state.lock()) {
				state->closed = true;
			}
			for (auto view : self.views) {
				view->conn.reset();
				view->db.reset();
			}
			self.connection = nullptr;
			return nullptr;
		} catch (const std::exception &error) {
			self.error = error.what();
		} catch (...) {
			self.error = "Cannot close the imported R connection";
		}
		return self.error.c_str();
	}
};

struct ImportedOperation {
	std::shared_ptr<DBWrapper> database;
	explicit ImportedOperation(std::shared_ptr<DBWrapper> database_p) : database(std::move(database_p)) {
		auto api = database->imported_owner->api;
		if (auto error = api->begin_operation(api->context)) {
			throw std::runtime_error(error);
		}
	}
	~ImportedOperation() {
		auto api = database->imported_owner->api;
		api->end_operation(api->context);
	}
};

std::shared_ptr<DBWrapper> GetImportedDatabase(const shared_ptr<ClientContext> &context) {
	if (!context) {
		return nullptr;
	}
	auto state = context->registered_state->Get<ImportedContextState>(ImportedContextState::Key());
	return state ? state->database.lock() : nullptr;
}

std::shared_ptr<void> BeginImportedOperation(const shared_ptr<ClientContext> &context) {
	auto state = context->registered_state->Get<ImportedContextState>(ImportedContextState::Key());
	if (!state || !state->borrowed) {
		return nullptr;
	}
	auto database = state->database.lock();
	if (state->closed || !database || !database->imported_owner->connection) {
		throw std::runtime_error("Imported connection is closed");
	}
	return std::make_shared<ImportedOperation>(std::move(database));
}

struct ImportedScanData : public ReplacementScanData {
	std::weak_ptr<DBWrapper> database;
	replacement_scan_t scan;
};

static unique_ptr<TableRef> ImportedScan(ClientContext &context, ReplacementScanInput &input,
                                         optional_ptr<ReplacementScanData> data_p) {
	auto &data = data_p->Cast<ImportedScanData>();
	auto database = data.database.lock();
	if (!database) {
		return nullptr;
	}
	ReplacementDataDBWrapper borrowed;
	borrowed.wrapper = database.get();
	return data.scan(context, input, &borrowed);
}

void SetupImportedContext(const std::shared_ptr<DBWrapper> &database, Connection &connection, bool borrowed) {
	auto &context = *connection.context;
	auto state = context.registered_state->GetOrCreate<ImportedContextState>(ImportedContextState::Key());
	state->database = database;
	state->borrowed = borrowed;
	state->closed = false;
	if (borrowed) {
		database->imported_owner->state = state;
	}
	auto &scans = context.config.replacement_scans;
	scans.erase(std::remove_if(scans.begin(), scans.end(),
	                           [](const shared_ptr<ReplacementScan> &scan) { return scan->function == ImportedScan; }),
	            scans.end());
	for (auto scan : {ArrowScanReplacement, EnvironmentScanReplacement}) {
		auto data = make_uniq<ImportedScanData>();
		data->database = database;
		data->scan = scan;
		context.config.replacement_scans.push_back(make_shared_ptr<ReplacementScan>(ImportedScan, std::move(data)));
	}
}

void DetachImportedConnection(ConnWrapper &connection) {
	auto &views = connection.imported_owner->views;
	views.erase(std::remove(views.begin(), views.end(), &connection), views.end());
}

void CloseImportedConnection(ConnWrapper &connection) {
	if (connection.conn) {
		auto api = connection.imported_owner->api;
		if (auto error = api->close(api->context)) {
			throw std::runtime_error(error);
		}
	}
}

SEXP ExportImportedConnection(ConnWrapper &connection) {
	return connection.imported_owner->exported;
}

} // namespace duckdb

[[cpp11::register]] cpp11::list rapi_import_connection(cpp11::list exported, duckdb::ConvertOpts convert_opts) {
	using namespace duckdb;
	using namespace cpp11::literals;
	auto address = cpp11::as_cpp<std::string>(exported["address"]);
	uintptr_t raw = 0;
	auto parsed = std::from_chars(address.data(), address.data() + address.size(), raw);
	if (!raw || parsed.ec != std::errc() || parsed.ptr != address.data() + address.size()) {
		cpp11::stop("Invalid shared connection descriptor address");
	}
	auto api = reinterpret_cast<duckdb_shared_connection *>(static_cast<uintptr_t>(raw));
	auto abi = SharedConnectionABI();
	if (api->version != DUCKDB_SHARED_CONNECTION_VERSION || api->struct_size < sizeof(duckdb_shared_connection)) {
		cpp11::stop("Unsupported shared connection protocol");
	}
	if (!api->context || !api->get_connection || !api->get_database || !api->is_valid || !api->close ||
	    !api->begin_operation || !api->end_operation || !api->subscribe_close || !api->unsubscribe_close) {
		cpp11::stop("Incomplete shared connection descriptor");
	}
	if (abi.empty() || !api->abi_id || abi != api->abi_id) {
		cpp11::stop("Cannot share a connection between incompatible DuckDB native builds");
	}
	if (!api->is_valid(api->context)) {
		cpp11::stop("Shared connection is closed or belongs to another thread");
	}
	if (auto original = OriginalRConnection(api); original != R_NilValue) {
		return cpp11::writable::list({"connection"_nm = original});
	}
	auto connection = static_cast<Connection *>(api->get_connection(api->context));
	auto native_database = static_cast<DuckDB *>(api->get_database(api->context));
	if (!connection || !native_database) {
		cpp11::stop("Shared connection has no native connection or database");
	}
	auto database = GetImportedDatabase(connection->context);
	if (!database) {
		database = std::shared_ptr<DBWrapper>(new DBWrapper(), [](DBWrapper *database) {
			// An Arrow consumer can release the final reference on a worker.
			// R protection and native destruction must wait for a safe R entry.
			if (!OnRThread() || RCallbackScope::Active()) {
				RCallbackScope::Defer(unique_ptr<DBWrapper>(database));
			} else {
				delete database;
			}
		});
		database->db = std::make_shared<DuckDB>(*native_database->instance);
		database->imported_owner = std::make_shared<ImportedConnection>(api, exported, connection);
		auto &owner = *database->imported_owner;
		owner.self = database->imported_owner;
		if (auto error =
		        api->subscribe_close(api->context, ImportedConnection::BeforeClose, &owner.self, &owner.subscription)) {
			throw std::runtime_error(error);
		}
		InitializeRDatabase(*database);
		SetupImportedContext(database, *connection, true);
	}
	auto wrapper = new ConnWrapper(database, connection, std::move(convert_opts));
	database->imported_owner->views.push_back(wrapper);
	conn_eptr_t con_ref(wrapper);
	db_eptr_t db_ref(new DBWrapperDual(database));
	db_ref->unlock();
	auto &config = DBConfig::GetConfig(*database->db->instance);
	auto path = config.options.database_path.empty() ? string(IN_MEMORY_PATH) : config.options.database_path;
	cpp11::writable::strings keywords;
	for (auto &keyword : Parser::KeywordList()) {
		keywords.push_back(keyword.name);
	}
	return cpp11::writable::list({"connection_ref"_nm = con_ref, "database_ref"_nm = db_ref, "dbdir"_nm = path,
	                              "read_only"_nm = (config.options.access_mode == AccessMode::READ_ONLY),
	                              "reserved_words"_nm = keywords});
}
