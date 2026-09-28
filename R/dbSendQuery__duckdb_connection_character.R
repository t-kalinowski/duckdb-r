# Explained in handbook/usage/statements/README.md.

#' @rdname duckdb_connection-class
#' @inheritParams DBI::dbSendQuery
#' @inheritParams DBI::dbBind
#' @param arrow Whether the query should be returned as an Arrow Table
#' @section Multiple statements:
#' A `statement` can contain several SQL statements separated by semicolons.
#' This applies to [dbSendQuery()], [dbSendQueryArrow()],
#' and helpers such as [dbExecute()] and [dbGetQuery()].
#'
#' Statements run in order.
#' Each statement is expanded and prepared after the preceding statements
#' have run, so it can see their effects.
#' For example, `PRAGMA create_fts_index(...)` can find a table
#' created earlier in the same string.
#' All statements before the last execute when the query is sent.
#' `params` apply only to the last statement, and only its result is returned.
#'
#' The whole input string is parsed before any statement runs.
#' A syntax error in the input therefore prevents all execution.
#' Other checks performed before execution can also reject the whole call.
#' For example, when `allow_extensions = FALSE`, an `INSTALL` or `LOAD`
#' anywhere in the string prevents any of its statements from running.
#'
#' If an error occurs while preparing or executing a statement,
#' no later statements run.
#' Changes already committed by earlier statements are not automatically
#' rolled back: submitting several statements in one string does not itself
#' put them in a single transaction.
#'
#' To run the statements in a single transaction, use [dbWithTransaction()].
#' Alternatively, call [dbBegin()] before submitting the SQL,
#' then [dbCommit()] on success or [dbRollback()] on failure.
#'
#' A `BEGIN TRANSACTION` inside the SQL string also starts a transaction
#' when execution reaches it.
#' However, if parsing fails, `BEGIN` never runs and there is no transaction
#' to roll back.
#' Starting the transaction before submitting the string avoids this
#' distinction; [dbWithTransaction()] also handles rollback automatically
#' when the call fails.
#'
#' To track which statements completed before an error,
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
