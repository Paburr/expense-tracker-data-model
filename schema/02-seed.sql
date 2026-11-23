-- ---------------------------------------------------------------------------
-- Synthetic seed data for expense-tracker-data-model
-- ---------------------------------------------------------------------------
-- Every row below is invented. Merchants are generic placeholders, cards are
-- fakes, amounts are plausible but made up. No real person, card, merchant or
-- statement is represented.
-- ---------------------------------------------------------------------------

INSERT INTO currency (id, code, symbol) VALUES
    (1, 'GTQ', 'Q'),
    (2, 'USD', '$');

INSERT INTO card (id, label, last_digits) VALUES
    (1, 'Tarjeta Demo A', 4321),
    (2, 'Tarjeta Demo B', 8765),
    (3, 'Tarjeta Demo C', 1357);

INSERT INTO capture_batch (id, channel, captured_on, note) VALUES
    (1, 'ocr',          '2025-03-03', 'March statement, single page'),
    (2, 'ocr',          '2025-04-02', 'April statement, single page'),
    (3, 'manual',       '2025-04-18', 'Manual entries for April'),
    (4, 'ocr',          '2025-05-02', 'May statement, single page'),
    (5, 'notification', '2025-05-10', 'Card notifications ingested'),
    (6, 'ocr',          '2025-03-20', 'March statement scanned a second time by mistake');

INSERT INTO payment_batch (id, paid_on, currency_id, card_id, note) VALUES
    (1, '2025-03-25', 1, 1, 'March settlement, Tarjeta Demo A'),
    (2, '2025-04-30', 1, NULL, 'April settlement, all cards'),
    (3, '2025-05-20', 2, 3, 'May settlement, Tarjeta Demo C');

INSERT INTO expense (id, currency_id, card_id, capture_batch_id, description,
                     amount_cents, spent_on, is_edited, created_at, payment_batch_id) VALUES
    -- March statement (batch 1)
    (1,  1, 1,    1, 'Supermercado Demo',      42500, '2025-03-03', 0, '2025-03-03T10:00:00', 1),
    (2,  1, 1,    1, 'Farmacia Ejemplo',       12750, '2025-03-04', 0, '2025-03-03T10:01:00', 1),
    (3,  1, 2,    1, 'Comercio Ejemplo',       25000, '2025-03-05', 0, '2025-03-03T10:02:00', NULL),
    (4,  1, 2,    1, 'Estacionamiento Demo',    3500, '2025-03-06', 0, '2025-03-03T10:03:00', NULL),
    (5,  2, 3,    1, 'Tienda Demo Online',      4999, '2025-03-07', 0, '2025-03-03T10:04:00', NULL),
    -- March statement scanned again (batch 6): same currency, amount and
    -- description as expense 1, so the tracker flags it as a duplicate.
    (6,  1, 1,    6, 'Supermercado Demo',      42500, '2025-03-20', 0, '2025-03-20T19:00:00', NULL),
    -- April statement (batch 2)
    (7,  1, 1,    2, 'Supermercado Demo',      47300, '2025-04-02', 0, '2025-04-02T09:10:00', 2),
    (8,  1, 2,    2, 'Comercio Ejemplo',       31200, '2025-04-05', 0, '2025-04-02T09:11:00', 2),
    (9,  1, 1,    2, 'Restaurante Demo',        9900, '2025-04-08', 1, '2025-04-02T09:12:00', 2),
    (10, 2, 3,    2, 'Tienda Demo Online',     12500, '2025-04-09', 0, '2025-04-02T09:13:00', 3),
    -- Manual entries (batch 3)
    (11, 1, 2,    3, 'Comercio Ejemplo',       31200, '2025-04-18', 0, '2025-04-18T20:00:00', NULL),
    (12, 1, NULL, 3, 'Gasto Externo Demo',      5000, '2025-04-19', 0, '2025-04-18T20:05:00', NULL),
    -- May statement (batch 4)
    (13, 1, 1,    4, 'Supermercado Demo',      51000, '2025-05-02', 0, '2025-05-02T08:30:00', NULL),
    (14, 1, 1,    4, 'Farmacia Ejemplo',        8250, '2025-05-03', 0, '2025-05-02T08:31:00', NULL),
    (15, 1, 2,    4, 'Comercio Ejemplo',       22400, '2025-05-06', 0, '2025-05-02T08:32:00', NULL),
    (16, 1, 2,    4, 'Estacionamiento Demo',    3800, '2025-05-07', 0, '2025-05-02T08:33:00', NULL),
    -- Notifications (batch 5)
    (17, 1, 2,    5, 'Comercio Ejemplo',       14500, '2025-05-10', 0, '2025-05-10T12:00:00', NULL),
    (18, 2, 3,    5, 'Tienda Demo Online',      2299, '2025-05-12', 0, '2025-05-10T12:01:00', NULL);

-- Duplicate declarations. The signature is copied from the duplicate row so the
-- composite foreign keys in detected_duplicate can be satisfied only when both
-- expenses really share it.
INSERT INTO detected_duplicate (expense_id, original_expense_id, duplicate_signature, status, detected_on)
SELECT e.id, 1, e.duplicate_signature, 'paid', '2025-03-20'
FROM expense e
WHERE e.id = 6;

INSERT INTO detected_duplicate (expense_id, original_expense_id, duplicate_signature, status, detected_on)
SELECT e.id, 8, e.duplicate_signature, 'pending', '2025-04-18'
FROM expense e
WHERE e.id = 11;

INSERT INTO loan_payment_batch (id, paid_on, currency_id, note) VALUES
    (1, '2025-04-20', 1, 'April settlement of outstanding loans');

INSERT INTO loan (id, currency_id, description, amount_cents, lent_on, created_at, loan_payment_batch_id) VALUES
    (1, 1, 'Préstamo de ejemplo 1', 100000, '2025-03-10', '2025-03-10T09:00:00', 1),
    (2, 1, 'Préstamo de ejemplo 2',  45000, '2025-04-12', '2025-04-12T18:30:00', NULL),
    (3, 2, 'Préstamo de ejemplo 3',   6000, '2025-05-05', '2025-05-05T11:15:00', NULL),
    (4, 1, 'Préstamo de ejemplo 4',  20000, '2025-03-28', '2025-03-28T16:45:00', 1);
