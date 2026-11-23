-- Business question: which card is carrying the spend, and how much of that is
-- still outstanding?
-- Expenses without a card are grouped under 'external' (cash or unassigned).
SELECT COALESCE(c.label, 'external')             AS card_label,
       cur.code                                  AS currency_code,
       COUNT(*)                                  AS expense_count,
       ROUND(SUM(CASE WHEN e.payment_batch_id IS NULL THEN e.amount_cents ELSE 0 END) / 100.0, 2) AS outstanding_amount,
       ROUND(SUM(e.amount_cents) / 100.0, 2)     AS total_amount
FROM expense e
JOIN currency cur ON cur.id = e.currency_id
LEFT JOIN card c ON c.id = e.card_id
GROUP BY COALESCE(c.label, 'external'), cur.code
ORDER BY outstanding_amount DESC, card_label, currency_code;
