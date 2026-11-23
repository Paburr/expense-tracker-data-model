-- Business question: how much is spent each month, per currency?
-- One row per (month, currency), including how much of it was already settled.
SELECT cur.code                                  AS currency_code,
       SUBSTR(e.spent_on, 1, 7)                  AS month,
       COUNT(*)                                  AS expense_count,
       ROUND(SUM(e.amount_cents) / 100.0, 2)     AS total_amount,
       ROUND(SUM(CASE WHEN e.payment_batch_id IS NOT NULL THEN e.amount_cents ELSE 0 END) / 100.0, 2) AS settled_amount,
       ROUND(SUM(CASE WHEN e.payment_batch_id IS NULL THEN e.amount_cents ELSE 0 END) / 100.0, 2)     AS outstanding_amount
FROM expense e
JOIN currency cur ON cur.id = e.currency_id
GROUP BY cur.code, SUBSTR(e.spent_on, 1, 7)
ORDER BY month, currency_code;
