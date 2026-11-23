-- Business question: how much money is still owed to me, per currency?
-- Only loans without a settlement batch are outstanding. The window function
-- adds the per-currency outstanding total to every row of that currency.
SELECT cur.code                                  AS currency_code,
       l.lent_on                                 AS lent_on,
       l.description                             AS description,
       ROUND(l.amount_cents / 100.0, 2)          AS amount,
       ROUND(SUM(l.amount_cents) OVER (PARTITION BY cur.code) / 100.0, 2) AS outstanding_total_by_currency
FROM loan l
JOIN currency cur ON cur.id = l.currency_id
WHERE l.loan_payment_batch_id IS NULL
ORDER BY cur.code, l.lent_on;
