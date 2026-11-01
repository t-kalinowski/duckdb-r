# RETICULATE_PYTHON selects a Python build with the companion export API.
reverse_python_module <- function() {
  skip_if_not_installed("reticulate")
  skip_if_not(reticulate::py_module_available("duckdb"))
  python <- reticulate::import("duckdb", convert = FALSE)
  skip_if_not(
    reticulate::py_has_attr(python, "export_connection"),
    "Python DuckDB does not provide the shared-connection exporter"
  )
  python
}

reverse_python_exec <- function(scope, source) {
  reticulate::import_builtins(convert = FALSE)$exec(source, scope)
  invisible()
}

reverse_r_import <- function(scope) {
  duckdb_import_connection(reticulate::py_to_r(
    scope$duckdb$export_connection(scope$con)
  ))
}

reverse_collect_native_refs <- function() {
  suppressWarnings(gc())
  # R statement finalizers park their native handles until a later entry.
  con <- dbConnect(duckdb(shared_home = FALSE))
  on.exit(dbDisconnect(con))
  invisible(dbGetQuery(con, "SELECT 1"))
  invisible(gc())
  # A relation can release its R connection, whose finalizer then unpreserves
  # the reticulate export owner already marked by the preceding collection.
  invisible(gc())
}

test_that("R imports Python sessions with native types, frames and transactions", {
  python <- reverse_python_module()
  scope <- reticulate::dict(duckdb = python)
  reverse_python_exec(
    scope,
    r"---(
con = duckdb.connect()
con.execute('CREATE TEMP TABLE reverse_values AS SELECT 10 AS value')
con.begin()
con.execute('INSERT INTO reverse_values VALUES (20)')
con.execute('SELECT * FROM range(3)')
assert con.fetchone() == (0,)
)---"
  )
  con <- reverse_r_import(scope)
  withr::defer(if (dbIsValid(con)) dbDisconnect(con))
  expect_s4_class(con, "duckdb_connection")
  expect_true(dbIsValid(con))
  expect_no_error(reverse_python_exec(
    scope,
    r"---(
assert con.fetchall() == [(1,), (2,)]
con.rollback()
for value in (-(2**63), 2**63 - 1, 2**64 - 1, 2**53 + 1):
    assert con.execute('SELECT ?', [value]).fetchall() == [(value,)]
)---"
  ))
  expect_equal(dbGetQuery(con, "SELECT value FROM reverse_values")$value, 10L)

  dbBegin(con)
  dbExecute(con, "INSERT INTO reverse_values VALUES (20)")
  expect_no_error(reverse_python_exec(
    scope,
    r"---(
assert con.execute('SELECT value FROM reverse_values ORDER BY value').fetchall() == [(10,), (20,)]
con.rollback()
con.begin()
con.execute('INSERT INTO reverse_values VALUES (30)')
)---"
  ))
  expect_equal(
    dbGetQuery(con, "SELECT value FROM reverse_values ORDER BY value")$value,
    c(10L, 30L)
  )
  dbCommit(con)
  expect_no_error(reverse_python_exec(
    scope,
    r"---(
assert con.execute('SELECT value FROM reverse_values ORDER BY value').fetchall() == [(10,), (30,)]
)---"
  ))

  rlang::local_bindings(
    reverse_global_frame = data.frame(value = c(2L, 3L)),
    .env = globalenv()
  )
  expect_equal(
    dbGetQuery(con, "SELECT value FROM reverse_global_frame")$value,
    c(2L, 3L)
  )
  assign("reverse_global_frame", data.frame(value = 42L), envir = globalenv())
  invisible(gc())
  expect_equal(
    dbGetQuery(con, "SELECT value FROM reverse_global_frame")$value,
    42L
  )
  duckdb_register(con, "reverse_registered_frame", data.frame(value = 7L))
  expect_no_error(reverse_python_exec(
    scope,
    r"---(
assert type(con) is duckdb.DuckDBPyConnection
assert con.execute('SELECT value FROM reverse_registered_frame').fetchall() == [(7,)]
)---"
  ))
})

test_that("Python registrations survive when the R view is the last owner", {
  python <- reverse_python_module()
  skip_if_not(reticulate::py_module_available("pandas"))
  scope <- reticulate::dict(duckdb = python)
  reverse_python_exec(
    scope,
    r"---(
import gc
import pandas
import weakref

con = duckdb.connect()
frame = pandas.DataFrame({'value': [99]})
frame_ref = weakref.ref(frame)
con.register('reverse_python_frame', frame)
con.create_function('reverse_python_udf', lambda value: value + 1, ['INTEGER'], 'INTEGER')
)---"
  )
  con <- reverse_r_import(scope)
  withr::defer(if (dbIsValid(con)) dbDisconnect(con))
  expect_no_error(reverse_python_exec(
    scope,
    r"---(
del con, frame
gc.collect()
assert frame_ref() is not None
)---"
  ))
  invisible(gc())
  expect_equal(
    dbGetQuery(con, "SELECT value FROM reverse_python_frame")$value,
    99
  )
  expect_equal(
    dbGetQuery(con, "SELECT reverse_python_udf(41) AS value")$value,
    42L
  )
  dbDisconnect(con)
  invisible(gc())
  expect_no_error(reverse_python_exec(
    scope,
    r"---(
gc.collect()
assert frame_ref() is None
)---"
  ))
})

test_that("collecting an R view preserves its registered frames in Python", {
  python <- reverse_python_module()
  scope <- reticulate::dict(duckdb = python)
  reverse_python_exec(scope, "import gc\ncon = duckdb.connect()")
  con <- reverse_r_import(scope)
  finalized <- new.env(parent = emptyenv())
  finalized$done <- FALSE
  witness <- new.env(parent = emptyenv())
  reg.finalizer(witness, function(...) finalized$done <- TRUE)
  frame <- data.frame(value = 17L)
  attr(frame, "collection_witness") <- witness
  duckdb_register(con, "reverse_retained_frame", frame)
  rm(con, frame, witness)
  suppressWarnings(gc())
  expect_false(finalized$done)
  expect_no_error(reverse_python_exec(
    scope,
    r"---(
assert con.execute('SELECT value FROM reverse_retained_frame').fetchall() == [(17,)]
con.close()
del con
gc.collect()
)---"
  ))
  invisible(gc())
  expect_true(finalized$done)
})

test_that("an R lazy relation retains the Python owner until it is collected", {
  python <- reverse_python_module()
  skip_if_not_installed("duckplyr")
  loadNamespace("duckplyr")
  # duckplyr normally retains the last materialized relation for last_rel().
  # Disable that diagnostic reference so this test observes its own lifetime.
  withr::local_options(duckdb.materialize_callback = NULL)
  scope <- reticulate::dict(duckdb = python)
  reverse_python_exec(
    scope,
    r"---(
import gc
import weakref
con = duckdb.connect()
con.execute('CREATE TEMP TABLE reverse_relation_values AS SELECT 42 AS value')
def reverse_lazy_udf(value):
    return value
udf_ref = weakref.ref(reverse_lazy_udf)
con.create_function('reverse_lazy_udf', reverse_lazy_udf, ['INTEGER'], 'INTEGER')
del reverse_lazy_udf
)---"
  )
  con <- reverse_r_import(scope)
  relation <- duckplyr::read_sql_duckdb(
    "SELECT reverse_lazy_udf(value) AS value FROM reverse_relation_values",
    con = con
  )
  rm(con)
  reverse_python_exec(scope, "del con\ngc.collect()")
  suppressWarnings(gc())
  expect_equal(as.data.frame(relation)$value, 42L)
  expect_no_error(reverse_python_exec(scope, "assert udf_ref() is not None"))

  rm(relation)
  reverse_collect_native_refs()
  expect_no_error(reverse_python_exec(
    scope,
    "gc.collect()\nassert udf_ref() is None"
  ))
})

test_that("closing Python-owned sessions releases all shared views and transactions", {
  python <- reverse_python_module()
  skip_if_not_installed("arrow")
  close_case <- function(closer) {
    scope <- reticulate::dict(
      duckdb = python,
      path = tempfile(fileext = ".duckdb")
    )
    reverse_python_exec(
      scope,
      r"---(
con = duckdb.connect(path)
observer = duckdb.connect(path)
cursor = con.cursor()
con.execute('CREATE TABLE reverse_close_values AS SELECT 1 AS value')
con.execute('CREATE TABLE reverse_cursor_values AS SELECT 5 AS value')
)---"
    )
    withr::defer(reverse_python_exec(scope, "con.close()\nobserver.close()"))
    con <- reverse_r_import(scope)
    sibling <- reverse_r_import(scope)
    dbBegin(con)
    dbExecute(con, "UPDATE reverse_close_values SET value = value + 1")
    reverse_python_exec(
      scope,
      r"---(
cursor.begin()
cursor.execute('UPDATE reverse_cursor_values SET value = value + 1')
)---"
    )

    if (closer == "R") {
      reverse_python_exec(
        scope,
        r"---(
con.execute('SELECT * FROM range(100000)')
assert con.fetchone() == (0,)
)---"
      )
      dbDisconnect(con)
    } else {
      result <- dbSendQuery(con, "SELECT * FROM range(100000)", arrow = TRUE)
      withr::defer(dbClearResult(result))
      reader <- duckdb_fetch_record_batch(result, 1024)
      expect_equal(reader$read_next_batch()$num_rows, 1024L)
      reverse_python_exec(scope, "con.close()")
    }

    expect_false(dbIsValid(con))
    expect_false(dbIsValid(sibling))
    expect_no_error(reverse_python_exec(
      scope,
      r"---(
observer.execute('UPDATE reverse_close_values SET value = value + 10')
observer.execute('UPDATE reverse_cursor_values SET value = value + 20')
assert observer.execute('SELECT value FROM reverse_close_values').fetchall() == [(11,)]
assert observer.execute('SELECT value FROM reverse_cursor_values').fetchall() == [(25,)]
for view in (con, cursor):
    try:
        view.execute('SELECT 1')
    except duckdb.ConnectionException:
        pass
    else:
        raise AssertionError('closed producer left a usable native view')
)---"
    ))
  }
  close_case("R")
  close_case("Python")
})

test_that("round trips preserve the original owner and release their references", {
  python <- reverse_python_module()
  scope <- reticulate::dict(duckdb = python)
  reverse_python_exec(
    scope,
    r"---(
import gc
import weakref

con = duckdb.connect()
con.execute('CREATE TEMP TABLE reverse_roundtrip AS SELECT 42 AS value')
def roundtrip_udf(value):
    return value + 1
udf_ref = weakref.ref(roundtrip_udf)
con.create_function('roundtrip_udf', roundtrip_udf, ['INTEGER'], 'INTEGER')
del roundtrip_udf
)---"
  )
  first <- reverse_r_import(scope)
  scope$roundtrip <- python$from_shared_connection(reticulate::r_to_py(
    duckdb_export_connection(first)
  ))
  expect_no_error(reverse_python_exec(scope, "assert roundtrip is con"))
  second <- duckdb_import_connection(reticulate::py_to_r(
    python$export_connection(scope$roundtrip)
  ))
  expect_equal(
    dbGetQuery(second, "SELECT value FROM reverse_roundtrip")$value,
    42L
  )
  dbDisconnect(second)
  expect_false(dbIsValid(first))
  rm(first, second)
  reverse_collect_native_refs()
  expect_no_error(reverse_python_exec(
    scope,
    r"---(
for view in (con, roundtrip):
    try:
        view.execute('SELECT 1')
    except duckdb.ConnectionException:
        pass
    else:
        raise AssertionError('round trip did not preserve the shared owner')
del view, con, roundtrip
gc.collect()
assert udf_ref() is None
)---"
  ))

  original <- dbConnect(duckdb(shared_home = FALSE))
  withr::defer(if (dbIsValid(original)) dbDisconnect(original))
  python_view <- python$from_shared_connection(reticulate::r_to_py(
    duckdb_export_connection(original)
  ))
  returned <- duckdb_import_connection(reticulate::py_to_r(
    python$export_connection(python_view)
  ))
  expect_identical(returned, original)
  dbDisconnect(returned)
  expect_false(dbIsValid(original))
  expect_error(python_view$execute("SELECT 1"), "closed")
})

test_that("duckplyr uses the imported Python session", {
  python <- reverse_python_module()
  skip_if_not_installed("duckplyr")
  scope <- reticulate::dict(duckdb = python)
  reverse_python_exec(
    scope,
    r"---(
con = duckdb.connect()
con.execute('CREATE TEMP TABLE reverse_duckplyr AS SELECT 42 AS value')
)---"
  )
  con <- reverse_r_import(scope)
  withr::defer(if (dbIsValid(con)) dbDisconnect(con))
  frame <- duckplyr::read_sql_duckdb(
    "SELECT value FROM reverse_duckplyr",
    con = con
  )
  expect_equal(as.data.frame(frame)$value, 42L)
  rlang::local_bindings(
    reverse_duckplyr_frame = data.frame(value = c(2L, 3L)),
    .env = globalenv()
  )
  captured <- duckplyr::read_sql_duckdb(
    "SELECT value FROM reverse_duckplyr_frame ORDER BY value",
    con = con
  )
  assign("reverse_duckplyr_frame", data.frame(value = 99L), envir = globalenv())
  invisible(gc())
  expect_equal(as.data.frame(captured)$value, c(2L, 3L))
  expect_equal(
    dbGetQuery(con, "SELECT value FROM reverse_duckplyr_frame")$value,
    99L
  )
  pending <- duckplyr::read_sql_duckdb(
    "SELECT value FROM reverse_duckplyr",
    con = con
  )
  dbDisconnect(con)
  expect_error(sum(as.data.frame(pending)$value), "closed")
})

test_that("cloning an imported R driver creates an independent retained session", {
  python <- reverse_python_module()
  scope <- reticulate::dict(duckdb = python)
  reverse_python_exec(
    scope,
    r"---(
import gc
con = duckdb.connect()
con.execute('CREATE TABLE reverse_cloned_values(value INTEGER)')
)---"
  )
  imported <- reverse_r_import(scope)
  clone <- dbConnect(imported@driver)
  withr::defer(if (dbIsValid(clone)) dbDisconnect(clone))
  other_clone <- dbConnect(imported@driver)
  dbDisconnect(other_clone)
  expect_no_error(reverse_python_exec(
    scope,
    "assert con.execute('SELECT value FROM reverse_cloned_values').fetchall() == []"
  ))
  dbExecute(clone, "CREATE TEMP TABLE reverse_clone_only AS SELECT 42 AS value")
  dbBegin(clone)
  dbExecute(clone, "INSERT INTO reverse_cloned_values VALUES (10)")
  expect_no_error(reverse_python_exec(
    scope,
    r"---(
assert con.execute('SELECT value FROM reverse_cloned_values').fetchall() == []
try:
    con.execute('SELECT value FROM reverse_clone_only')
except duckdb.CatalogException:
    pass
else:
    raise AssertionError('cloned R driver reused the original native session')
)---"
  ))
  dbCommit(clone)
  scope$clone_view <- python$from_shared_connection(reticulate::r_to_py(
    duckdb_export_connection(clone)
  ))
  expect_no_error(reverse_python_exec(
    scope,
    r"---(
assert clone_view is not con
assert clone_view.execute('SELECT value FROM reverse_clone_only').fetchall() == [(42,)]
del con
gc.collect()
)---"
  ))
  rm(imported)
  suppressWarnings(gc())
  expect_equal(
    dbGetQuery(clone, "SELECT value FROM reverse_cloned_values")$value,
    10L
  )
  dbDisconnect(clone)
  expect_no_error(reverse_python_exec(
    scope,
    r"---(
try:
    clone_view.execute('SELECT 1')
except duckdb.ConnectionException:
    pass
else:
    raise AssertionError('closing the R clone left its Python view usable')
)---"
  ))
})

test_that("Python-owned sessions refuse foreign threads and reentrant R queries", {
  reverse_python_module()
  skip_if_not_installed("callr")
  # Reticulate callbacks must execute on R's thread. A regression acquiring
  # the same session twice becomes a timeout instead of wedging this suite.
  result <- callr::r(
    function(pkg, python) {
      Sys.setenv(RETICULATE_PYTHON = python)
      ns <- asNamespace(pkg)
      module <- reticulate::import("duckdb", convert = FALSE)
      scope <- reticulate::dict(duckdb = module)
      builtins <- reticulate::import_builtins(convert = FALSE)
      builtins$exec("con = duckdb.connect(config={'threads': '1'})", scope)
      exported <- reticulate::py_to_r(module$export_connection(scope$con))
      scope$r_import <- function(value) {
        ns$duckdb_import_connection(exported)
        stop("An initial import was admitted inside its producer's query")
      }
      builtins$exec(
        r"---(
con.create_function('reverse_reentrant_import', lambda value: r_import(value), ['INTEGER'], 'INTEGER')
try:
    con.execute('SELECT reverse_reentrant_import(1)').fetchall()
except duckdb.InvalidInputException as error:
    assert "code running inside a query cannot use that query's connection" in str(error)
else:
    raise AssertionError('initial R import was admitted inside its producer query')
con.remove_function('reverse_reentrant_import')
)---",
        scope
      )
      con <- ns$duckdb_import_connection(reticulate::py_to_r(
        module$export_connection(scope$con)
      ))
      ns$duckdb_register(con, "reverse_thread_frame", data.frame(value = 17L))
      rm(con)
      suppressWarnings(gc())
      builtins$exec(
        r"---(
from concurrent.futures import ThreadPoolExecutor

with ThreadPoolExecutor(max_workers=1) as executor:
    try:
        executor.submit(con.execute, 'SELECT value FROM reverse_thread_frame').result()
    except duckdb.ConnectionException as error:
        assert 'Exported connection must be used on its exporting thread' in str(error)
    else:
        raise AssertionError('exported Python owner accessed R from a foreign thread')

    con.execute('SELECT value FROM reverse_thread_frame')
    try:
        executor.submit(con.fetchall).result()
    except duckdb.ConnectionException as error:
        assert 'Exported connection must be used on its exporting thread' in str(error)
    else:
        raise AssertionError('exported Python owner fetched from a foreign thread')
    assert con.fetchall() == [(17,)]
)---",
        scope
      )
      con <- ns$duckdb_import_connection(reticulate::py_to_r(
        module$export_connection(scope$con)
      ))
      on.exit(DBI::dbDisconnect(con))
      stopifnot(identical(
        DBI::dbGetQuery(con, "SELECT value FROM reverse_thread_frame")$value,
        17L
      ))
      scope$r_query <- function(value) {
        DBI::dbGetQuery(con, "SELECT 1 AS value")$value
      }
      builtins$exec(
        r"---(
con.create_function('reverse_reentrant_query', lambda value: r_query(value), ['INTEGER'], 'INTEGER')
try:
    con.execute('SELECT reverse_reentrant_query(1)').fetchall()
except duckdb.InvalidInputException as error:
    assert "code running inside a query cannot use that query's connection" in str(error)
else:
    raise AssertionError('Python-owned session accepted a reentrant R query')
con.remove_function('reverse_reentrant_query')
assert con.execute('SELECT 42').fetchall() == [(42,)]
)---",
        scope
      )
      DBI::dbGetQuery(con, "SELECT 42 AS value")$value
    },
    args = list(
      pkg = getNamespaceName(environment(duckdb_import_connection)),
      python = reticulate::py_config()$python
    ),
    timeout = 30
  )
  expect_equal(result, 42L)
})

test_that("Python close drains the last parked R statement safely", {
  reverse_python_module()
  skip_if_not_installed("callr")
  result <- callr::r(
    function(pkg, python) {
      Sys.setenv(RETICULATE_PYTHON = python)
      ns <- asNamespace(pkg)
      module <- reticulate::import("duckdb", convert = FALSE)
      for (iteration in seq_len(3)) {
        owner <- module$connect()
        exported <- reticulate::py_to_r(module$export_connection(owner))
        finalized <- FALSE
        witness <- new.env(parent = emptyenv())
        reg.finalizer(witness, function(...) finalized <<- TRUE)
        attr(exported, "collection_witness") <- witness
        con <- ns$duckdb_import_connection(exported)
        connection_finalized <- FALSE
        connection_witness <- new.env(parent = emptyenv())
        reg.finalizer(connection_witness, function(...) {
          connection_finalized <<- TRUE
        })
        attr(con, "collection_witness") <- connection_witness
        result <- DBI::dbSendQuery(con, "SELECT 42 AS value")
        stopifnot(identical(DBI::dbFetch(result)$value, 42L))
        owner$execute("SELECT 1")$fetchall()
        rm(con, result, exported, witness, connection_witness)
        suppressWarnings(gc())
        suppressWarnings(gc())
        # The parked statement still owns the imported database and export.
        stopifnot(connection_finalized, !finalized)
        owner$close()
        invisible(gc())
        stopifnot(finalized)
      }
      TRUE
    },
    args = list(
      pkg = getNamespaceName(environment(duckdb_import_connection)),
      python = reticulate::py_config()$python
    ),
    timeout = 30
  )
  expect_true(result)
})
