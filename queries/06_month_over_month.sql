-- Business question: is this month more expensive than the previous one, per
-- currency? Uses a CTE to aggregate and a window function to compare each month
-- with the previous month of the same currency.
WITH monthly AS (
    SELECT cur.code                              AS currency_code,
           SUBSTR(e.spent_on, 1, 7)              AS month,
           SUM(e.amount_cents)                   AS total_cents
    FROM expense e
    JOIN currency cur ON cur.id = e.currency_id
    GROUP BY cur.code, SUBSTR(e.spent_on, 1, 7)
)
SELECT m.currency_code                           AS currency_code,
       m.month                                   AS month,
       ROUND(m.total_cents / 100.0, 2)           AS total_amount,
       ROUND(LAG(m.total_cents) OVER (PARTITION BY m.currency_code ORDER BY m.month) / 100.0, 2) AS previous_month_amount,
       ROUND((m.total_cents - LAG(m.total_cents) OVER (PARTITION BY m.currency_code ORDER BY m.month)) * 100.0
             / LAG(m.total_cents) OVER (PARTITION BY m.currency_code ORDER BY m.month), 2) AS change_percent
FROM monthly m
ORDER BY m.currency_code, m.month;
