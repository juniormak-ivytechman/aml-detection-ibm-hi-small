-- ============================================================
-- AML Detection Project — 00_schema.sql
-- IBM HI-Small Dataset | DuckDB
-- Author: Junior Radebe
--
-- I started with MySQL Workbench but the Table Data Import
-- Wizard kept crashing on 5M rows — timeouts, lost connections,
-- hours of waiting. Switched to DuckDB entirely. Import that
-- took 3–5 hours in Workbench finished in under 60 seconds here.
--
-- I used a two-step approach: read the CSV into a staging table
-- first so DuckDB can auto-detect the structure, then cast
-- everything into the final typed table with clean column names.
-- ============================================================


-- ── STEP 1: STAGING TABLE ───────────────────────────────────
-- I let DuckDB read the raw CSV and figure out the structure.
-- The HI-Small CSV has a quirk: two columns named "Account"
-- (one for origin, one for destination). DuckDB auto-renames
-- the second one to "Account_1" — I use that in Step 2.

CREATE OR REPLACE TABLE transactions_stage AS
SELECT *
FROM read_csv_auto('HI-Small_Trans.csv');

-- Quick check before committing to the full cast
SELECT COUNT(*) AS total_rows FROM transactions_stage;
DESCRIBE transactions_stage;


-- ── STEP 2: FINAL TYPED TABLE ───────────────────────────────
-- I cast every column to its correct type here rather than
-- trusting auto-detection for the final table.
--
-- DECIMAL(18,2) for all monetary amounts — I made a deliberate
-- decision not to use FLOAT or DOUBLE. Floating point rounding
-- errors in financial data are an audit liability.
--
-- strptime() to parse the IBM timestamp format (YYYY/MM/DD HH:MM).
-- row_number() to give each transaction a unique ID since the
-- original CSV has no primary key.

CREATE OR REPLACE TABLE transactions AS
SELECT
    row_number() OVER ()                            AS transaction_id,
    strptime("Timestamp", '%Y/%m/%d %H:%M')         AS transaction_ts,
    "From Bank"                                     AS from_bank,
    "Account"                                       AS from_account,
    "To Bank"                                       AS to_bank,
    "Account_1"                                     AS to_account,
    CAST("Amount Received" AS DECIMAL(18,2))        AS amount_received,
    "Receiving Currency"                            AS receiving_currency,
    CAST("Amount Paid" AS DECIMAL(18,2))            AS amount_paid,
    "Payment Currency"                              AS payment_currency,
    "Payment Format"                                AS payment_format,
    CAST("Is Laundering" AS BOOLEAN)                AS is_laundering
FROM transactions_stage;


-- ── STEP 3: DROP STAGING TABLE ──────────────────────────────
-- Once I confirmed the final table looked right I dropped the
-- staging table to keep the database clean.
-- Run 04_validation_queries.sql first before dropping.

-- DROP TABLE IF EXISTS transactions_stage;


-- ── QUICK VERIFICATION ──────────────────────────────────────
SELECT COUNT(*) AS total_rows FROM transactions;
SELECT MIN(transaction_ts) AS earliest, MAX(transaction_ts) AS latest
FROM transactions;
