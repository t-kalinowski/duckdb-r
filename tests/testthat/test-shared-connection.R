test_that("exporting a connection preserves its transaction and identity", {
  con <- local_con()
  dbExecute(con, "CREATE TEMP TABLE shared_export(value INTEGER)")
  dbBegin(con)
  dbExecute(con, "INSERT INTO shared_export VALUES (42)")

  exported <- duckdb_export_connection(con)

  expect_named(exported, c("address", "owner"))
  expect_type(exported$address, "character")
  expect_match(exported$address, "^[0-9]+$")
  expect_type(exported$owner, "externalptr")
  expect_true(dbIsValid(con))
  expect_equal(dbGetQuery(con, "SELECT value FROM shared_export")$value, 42L)
  dbRollback(con)
  expect_equal(dbGetQuery(con, "SELECT count(*) AS n FROM shared_export")$n, 0)
})

test_that("importing an R export returns its original native connection", {
  con <- local_con()
  exported <- duckdb_export_connection(con)
  imported <- duckdb_import_connection(exported)
  expect_identical(imported, con)
  expect_equal(dbGetQuery(imported, "SELECT 42 AS value")$value, 42L)
})

test_that("connection import rejects malformed descriptor addresses", {
  for (address in c("-1", "184467440737095516160", "12 trailing")) {
    expect_error(
      duckdb_import_connection(list(address = address, owner = NULL)),
      "Invalid shared connection descriptor address"
    )
  }
})

test_that("connection export validates its public arguments", {
  con <- dbConnect(duckdb())
  expect_error(duckdb_export_connection(NULL))
  expect_error(duckdb_export_connection(con, environment = list()))
  dbDisconnect(con)
  expect_error(duckdb_export_connection(con))
})

test_that("exports do not prevent explicit disconnection", {
  con <- dbConnect(duckdb())
  exported <- duckdb_export_connection(con)
  second <- duckdb_export_connection(con)
  dbDisconnect(con)
  expect_false(dbIsValid(con))
  expect_type(exported$owner, "externalptr")
  expect_type(second$owner, "externalptr")
  rm(exported, second)
  expect_no_error(gc())
})

test_that("closing an exported connection rolls back while R results remain alive", {
  skip_if_not_installed("arrow")
  drv <- duckdb(shared_home = FALSE)
  con <- dbConnect(drv)
  observer <- dbConnect(drv)
  withr::defer(if (dbIsValid(con)) dbDisconnect(con))
  withr::defer(dbDisconnect(observer))
  dbExecute(con, "CREATE TABLE shared_close(value INTEGER)")
  dbExecute(con, "INSERT INTO shared_close VALUES (0)")
  exported <- duckdb_export_connection(con)
  dbBegin(con)
  dbExecute(con, "UPDATE shared_close SET value = 1")
  result <- dbSendQuery(con, "SELECT * FROM range(1000000)", arrow = TRUE)
  withr::defer(dbClearResult(result))
  reader <- duckdb_fetch_record_batch(result, 1024)
  expect_equal(reader$read_next_batch()$num_rows, 1024L)

  dbDisconnect(con)

  # The reader can retain buffered rows and its context; neither may keep
  # this transaction's locks after explicit shared disconnection.
  expect_equal(dbExecute(observer, "UPDATE shared_close SET value = 2"), 1)
})
