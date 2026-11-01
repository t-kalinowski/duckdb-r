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
