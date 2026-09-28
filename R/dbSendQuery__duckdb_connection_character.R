# Explained in handbook/usage/statements/README.md.

#' @rdname duckdb_connection-class
#' @inheritParams DBI::dbSendQuery
#' @inheritParams DBI::dbBind
#' @param arrow Whether the query should be returned as an Arrow Table
#' @section Multiple statements:
#' A `statement` can hold several SQL statements separated by semicolons,
#' in [dbSendQuery()], [dbSendQueryArrow()],
#' and the helpers built on them, such as [dbExecute()] and [dbGetQuery()].
#' They run in order, and each is prepared only after those before it have run,
#' so it sees their effects:
#' a `PRAGMA` that generates SQL, such as `create_fts_index`,
#' finds a table created earlier in the same string.
#' Every statement but the last runs when the query is sent,
#' `params` bind to the last statement only,
#' and only the last statement's result is returned.
#'
#' The whole input string is parsed before anything runs.
#' Syntax errors in that input, and `INSTALL` or `LOAD` under
#' `allow_extensions = FALSE`, reject the whole call.
#' An error during preparation or execution stops later statements;
#' earlier committed changes are not automatically rolled back.
#' To run the statements in one transaction, use [dbWithTransaction()],
#' or call [dbBegin()] before the query, then [dbCommit()] on success
#' or [dbRollback()] on failure.
#' To know which statements have run when one fails,
#' send one statement per call.
#' @usage NULL
dbSendQuery__duckdb_connection_character <- function(
  conn,
  statement,
  params = NULL,
  ...,
  arrow = FALSE
) {
  if (conn@debug) {
    message("Q ", statement)
  }

  env <- find_caller()

  statement <- enc2utf8(statement)
  stmt_lst <- rethrow_rapi_prepare(conn@conn_ref, statement, env)

  res <- duckdb_result(
    connection = conn,
    stmt_lst = stmt_lst,
    arrow = arrow
  )
  if (length(params) > 0) {
    dbBind(res, params)
  }
  return(res)
}

#' @rdname duckdb_connection-class
#' @export
setMethod(
  "dbSendQuery",
  c("duckdb_connection", "character"),
  dbSendQuery__duckdb_connection_character
)

find_caller <- function() {
  i <- 3L
  env <- parent.frame(i)

  while (!identical(env, emptyenv())) {
    env_name <- environmentName(parent.env(env))
    if (!(env_name %in% c(get_package_name(), "DBI"))) {
      return(env)
    }
    i <- i + 1L
    env <- parent.frame(i)
  }

  env
}
