-- Business question: where does the money actually go?
-- Merchants are grouped by the normalized description, the same normalization
-- used by the duplicate signature, so 'Super mercado Demo' and
-- 'SUPERMERCADO-DEMO' count as one merchant.
SELECT cur.code                                  AS currency_code,
       MAX(e.description)                        AS merchant,
       COUNT(*)                                  AS expense_count,
       ROUND(SUM(e.amount_cents) / 100.0, 2)     AS total_amount
FROM expense e
JOIN currency cur ON cur.id = e.currency_id
GROUP BY cur.code, e.description_normalized
ORDER BY total_amount DESC, merchant
LIMIT 10;
