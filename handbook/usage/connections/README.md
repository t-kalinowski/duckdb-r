# Connections

`dbConnect()` semantics:
database instances and their caching,
when `config` and `read_only` take effect,
and `duckdb_shutdown()`.
`?duckdb` (the roxygen in [`R/Driver.R`](/R/Driver.R))
is the shipped reference for this topic
and carries the full text of these rules.

The load-bearing facts:

* `duckdb()` returns a driver that owns a *database instance*;
  `dbConnect()` opens connections to it,
  and many connections share one instance.
* For a file-based `dbdir` the instance is **cached**,
  keyed by the canonical path, in `driver_registry`.
  An in-memory database is never cached.
* **That cache is a correctness guard, not an optimization.**
  On POSIX the engine's file lock is per-process, and `rapi_startup()` builds a `DuckDB` directly,
  so a second read-write instance on a file this process already holds opens without complaint.
  The two then diverge: each sees what was committed before it opened and nothing the other writes afterwards.
  On Windows the engine opens a read-write database file sharing nothing but its deletion
  (vendored `src/duckdb/src/common/local_file_system.cpp`), which probably refuses the second open; that is not measured.
  `driver_registry` is what keeps one R session to one writer per database,
  so a key that fails to unify two spellings of one file is a data-integrity bug rather than a missed reuse
  ([`2026-08-09-path-canonicalization/`](/experiments/2026-08-09-path-canonicalization/README.md)).
* **The key is the engine's path, not R's.**
  `path_normalize()` asks DuckDB through `rapi_canonicalize_path()` rather than calling `normalizePath()`,
  because the identity that decides whether two calls collide on a lock is the engine's.
  DuckDB canonicalizes the longest existing prefix and appends the rest,
  so a database that does not exist yet resolves without anything being created.
  `duckdb()` resolves the path once more after the engine has opened it, and files the instance under that key,
  because a symlink to a database yet to be created resolves only once its target exists.
  Two spellings of one database (relative, symlinked, differently separated) therefore share an instance.
  Symlinks are out of scope on Windows, where creating one takes administrator rights or Developer Mode, so few users have them.
  There the engine does not open a symlink whose target does not exist yet,
  and `duckdb()` fails with `Cannot open file`, which the test for that case skips.
  Only `~` stays R's to expand: DuckDB has its own idea of the home directory, and on Windows it is not R's.
  A path that resolves no further is used as it stands rather than refused,
  so that a network drive whose directories the user may traverse but not list still opens
  ([#455](https://github.com/duckdb/duckdb-r/issues/455)).
  That the engine opens such a path where `normalizePath()` refuses it rests on the engine's sources,
  and a runner did not reproduce it
  ([`2026-08-09-path-canonicalization/`](/experiments/2026-08-09-path-canonicalization/README.md)).
  A path the engine cannot open, in a directory that does not exist for one,
  still fails in `duckdb()` with the engine's error naming it, and leaves nothing cached.
* `dbdir`, `config`, `read_only`, `home`, and `shared_home`
  all describe the *instance*, so they bind when it is created —
  and `dbConnect()` accepts every one of them anyway,
  in two ways, neither of them what a caller wants
  ([#83](https://github.com/duckdb/duckdb-r/issues/83),
  [#171](https://github.com/duckdb/duckdb-r/issues/171)).
  `dbdir` wins: it overrides the path the driver was built with
  and opens the connection on a driver of its own,
  leaving the object passed in holding its own database.
  The rest lose: merged over the driver's, they land only where that
  call is the one creating the instance — which is why the same
  `config` argument takes effect beside a `dbdir` naming another
  file, and is dropped without it.
  Naming all of them once, in `duckdb()`, is what avoids both.
  To apply new values to a file database,
  release the instance with `duckdb_shutdown()` first;
  a setting the engine also accepts after startup, `memory_limit`
  and `threads` among them, can be `SET` on the connection instead.
* **Each of those losses is now an error**
  ([#2560](https://github.com/duckdb/duckdb-r/issues/2560)),
  and taking the arguments out of `dbConnect()` altogether remains
  [#126](https://github.com/duckdb/duckdb-r/issues/126).
  A setting is refused when it *differs* from the instance's, not
  merely when it is passed: `dbConnect()` forwards the driver's own
  values, so repeating one is no collision.
  A `dbdir` that would displace the driver's is refused only when the
  driver owns a file — `dbConnect(duckdb(), "my.db")` displaces a
  throwaway in-memory database and is the documented idiom.
  The way through, either way, is `duckdb_shutdown()`.
* **Why an error and not a warning.**
  The trade is a script that used to run and now stops, against a
  setting the caller believed had applied.
  The second is the worse failure and the harder one to notice —
  a database opened writable when `read_only = TRUE` was asked for
  reads as success until something writes — and
  [tidy design](https://design.tidyverse.org/) settles which way that
  goes.
  The cost is bounded by comparing values rather than counting
  arguments: the calls that break are the ones that were already not
  doing what they said.
* **A `dbdir` an extension answers is not normalized.**
  `md:` (MotherDuck), `ducklake:` and their kind name a replacement
  open, not a file, so they pass through untouched; normalizing one
  turned it into a local file name the engine then failed to open.
  The test for a prefix is the engine's own: two or more
  alphanumeric characters before the first colon, which leaves `C:\db`
  a Windows path, and `://` after them marks a URL scheme rather than
  a prefix, which leaves `s3://` to be normalized like any other path.
* `dbDisconnect()` closes one connection only;
  its `shutdown` argument is unused.
  `dbConnect()` hands the instance's only strong reference to the connection,
  so the instance is released when the last connection closes —
  and a driver never connected to releases it when it is garbage-collected,
  or at the end of the session.
* The engine keeps an instance cache of its own,
  which waits for a shutdown that is finishing
  and cannot tell that from an instance nothing is shutting down,
  so it spins forever on the second.
  [`patch/0042-Tell-a-database-still-in-use-from-a-shutdown-in-flight.patch`](/patch/0042-Tell-a-database-still-in-use-from-a-shutdown-in-flight.patch)
  makes it report instead, measured in
  [`experiments/2026-09-19-instance-cache-in-use/`](/experiments/2026-09-19-instance-cache-in-use/README.md).
  No call from R reaches that cache today, because `duckdb()` builds its instance directly.
  Handing the driver cache to it is [#2857](https://github.com/duckdb/duckdb-r/issues/2857),
  which collects what the attempt in [#2644](https://github.com/duckdb/duckdb-r/pull/2644) found.
* `dbIsValid()` on a driver reports whether it still holds an instance,
  and opens nothing to find out,
  so a driver whose last connection has closed is no longer valid.
  `duckdb_shutdown()` on such a driver is a silent no-op:
  what it asks for has already happened.
* An uncleared result, or an Arrow stream not yet released,
  keeps the instance alive past `dbDisconnect()`,
  unknown to the driver, and a new driver on the same file then opens the
  file a second time in this process; the mapping behind that is
  [`architecture/glue/objects/`](/handbook/architecture/glue/objects/README.md)'s.

*To deepen: absorb the instance and caching section of `?duckdb`.*

## Sharing with another language binding

`duckdb_export_connection(con, environment = globalenv())` exports the original
session through the native protocol in
[`inst/include/duckdb_shared_connection.h`](/inst/include/duckdb_shared_connection.h).
It returns a descriptor address and an owning external pointer, without executing
SQL or changing transaction state. A consumer keeps the owner alive while it uses
the descriptor and rejects incompatible protocol or native ABI identities before
accessing the engine objects.

The producer retains the R connection and lookup environment. A foreign operation
runs on R's owning thread, within the same reentrancy boundary as an R query, and
supplies that environment to R dataframe discovery. Lazy native relations retain
their discovered frames until the relations are released, so results remain valid
after a name is rebound without retaining frames from every past query.
The native R connection and its relational API remain available to DBI and duckplyr.
Sharing does not change which connection duckplyr selects for its own workflows.

A Python user-defined function that calls R must run on R's owning thread.
Set `threads = 1` before invoking such a function. Ordinary native queries can
execute in parallel.

An explicit close notifies imported views before destroying the connection, outside
engine locks. Each view releases its outstanding results in that notification.
The producer ends its R streams and rolls back an open transaction before closing,
even when an R result still holds the underlying client context.
A refused notification leaves the native connection open, although views already
notified may have discarded results. Collecting an export only releases its references;
it does not explicitly disconnect the R connection. The protocol is process-local
and does not make R objects safe to query from background threads.

`duckdb_import_connection(exported)` imports the same protocol from another
binding as a native `duckdb_connection`. The R driver wraps the original database,
and DBI, relational operations, and duckplyr use the producer's connection and
transaction. Import obtains quoting metadata from the native parser without
executing SQL on the shared session, so an open transaction or pending result is
preserved. A first foreign import during an active query is refused before
changing the native session.

R queries keep their ordinary caller-environment lookup, including R data frames
in `globalenv()`. Direct Python queries keep Python's lookup conventions. Explicitly
registered views are visible from either binding. Native views retain registered
R data frames even after the imported R connection is collected; the importing
view, its statements, relations, and Arrow streams retain the producer as needed.
The producer's context holds weak references to the R adapter so these lifetimes
do not form an ownership cycle.

Collecting an imported R view releases that view. Explicit `dbDisconnect()` closes
the shared session and invalidates its other views; closing the producer also
invalidates the R connection. `dbConnect(imported@driver)` opens an independent
native session on the same database, with its own transaction and temporary tables.
Exporting that clone shares the clone's session. Exporting an imported view forwards
the original producer's export, and importing an R-produced export returns its
original R connection, so round trips do not create nested owners.
