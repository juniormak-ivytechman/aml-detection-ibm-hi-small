-- ============================================================
-- AML Detection Project — 01_cache_tables.sql
-- IBM HI-Small Dataset | DuckDB
-- Author: Junior Radebe
--
-- I chose cache tables over views for a specific reason: views
-- recalculate from 5M rows every time Power BI queries them.
-- That means every dashboard refresh was scanning the full
-- dataset repeatedly — slow and unstable on my machine.
--
-- Cache tables store the pre-aggregated result as a real table.
-- Power BI imports them as static CSVs. Rebuild cost is paid
-- once; every query after that is instant.
--
-- Run order:
--   1. 00_schema.sql
--   2. 04_validation_queries.sql (confirm the import)
--   3. THIS FILE
--   4. 03_export_cache_tables.sql (export CSVs for Power BI)
-- ============================================================


-- ── CACHE TABLE 1: Daily Summary ────────────────────────────
-- Powers the Page 1 time-series charts and KPI totals.
-- I grouped by payment format and currency as well so I could
-- filter by channel in Power BI without needing a separate table.
-- Produces ~70 rows (20 days × format/currency combinations).

CREATE OR REPLACE TABLE daily_summary_cache AS
SELECT
    CAST(transaction_ts AS DATE)                AS txn_date,
    DAYNAME(transaction_ts)                     AS day_of_week,
    payment_format,
    payment_currency,
    receiving_currency,
    COUNT(*)                                    AS total_transactions,
    SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END)
                                                AS suspicious_count,
    COUNT(*) - SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END)
                                                AS legitimate_count,
    ROUND(
        SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END) * 100.0 / COUNT(*),
    4)                                          AS laundering_rate_pct,
    ROUND(SUM(amount_paid), 2)                  AS total_volume_usd,
    ROUND(SUM(CASE WHEN is_laundering THEN amount_paid ELSE 0 END), 2)
                                                AS suspicious_volume_usd
FROM transactions
GROUP BY
    CAST(transaction_ts AS DATE),
    DAYNAME(transaction_ts),
    payment_format,
    payment_currency,
    receiving_currency
ORDER BY txn_date;

SELECT COUNT(*) AS daily_summary_rows FROM daily_summary_cache;
-- ~70 rows


-- ── CACHE TABLE 2: Payment Format Risk ──────────────────────
-- Powers the payment format risk chart on Page 2 and the
-- payment channel donut on Page 1.
-- ACH came out as the dominant suspicious channel (0.75% rate,
-- 86.59% of all suspicious transactions) which I found notable
-- given it's also the most commonly used format overall.

CREATE OR REPLACE TABLE payment_format_cache AS
SELECT
    payment_format,
    COUNT(*)                                    AS total_transactions,
    SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END)
                                                AS suspicious_count,
    ROUND(
        SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END) * 100.0 / COUNT(*),
    4)                                          AS laundering_rate_pct,
    ROUND(SUM(amount_paid), 2)                  AS total_volume_usd,
    ROUND(AVG(amount_paid), 2)                  AS avg_amount_usd,
    ROUND(MAX(amount_paid), 2)                  AS max_amount_usd
FROM transactions
GROUP BY payment_format
ORDER BY laundering_rate_pct DESC;

SELECT COUNT(*) AS payment_format_rows FROM payment_format_cache;
-- ~6 rows (one per payment format)


-- ── CACHE TABLE 3: Bank Risk ─────────────────────────────────
-- Powers the bank risk summary on Page 3 and the suspicious
-- volume by bank chart on Page 1.
-- I ordered by suspicious volume descending so the highest
-- exposure banks sit at the top in the Power BI table by default.

CREATE OR REPLACE TABLE bank_risk_cache AS
SELECT
    from_bank                                   AS bank_name,
    COUNT(*)                                    AS outbound_txns,
    SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END)
                                                AS outbound_suspicious,
    ROUND(
        SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END) * 100.0 / COUNT(*),
    4)                                          AS outbound_laundering_rate_pct,
    ROUND(SUM(amount_paid), 2)                  AS outbound_volume_usd,
    ROUND(SUM(CASE WHEN is_laundering THEN amount_paid ELSE 0 END), 2)
                                                AS outbound_suspicious_volume_usd,
    COUNT(DISTINCT from_account)                AS unique_accounts
FROM transactions
GROUP BY from_bank
ORDER BY outbound_suspicious_volume_usd DESC;

SELECT COUNT(*) AS bank_risk_rows FROM bank_risk_cache;
-- ~15–20 rows (one per bank)


-- ── CACHE TABLE 4: Account Risk ─────────────────────────────
-- Powers the account risk leaderboard on Page 3 and the scatter
-- plot on Page 2. Also the source for drill-through — when an
-- analyst right-clicks an account on Page 3, account_id filters
-- the suspicious_transactions_cache on Page 4.
--
-- Risk score is a composite of four components (0–100 cap):
--   suspicion_rate_pct        primary driver
--   payment_formats_used × 5  using multiple channels signals obfuscation
--   volume bonus (+10)         accounts with > 50 transactions get flagged
--   cross_currency_txns × 2   currency conversion adds layering complexity
--
-- I capped results at the top 500 accounts. The full suspicious
-- account list is much larger but 500 covers all meaningful risk tiers.

CREATE OR REPLACE TABLE account_risk_cache AS
SELECT
    from_account                                AS account_id,
    from_bank                                   AS bank,
    COUNT(*)                                    AS total_txns,
    SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END)
                                                AS suspicious_txns,
    ROUND(
        SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END) * 100.0 / COUNT(*),
    2)                                          AS suspicion_rate_pct,
    ROUND(SUM(amount_paid), 2)                  AS total_volume_usd,
    SUM(CASE WHEN payment_currency <> receiving_currency THEN 1 ELSE 0 END)
                                                AS cross_currency_txns,
    COUNT(DISTINCT to_account)                  AS unique_counterparties,
    COUNT(DISTINCT payment_format)              AS payment_formats_used,
    LEAST(100, ROUND(
        (SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END) * 100.0 / COUNT(*))
        + (COUNT(DISTINCT payment_format) * 5)
        + (CASE WHEN COUNT(*) > 50 THEN 10 ELSE COUNT(*) * 0.2 END)
        + (SUM(CASE WHEN payment_currency <> receiving_currency THEN 1 ELSE 0 END) * 2)
    , 2))                                       AS risk_score
FROM transactions
GROUP BY from_account, from_bank
HAVING SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END) > 0
ORDER BY risk_score DESC
LIMIT 500;

SELECT COUNT(*) AS account_risk_rows FROM account_risk_cache;
-- 500 rows


-- ── CACHE TABLE 5: Hourly Heatmap ───────────────────────────
-- Powers the day-hour heatmap on Page 2.
-- I included day_num (numeric day of week) so I could sort the
-- matrix rows correctly in Power BI — without it, Power BI
-- sorts days alphabetically (Friday, Monday, Saturday...) which
-- makes the heatmap confusing to read.

CREATE OR REPLACE TABLE hourly_heatmap_cache AS
SELECT
    DAYNAME(transaction_ts)                     AS day_of_week,
    DAYOFWEEK(transaction_ts)                   AS day_num,
    HOUR(transaction_ts)                        AS hour_of_day,
    COUNT(*)                                    AS total_transactions,
    SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END)
                                                AS suspicious_count,
    ROUND(
        SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END) * 100.0 / COUNT(*),
    4)                                          AS laundering_rate_pct,
    ROUND(SUM(amount_paid), 2)                  AS total_volume_usd
FROM transactions
GROUP BY
    DAYNAME(transaction_ts),
    DAYOFWEEK(transaction_ts),
    HOUR(transaction_ts)
ORDER BY day_num, hour_of_day;

SELECT COUNT(*) AS heatmap_rows FROM hourly_heatmap_cache;
-- ~70 rows (7 days × hours that have data)


-- ── CACHE TABLE 6: Suspicious Transactions ──────────────────
-- Powers the drill-through detail page (Page 4).
-- This is the only cache table that keeps individual rows rather
-- than aggregating. Every confirmed suspicious transaction is here
-- with enough context for SAR preparation — counterparties,
-- amounts, currencies, payment method, and a cross-currency flag.

CREATE OR REPLACE TABLE suspicious_transactions_cache AS
SELECT
    transaction_id,
    transaction_ts,
    from_bank,
    from_account,
    to_bank,
    to_account,
    ROUND(amount_paid, 2)                       AS amount_paid,
    payment_currency,
    ROUND(amount_received, 2)                   AS amount_received,
    receiving_currency,
    payment_format,
    CASE WHEN payment_currency <> receiving_currency
        THEN 'Yes' ELSE 'No'
    END                                         AS is_cross_currency
FROM transactions
WHERE is_laundering = TRUE
ORDER BY transaction_ts;

SELECT COUNT(*) AS suspicious_txn_rows FROM suspicious_transactions_cache;
-- ~5,000 rows (0.10% of 5M)


-- ── CACHE TABLE 7: Currency Pair Risk ───────────────────────
-- Powers the currency pair bar chart on Page 2.
-- I filtered to pairs with at least 50 transactions to avoid
-- noise from one-off currency combinations skewing the rate.
-- Saudi Riyal → Saudi Riyal came out highest at 0.42% —
-- an unexpected finding since it's a same-currency pair.

CREATE OR REPLACE TABLE currency_pair_cache AS
SELECT
    payment_currency || ' → ' || receiving_currency
                                                AS currency_pair,
    payment_currency,
    receiving_currency,
    COUNT(*)                                    AS total_transactions,
    SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END)
                                                AS suspicious_count,
    ROUND(
        SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END) * 100.0 / COUNT(*),
    4)                                          AS laundering_rate_pct,
    ROUND(SUM(amount_paid), 2)                  AS total_volume_usd
FROM transactions
GROUP BY payment_currency, receiving_currency
HAVING total_transactions >= 50
ORDER BY laundering_rate_pct DESC;

SELECT COUNT(*) AS currency_pair_rows FROM currency_pair_cache;


-- ── ALL CACHE TABLES: Final check ───────────────────────────
SELECT 'daily_summary_cache'          AS cache_table, COUNT(*) AS rows FROM daily_summary_cache
UNION ALL
SELECT 'payment_format_cache',                         COUNT(*) FROM payment_format_cache
UNION ALL
SELECT 'bank_risk_cache',                              COUNT(*) FROM bank_risk_cache
UNION ALL
SELECT 'account_risk_cache',                           COUNT(*) FROM account_risk_cache
UNION ALL
SELECT 'hourly_heatmap_cache',                         COUNT(*) FROM hourly_heatmap_cache
UNION ALL
SELECT 'suspicious_transactions_cache',                COUNT(*) FROM suspicious_transactions_cache
UNION ALL
SELECT 'currency_pair_cache',                          COUNT(*) FROM currency_pair_cache
ORDER BY cache_table;
