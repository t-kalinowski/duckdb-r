# These tests need the Python importer from the matching duckdb-python branch.
# RETICULATE_PYTHON selects that installation for the paired integration run.
shared_python_module <- function() {
  skip_if_not_installed("reticulate")
  skip_if_not(reticulate::py_module_available("duckdb"))
  python <- reticulate::import("duckdb", convert = FALSE)
  skip_if_not(
    reticulate::py_has_attr(python, "from_shared_connection"),
    "Python DuckDB does not provide the shared-connection importer"
  )
  python
}

shared_python_scope <- function(con) {
  python <- shared_python_module()
  reticulate::dict(
    duckdb = python,
    con = python$from_shared_connection(
      reticulate::r_to_py(duckdb_export_connection(con))
    )
  )
}

shared_python_exec <- function(scope, source) {
  reticulate::import_builtins(convert = FALSE)$exec(source, scope)
  invisible()
}

test_that("Python shares native types, R frames and their lifetime", {
  shared_python_module()
  con <- local_con(drv = duckdb(environment_scan = TRUE, shared_home = FALSE))
  finalized <- new.env(parent = emptyenv())
  finalized$done <- FALSE
  witness <- new.env(parent = emptyenv())
  reg.finalizer(witness, function(...) finalized$done <- TRUE)
  frame <- data.frame(value = c(2L, 3L))
  attr(frame, "collection_witness") <- witness
  rlang::local_bindings(
    shared_native_frame = frame,
    .env = globalenv()
  )
  rm(frame, witness)
  duckdb_register(con, "registered_native_frame", data.frame(value = 7L))
  scope <- shared_python_scope(con)

  expect_no_error(shared_python_exec(
    scope,
    r"---(
import decimal
import gc

assert type(con) is duckdb.DuckDBPyConnection
assert con.execute('SELECT * FROM shared_native_frame').fetchall() == [(2,), (3,)]
assert con.execute('SELECT * FROM registered_native_frame').fetchall() == [(7,)]
plan = con.execute('EXPLAIN SELECT * FROM registered_native_frame').fetchall()
assert any('R Dataframe Scan' in str(row) for row in plan)
lazy = con.sql('SELECT * FROM shared_native_frame ORDER BY value')
for value in (-(2**63), 2**63 - 1, 2**64 - 1, 2**53 + 1):
    assert con.execute('SELECT ?', [value]).fetchone() == (value,)
value = decimal.Decimal('12345678901234567890123456789.123456789')
assert con.execute('SELECT ?', [value]).fetchone() == (value,)
assert con.execute('SELECT ?', [None]).fetchone() == (None,)
)---"
  ))

  assign("shared_native_frame", data.frame(value = 42L), envir = globalenv())
  invisible(gc())
  expect_false(finalized$done)
  expect_no_error(shared_python_exec(
    scope,
    r"---(
assert con.execute('SELECT * FROM shared_native_frame').fetchall() == [(42,)]
assert lazy.fetchall() == [(2,), (3,)]
del lazy
gc.collect()
)---"
  ))
  # Releasing the native dependency can defer R protection cleanup until the
  # next owner-thread entry. The export itself must not pin historical frames.
  dbGetQuery(con, "SELECT 1")
  invisible(gc())
  expect_true(finalized$done)
  expect_true(dbIsValid(con))
  expect_no_error(shared_python_exec(
    scope,
    r"---(
con.create_function(
    'retained_native_udf', lambda value: value + 1, ['INTEGER'], 'INTEGER'
)
child = con.cursor()
del con
gc.collect()
assert child.execute('SELECT * FROM shared_native_frame').fetchall() == [(42,)]
try:
    child.execute('SELECT * FROM registered_native_frame')
except duckdb.CatalogException:
    pass
else:
    raise AssertionError('native cursor inherited a session-local registration')
child.close()
)---"
  ))
  expect_equal(
    dbGetQuery(con, "SELECT value FROM registered_native_frame")$value,
    7L
  )
  expect_equal(
    dbGetQuery(con, "SELECT retained_native_udf(41) AS value")$value,
    42L
  )

  # Only the Python view keeps this connection and its registered frame alive.
  retained <- local({
    owner <- dbConnect(duckdb(shared_home = FALSE))
    duckdb_register(owner, "retained_native_frame", data.frame(value = 99L))
    shared_python_scope(owner)
  })
  invisible(gc())
  expect_no_error(shared_python_exec(
    retained,
    r"---(
assert con.execute('SELECT * FROM retained_native_frame').fetchall() == [(99,)]
con.close()
)---"
  ))
})

test_that("shared operations refuse foreign threads and reentrant R queries", {
  shared_python_module()
  skip_if_not_installed("callr")

  checks <- r"---(
from concurrent.futures import ThreadPoolExecutor

with ThreadPoolExecutor(max_workers=1) as executor:
    try:
        executor.submit(con.execute, 'SELECT 1').result()
    except duckdb.ConnectionException as error:
        assert 'importing thread' in str(error)
    else:
        raise AssertionError('shared connection accepted a foreign thread')

con.create_function(
    'shared_reentrant_r_query', lambda value: r_query(value), ['INTEGER'], 'INTEGER'
)
try:
    con.execute('SELECT shared_reentrant_r_query(1)').fetchall()
except duckdb.InvalidInputException as error:
    assert 'Connection already working on another query' in str(error)
else:
    raise AssertionError('shared query accepted a reentrant R query')
con.remove_function('shared_reentrant_r_query')
assert con.execute('SELECT 42').fetchall() == [(42,)]
)---"

  # A regression takes the client-context lock twice. A subprocess timeout
  # turns that deadlock into a test failure without wedging the full suite.
  result <- callr::r(
    function(pkg, python, checks) {
      Sys.setenv(RETICULATE_PYTHON = python)
      ns <- asNamespace(pkg)
      con <- DBI::dbConnect(ns$duckdb(shared_home = FALSE))
      on.exit(DBI::dbDisconnect(con))
      # This exercises reentrancy on R's owning thread; an R callback cannot
      # be serviced while that thread waits for a background Python UDF.
      DBI::dbExecute(con, "SET threads = 1")
      module <- reticulate::import("duckdb", convert = FALSE)
      scope <- reticulate::dict(
        duckdb = module,
        con = module$from_shared_connection(
          reticulate::r_to_py(ns$duckdb_export_connection(con))
        )
      )
      pending <- new.env(parent = emptyenv())
      pending$result <- DBI::dbSendStatement(
        con,
        "CREATE TEMP TABLE shared_reentrant_probe(value INTEGER)"
      )
      finalized <- FALSE
      witness <- new.env(parent = emptyenv())
      reg.finalizer(witness, function(...) finalized <<- TRUE)
      pending$witness <- witness
      rm(witness)
      scope[["r_query"]] <- function(value) {
        pending$result <- NULL
        pending$witness <- NULL
        invisible(gc())
        stopifnot(finalized)
        DBI::dbGetQuery(con, "SELECT 1 AS value")$value
      }
      reticulate::import_builtins(convert = FALSE)$exec(checks, scope)
      list(
        finalized = finalized,
        value = DBI::dbGetQuery(con, "SELECT 42 AS value")$value
      )
    },
    args = list(
      pkg = getNamespaceName(environment(duckdb_export_connection)),
      python = reticulate::py_config()$python,
      checks = checks
    ),
    timeout = 30
  )
  expect_true(result$finalized)
  expect_equal(result$value, 42L)
})

test_that("both runtimes share transactions and explicit close", {
  shared_python_module()
  drv <- duckdb(shared_home = FALSE)
  con <- dbConnect(drv)
  observer <- dbConnect(drv)
  withr::defer(if (dbIsValid(con)) dbDisconnect(con))
  withr::defer(dbDisconnect(observer))
  dbExecute(con, "CREATE TABLE shared_native_values(value INTEGER)")
  dbExecute(
    con,
    "CREATE TABLE shared_native_cursor_values AS SELECT 5 AS value"
  )
  dbBegin(con)
  dbExecute(con, "INSERT INTO shared_native_values VALUES (10)")
  scope <- shared_python_scope(con)

  expect_no_error(shared_python_exec(
    scope,
    r"---(
assert con.execute('SELECT * FROM shared_native_values').fetchall() == [(10,)]
con.execute('INSERT INTO shared_native_values VALUES (20)')
con.rollback()
)---"
  ))
  expect_equal(
    dbGetQuery(con, "SELECT count(*) AS n FROM shared_native_values")$n,
    0
  )
  dbBegin(con)
  dbExecute(con, "INSERT INTO shared_native_values VALUES (30)")
  expect_no_error(shared_python_exec(
    scope,
    r"---(
con.execute('INSERT INTO shared_native_values VALUES (40)')
con.commit()
)---"
  ))
  expect_equal(
    dbGetQuery(
      observer,
      "SELECT value FROM shared_native_values ORDER BY value"
    )$value,
    c(30L, 40L)
  )

  dbBegin(con)
  dbExecute(con, "UPDATE shared_native_values SET value = value + 1")
  expect_no_error(shared_python_exec(
    scope,
    r"---(
lazy = con.sql('SELECT * FROM shared_native_values')
con.execute('SELECT * FROM range(100000)')
assert con.fetchone() == (0,)
cursor = con.cursor()
cursor.execute('BEGIN')
cursor.execute('UPDATE shared_native_cursor_values SET value = value + 1')
)---"
  ))
  dbDisconnect(con)
  # The Python wrapper still exists, but its pending result cannot retain the
  # rolled-back write or block the observer's update until Python GC runs.
  expect_equal(
    dbExecute(observer, "UPDATE shared_native_values SET value = value + 100"),
    2
  )
  expect_equal(
    dbExecute(
      observer,
      "UPDATE shared_native_cursor_values SET value = value + 100"
    ),
    1
  )
  expect_equal(
    dbGetQuery(observer, "SELECT value FROM shared_native_cursor_values")$value,
    105L
  )
  expect_no_error(shared_python_exec(
    scope,
    r"---(
for operation in (
    con.fetchone,
    lambda: con.execute('SELECT 1'),
    lazy.fetchall,
    lambda: cursor.execute('SELECT 1'),
):
    try:
        operation()
    except duckdb.Error:
        pass
    else:
        raise AssertionError('native view remained usable after R close')
del lazy
)---"
  ))

  con <- dbConnect(drv)
  scope <- shared_python_scope(con)
  scope[["sibling"]] <- shared_python_scope(con)[["con"]]
  dbBegin(con)
  dbExecute(con, "UPDATE shared_native_values SET value = value + 1")
  expect_no_error(shared_python_exec(
    scope,
    r"---(
con.close()
try:
    sibling.execute('SELECT 1')
except duckdb.Error:
    pass
else:
    raise AssertionError('another view remained usable after Python close')
)---"
  ))
  expect_false(dbIsValid(con))
  expect_equal(
    dbGetQuery(
      observer,
      "SELECT value FROM shared_native_values ORDER BY value"
    )$value,
    c(130L, 140L)
  )
})

test_that("Python uses the native owner of a duckplyr relation", {
  shared_python_module()
  skip_if_not_installed("duckplyr")
  skip_if_not_installed("dbplyr")
  frame <- duckplyr::duckdb_tibble(value = c(2L, 3L))
  table <- duckplyr::as_tbl(frame)
  con <- dbplyr::remote_con(table)
  scope <- shared_python_scope(con)
  scope[["query"]] <- as.character(dbplyr::sql_render(table))

  expect_no_error(shared_python_exec(
    scope,
    r"---(
assert con.execute(query).fetchall() == [(2,), (3,)]
con.execute('CREATE TEMP TABLE shared_duckplyr_values AS SELECT 42 AS value')
)---"
  ))
  from_python <- duckplyr::read_sql_duckdb(
    "SELECT value FROM shared_duckplyr_values",
    con = con
  )
  expect_equal(as.data.frame(from_python)$value, 42L)
  dbExecute(con, "DROP TABLE shared_duckplyr_values")
})
