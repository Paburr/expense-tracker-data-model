-- Business question: which captures were flagged as duplicates, and how
-- critical are they?
-- 'paid' means the original expense was already settled (critical warning in
-- the source UI); 'pending' means the original is still outstanding.
SELECT d.status                                  AS duplicate_status,
       cur.code                                  AS currency_code,
       original.spent_on                         AS original_spent_on,
       duplicate.spent_on                        AS duplicate_spent_on,
       ROUND(duplicate.amount_cents / 100.0, 2)  AS amount,
       duplicate.description                     AS description,
       COALESCE(original_card.label, 'external') AS original_card,
       COALESCE(duplicate_card.label, 'external') AS duplicate_card
FROM detected_duplicate d
JOIN expense duplicate ON duplicate.id = d.expense_id
JOIN expense original ON original.id = d.original_expense_id
JOIN currency cur ON cur.id = duplicate.currency_id
LEFT JOIN card original_card ON original_card.id = original.card_id
LEFT JOIN card duplicate_card ON duplicate_card.id = duplicate.card_id
ORDER BY d.status, original.spent_on;
