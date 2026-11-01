# Handbook: handbook/usage/connections/README.md

#' Export a native connection for another language binding
#'
#' `duckdb_export_connection()` exposes an existing connection through the
#' native sharing protocol in `duckdb_shared_connection.h`. A consumer must
#' validate the protocol and native ABI before using the connection.
#'
#' @param con A live [duckdb_connection-class].
#' @param environment Environment used to discover R data frames when the
#'   importing binding prepares SQL. Defaults to [globalenv()].
#'
#' @return A named list containing `address`, a decimal character representation
#'   of the native descriptor address, and `owner`, an external pointer that
#'   retains the descriptor, connection, and environment. Consumers must retain
#'   `owner` for as long as they use the descriptor.
#'
#' @details
#' Export does not execute SQL, open a second connection, or change transaction
#' state. Operations through an imported connection use the original session.
#' Explicit disconnection closes every imported view, ends pending streaming
#' results, and rolls back an open transaction. Collecting an export only
#' releases that export's references.
#'
#' Native sharing requires a compatible engine build and serial execution on
#' R's owning thread. It is not an interface for passing connections between
#' processes. Importers reject incompatible builds before accessing the native
#' connection, allowing the caller to select another integration method.
#'
#' A Python user-defined function that calls R must also run on R's owning
#' thread, for example by setting `SET threads = 1` before invoking it.
#' Ordinary native queries can execute in parallel.
#'
#' Lazy native relations retain the R data frames found during query
#' preparation until those relations are released, including when a frame's
#' name is rebound in the lookup environment.
#'
#' @export
duckdb_export_connection <- function(con, environment = globalenv()) {
  stopifnot(
    inherits(con, "duckdb_connection"),
    dbIsValid(con),
    is.environment(environment)
  )
  rethrow_rapi_export_connection(con, environment)
}

#' Import a native connection from another language binding
#'
#' `duckdb_import_connection()` presents a compatible foreign native connection
#' as a regular [duckdb_connection-class], with DBI and relational methods.
#' Queries share the producer's session and transaction. Importing an R export
#' returns its original R connection.
#'
#' @param exported A native connection export containing `address` and `owner`.
#'
#' @return A [duckdb_connection-class] using the exported native connection.
#' @details Collecting the imported R connection releases that view. Explicit
#'   [DBI::dbDisconnect()] closes the shared session in both bindings. Native
#'   builds must be ABI-compatible; import rejects incompatible builds.
#' @export
duckdb_import_connection <- function(exported) {
  stopifnot(
    is.list(exported),
    all(c("address", "owner") %in% names(exported)),
    is.character(exported$address),
    length(exported$address) == 1L
  )
  convert_opts <- duckdb_convert_opts()
  native <- rethrow_rapi_import_connection(exported, convert_opts)
  if (!is.null(native[["connection"]])) {
    return(native[["connection"]])
  }
  driver <- new(
    "duckdb_driver",
    database_ref = native$database_ref,
    config = list(),
    dbdir = native$dbdir,
    read_only = native$read_only,
    convert_opts = convert_opts,
    bigint = convert_opts$bigint,
    allow_extensions = TRUE
  )
  reg.finalizer(driver@database_ref, onexit = TRUE, rapi_shutdown)
  con <- new(
    "duckdb_connection",
    conn_ref = native$connection_ref,
    driver = driver,
    debug = FALSE,
    reserved_words = native$reserved_words,
    convert_opts = convert_opts,
    timezone_out = convert_opts$timezone_out,
    tz_out_convert = convert_opts$tz_out_convert,
    bigint = convert_opts$bigint
  )
  con
}
