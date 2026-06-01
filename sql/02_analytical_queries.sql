-- ============================================================
-- AML Detection Project — 02_analytical_queries.sql
-- IBM HI-Small Dataset | DuckDB
-- Author: Junior Radebe
--
-- These are the queries I wrote to investigate the data directly
-- in DuckDB — typology detection, entity tracing, pattern analysis.
-- They're not used by Power BI (the dashboard uses the cache table
-- CSVs). These are for running in the DuckDB CLI when I needed
-- to dig deeper than what the dashboard shows.
--
-- A key optimisation I applied throughout: filter to
-- is_laundering = TRUE first. That drops the working set from
-- 5M rows to ~5K before any grouping or joining happens.
-- Without that, most of these queries timed out.
-- ============================================================


-- ════════════════════════════════════════════════════════════
-- SECTION 1: BASELINE KPIs
-- ════════════════════════════════════════════════════════════

-- Full dataset summary — I ran this first to get a feel for the
-- shape of the data before writing any typology queries.
SELECT
    COUNT(*)                                                AS total_transactions,
    SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END)         AS suspicious_count,
    COUNT(*) - SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END)
                                                            AS legitimate_count,
    ROUND(
        SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END) * 100.0 / COUNT(*),
    4)                                                      AS laundering_rate_pct,
    ROUND(SUM(amount_paid), 2)                              AS total_volume_usd,
    ROUND(SUM(CASE WHEN is_laundering THEN amount_paid ELSE 0 END), 2)
                                                            AS suspicious_volume_usd,
    ROUND(AVG(amount_paid), 2)                              AS avg_transaction_usd,
    COUNT(DISTINCT from_account)                            AS unique_senders,
    COUNT(DISTINCT to_account)                              AS unique_receivers,
    COUNT(DISTINCT from_bank)                               AS unique_banks
FROM transactions;


-- Cross-currency rate — I checked this early because cross-currency
-- transactions are a common layering signal. Turned out same-currency
-- pairs dominated suspicious activity, which was an unexpected finding.
SELECT
    COUNT(*)                                                AS total_transactions,
    SUM(CASE WHEN payment_currency <> receiving_currency THEN 1 ELSE 0 END)
                                                            AS cross_currency_count,
    ROUND(
        SUM(CASE WHEN payment_currency <> receiving_currency THEN 1 ELSE 0 END)
        * 100.0 / COUNT(*),
    2)                                                      AS cross_currency_rate_pct,
    SUM(CASE WHEN payment_currency <> receiving_currency
             AND is_laundering THEN 1 ELSE 0 END)          AS cross_currency_suspicious,
    ROUND(
        SUM(CASE WHEN payment_currency <> receiving_currency
                 AND is_laundering THEN 1 ELSE 0 END)
        * 100.0 /
        NULLIF(SUM(CASE WHEN payment_currency <> receiving_currency
                   THEN 1 ELSE 0 END), 0),
    4)                                                      AS cross_currency_laundering_rate_pct
FROM transactions;


-- ════════════════════════════════════════════════════════════
-- SECTION 2: TYPOLOGY DETECTION
-- ════════════════════════════════════════════════════════════

-- ── Typology 1: Structuring (Smurfing) ──────────────────────
-- I looked for accounts repeatedly transacting just below the
-- $10,000 CTR threshold — classic structuring behaviour.
-- Filtered to suspicious transactions only so the query stays fast.

SELECT
    from_account,
    from_bank,
    COUNT(*)                                    AS transaction_count,
    ROUND(SUM(amount_paid), 2)                  AS total_amount_usd,
    ROUND(AVG(amount_paid), 2)                  AS avg_amount_usd,
    SUM(CASE WHEN amount_paid BETWEEN 9000 AND 9999.99 THEN 1 ELSE 0 END)
                                                AS count_in_9k_band,
    SUM(CASE WHEN amount_paid BETWEEN 4500 AND 4999.99 THEN 1 ELSE 0 END)
                                                AS count_in_4k5_band,
    MIN(transaction_ts)                         AS first_txn,
    MAX(transaction_ts)                         AS last_txn
FROM transactions
WHERE is_laundering = TRUE
  AND amount_paid BETWEEN 4500 AND 9999.99
GROUP BY from_account, from_bank
HAVING (count_in_9k_band + count_in_4k5_band) >= 3
ORDER BY (count_in_9k_band + count_in_4k5_band) DESC
LIMIT 100;


-- ── Typology 2: Pass-Through Accounts (Layering) ────────────
-- I looked for accounts appearing as both sender and receiver
-- in suspicious transactions — a strong layering indicator.
-- I used temp tables here because self-joining the full 5M-row
-- table timed out. Pre-aggregate first, then join the small sets.

CREATE OR REPLACE TEMP TABLE outbound AS
SELECT
    from_account                                AS account_id,
    from_bank                                   AS bank,
    COUNT(*)                                    AS outbound_count,
    SUM(amount_paid)                            AS outbound_volume,
    SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END)
                                                AS outbound_laundering
FROM transactions
WHERE is_laundering = TRUE
GROUP BY from_account, from_bank;

CREATE OR REPLACE TEMP TABLE inbound AS
SELECT
    to_account                                  AS account_id,
    to_bank                                     AS bank,
    COUNT(*)                                    AS inbound_count,
    SUM(amount_received)                        AS inbound_volume,
    SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END)
                                                AS inbound_laundering
FROM transactions
WHERE is_laundering = TRUE
GROUP BY to_account, to_bank;

SELECT
    o.account_id,
    o.bank,
    o.outbound_count,
    o.outbound_laundering,
    i.inbound_count,
    i.inbound_laundering,
    ROUND(o.outbound_volume / NULLIF(i.inbound_volume, 0), 4)
                                                AS outbound_to_inbound_ratio
FROM outbound o
INNER JOIN inbound i
    ON o.account_id = i.account_id
   AND o.bank       = i.bank
ORDER BY (o.outbound_laundering + i.inbound_laundering) DESC
LIMIT 100;


-- ── Typology 3: Fan-Out (Placement) ─────────────────────────
-- Single sender distributing to many unique receivers.
-- The 603 accounts in the dashboard with >= 5 counterparties
-- came from this logic.

SELECT
    from_account,
    from_bank,
    COUNT(*)                                    AS total_transactions,
    SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END)
                                                AS laundering_txns,
    COUNT(DISTINCT to_account)                  AS unique_receivers,
    ROUND(SUM(amount_paid), 2)                  AS total_sent_usd
FROM transactions
WHERE is_laundering = TRUE
GROUP BY from_account, from_bank
HAVING unique_receivers >= 5
ORDER BY laundering_txns DESC
LIMIT 50;


-- ── Typology 4: Fan-In (Integration) ────────────────────────
-- Many senders converging on a single receiver — integration stage.

SELECT
    to_account,
    to_bank,
    COUNT(*)                                    AS total_transactions,
    SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END)
                                                AS laundering_txns,
    COUNT(DISTINCT from_account)                AS unique_senders,
    ROUND(SUM(amount_received), 2)              AS total_received_usd
FROM transactions
WHERE is_laundering = TRUE
GROUP BY to_account, to_bank
HAVING unique_senders >= 5
ORDER BY laundering_txns DESC
LIMIT 50;


-- ── Typology 5: Round-Number Transactions ───────────────────
-- Exact multiples of $1,000 in suspicious transactions.
-- Natural economic activity rarely produces perfectly round amounts —
-- these suggest manual entry or deliberate structuring.

SELECT
    amount_paid,
    COUNT(*)                                    AS transaction_count,
    SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END)
                                                AS laundering_count,
    ROUND(
        SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END) * 100.0 / COUNT(*),
    2)                                          AS laundering_rate_pct,
    COUNT(DISTINCT from_account)                AS unique_senders
FROM transactions
WHERE amount_paid = ROUND(amount_paid / 1000, 0) * 1000
  AND amount_paid >= 5000
  AND is_laundering = TRUE
GROUP BY amount_paid
ORDER BY laundering_count DESC
LIMIT 50;


-- ════════════════════════════════════════════════════════════
-- SECTION 3: ENTITY INVESTIGATION
-- ════════════════════════════════════════════════════════════

-- ── Account trace ────────────────────────────────────────────
-- I used this to pull everything for a specific account —
-- both what it sent and what it received — for case building.
-- Change the account ID and bank to whichever account you're tracing.

SELECT
    'OUTBOUND'                                  AS direction,
    transaction_ts,
    to_bank                                     AS counterparty_bank,
    to_account                                  AS counterparty_account,
    ROUND(amount_paid, 2)                       AS amount_usd,
    payment_currency,
    payment_format,
    is_laundering
FROM transactions
WHERE from_account = '100428660'
  AND from_bank    = '70'

UNION ALL

SELECT
    'INBOUND',
    transaction_ts,
    from_bank,
    from_account,
    ROUND(amount_received, 2),
    receiving_currency,
    payment_format,
    is_laundering
FROM transactions
WHERE to_account = '100428660'
  AND to_bank    = '70'

ORDER BY transaction_ts;


-- ── Top risky accounts at a specific bank ────────────────────
-- I ran this per bank to understand risk concentration.
-- Change '70' to whichever bank you want to drill into.

SELECT
    from_account,
    COUNT(*)                                    AS total_txns,
    SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END)
                                                AS suspicious_txns,
    ROUND(
        SUM(CASE WHEN is_laundering THEN 1 ELSE 0 END) * 100.0 / COUNT(*),
    2)                                          AS risk_rate_pct,
    ROUND(SUM(amount_paid), 2)                  AS total_volume_usd,
    MIN(transaction_ts)                         AS first_txn,
    MAX(transaction_ts)                         AS last_txn
FROM transactions
WHERE from_bank = '70'
GROUP BY from_account
HAVING suspicious_txns > 0
ORDER BY suspicious_txns DESC, risk_rate_pct DESC
LIMIT 20;


-- ── Date-range suspicious activity breakdown ─────────────────
-- I used this to pull a day-by-day breakdown for specific
-- periods — useful for correlating spikes with calendar events.

SELECT
    CAST(transaction_ts AS DATE)                AS txn_date,
    payment_format,
    COUNT(*)                                    AS suspicious_count,
    ROUND(SUM(amount_paid), 2)                  AS suspicious_volume_usd,
    COUNT(DISTINCT from_account)                AS unique_accounts,
    COUNT(DISTINCT from_bank)                   AS unique_banks
FROM transactions
WHERE is_laundering = TRUE
  AND CAST(transaction_ts AS DATE) BETWEEN '2022-09-01' AND '2022-09-10'
GROUP BY CAST(transaction_ts AS DATE), payment_format
ORDER BY txn_date, suspicious_volume_usd DESC;
