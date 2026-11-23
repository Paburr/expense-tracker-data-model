-- ---------------------------------------------------------------------------
-- expense-tracker-data-model — relational schema for a multi-currency expense tracker
-- ---------------------------------------------------------------------------
-- Portable dialect: standard SQL that runs unchanged on SQLite 3.31+ and on
-- PostgreSQL 12+ (STORED generated columns). No AUTOINCREMENT, no SERIAL, no
-- ENUM types, no vendor functions. Every primary key is an explicit surrogate
-- integer, supplied by the writer of the row.
--
-- Money is stored as integer minor units (cents) to avoid floating point
-- drift; the source application kept amounts as JavaScript numbers and
-- rounded them with toFixed(2) at comparison time.
--
-- Foreign keys are enforced by the engine. SQLite needs
-- `PRAGMA foreign_keys = ON` per connection (verify.py does this);
-- PostgreSQL enforces them by default.
-- ---------------------------------------------------------------------------

-- Supported currencies. The source hard-codes GTQ and USD in the UI and in the
-- duplicate signature, so the set is closed here as well.
CREATE TABLE currency (
    id     INTEGER NOT NULL PRIMARY KEY,
    code   TEXT    NOT NULL,             -- ISO 4217 style code, e.g. 'GTQ'
    symbol TEXT    NOT NULL,             -- display symbol, e.g. 'Q'
    CONSTRAINT uq_currency_code UNIQUE (code),
    CONSTRAINT ck_currency_code_supported CHECK (code IN ('GTQ', 'USD'))
);

-- Payment card profiles. The source UI asked for a name and the last digits of
-- the card and allowed 1 to 4 digits; the model keeps the digits as an integer
-- so "digits only" is a type-level guarantee instead of a regex check.
CREATE TABLE card (
    id          INTEGER NOT NULL PRIMARY KEY,
    label       TEXT    NOT NULL,        -- e.g. 'Tarjeta Demo A'
    last_digits INTEGER NOT NULL,
    CONSTRAINT uq_card_label UNIQUE (label),
    CONSTRAINT ck_card_last_digits_range CHECK (last_digits BETWEEN 0 AND 9999)
);

-- One capture session: a scanned statement image, a manual entry session or an
-- ingested bank notification. The source had an OCR batch flow but did not
-- persist the session itself; this table records what the UI already implied.
CREATE TABLE capture_batch (
    id          INTEGER NOT NULL PRIMARY KEY,
    channel     TEXT    NOT NULL,
    captured_on TEXT    NOT NULL,        -- ISO 8601 date, 'YYYY-MM-DD'
    note        TEXT,
    CONSTRAINT ck_capture_batch_channel CHECK (channel IN ('manual', 'ocr', 'notification'))
);

-- A settlement run: the moment a set of expenses was marked as paid. The source
-- stored this as a `payments` document holding currency, total and the card
-- filter used; the total is derived from the linked expenses here.
CREATE TABLE payment_batch (
    id          INTEGER NOT NULL PRIMARY KEY,
    paid_on     TEXT    NOT NULL,        -- ISO 8601 date, 'YYYY-MM-DD'
    currency_id INTEGER NOT NULL,
    card_id     INTEGER,                 -- NULL = mixed cards ('TODOS' in the source UI)
    note        TEXT,
    CONSTRAINT fk_payment_batch_currency FOREIGN KEY (currency_id) REFERENCES currency (id),
    CONSTRAINT fk_payment_batch_card FOREIGN KEY (card_id) REFERENCES card (id)
);

-- A card expense.
--
-- duplicate_signature is the database expression of the source duplicate rule
-- `currency + amount + description`: currency id, amount in cents and the
-- description upper-cased with spaces, hyphens and underscores removed (the
-- source normalized with /[\s\-_]/g). The card is deliberately NOT part of the
-- signature, exactly as in the source.
CREATE TABLE expense (
    id                     INTEGER NOT NULL PRIMARY KEY,
    currency_id            INTEGER NOT NULL,
    card_id                INTEGER,      -- NULL = external / cash expense
    capture_batch_id       INTEGER NOT NULL,
    description            TEXT    NOT NULL,
    description_normalized TEXT GENERATED ALWAYS AS (
                               REPLACE(REPLACE(REPLACE(UPPER(TRIM(description)), ' ', ''), '-', ''), '_', '')
                           ) STORED,
    amount_cents           INTEGER NOT NULL,
    spent_on               TEXT    NOT NULL,   -- ISO 8601 date, 'YYYY-MM-DD'
    is_edited              INTEGER NOT NULL DEFAULT 0,
    created_at             TEXT    NOT NULL,   -- ISO 8601 timestamp
    payment_batch_id       INTEGER,            -- NULL = still outstanding
    duplicate_signature    TEXT GENERATED ALWAYS AS (
                               CAST(currency_id AS TEXT) || '|' || CAST(amount_cents AS TEXT) || '|' ||
                               REPLACE(REPLACE(REPLACE(UPPER(TRIM(description)), ' ', ''), '-', ''), '_', '')
                           ) STORED,
    CONSTRAINT ck_expense_amount_positive CHECK (amount_cents > 0),
    CONSTRAINT ck_expense_is_edited CHECK (is_edited IN (0, 1)),
    CONSTRAINT fk_expense_currency FOREIGN KEY (currency_id) REFERENCES currency (id),
    CONSTRAINT fk_expense_card FOREIGN KEY (card_id) REFERENCES card (id),
    CONSTRAINT fk_expense_capture_batch FOREIGN KEY (capture_batch_id) REFERENCES capture_batch (id),
    CONSTRAINT fk_expense_payment_batch FOREIGN KEY (payment_batch_id) REFERENCES payment_batch (id),
    -- Referenced by detected_duplicate, which pins both copies to one signature.
    CONSTRAINT uq_expense_id_signature UNIQUE (id, duplicate_signature)
);

-- A duplicate found by the tracker. Both the suspect expense and the original
-- must exist and must share the same duplicate_signature, which the composite
-- foreign keys below enforce: a duplicate declaration that does not match the
-- rule is rejected by the database, not by application code.
--
-- `status` mirrors the source alerts: 'pending' when the original is still
-- unpaid (yellow warning) and 'paid' when the original was already settled
-- (red critical warning).
CREATE TABLE detected_duplicate (
    expense_id          INTEGER NOT NULL PRIMARY KEY,
    original_expense_id INTEGER NOT NULL,
    duplicate_signature TEXT    NOT NULL,
    status              TEXT    NOT NULL,
    detected_on         TEXT    NOT NULL,
    CONSTRAINT fk_detected_duplicate_expense
        FOREIGN KEY (expense_id, duplicate_signature) REFERENCES expense (id, duplicate_signature),
    CONSTRAINT fk_detected_duplicate_original
        FOREIGN KEY (original_expense_id, duplicate_signature) REFERENCES expense (id, duplicate_signature),
    CONSTRAINT ck_detected_duplicate_distinct CHECK (expense_id <> original_expense_id),
    CONSTRAINT ck_detected_duplicate_status CHECK (status IN ('pending', 'paid'))
);

-- Money lent to a third party. The source never stored the borrower, only a
-- free-text description, so no person data is modelled here.
CREATE TABLE loan_payment_batch (
    id          INTEGER NOT NULL PRIMARY KEY,
    paid_on     TEXT    NOT NULL,        -- ISO 8601 date, 'YYYY-MM-DD'
    currency_id INTEGER NOT NULL,
    note        TEXT,
    CONSTRAINT fk_loan_payment_batch_currency FOREIGN KEY (currency_id) REFERENCES currency (id)
);

CREATE TABLE loan (
    id                    INTEGER NOT NULL PRIMARY KEY,
    currency_id           INTEGER NOT NULL,
    description           TEXT    NOT NULL,
    amount_cents          INTEGER NOT NULL,
    lent_on               TEXT    NOT NULL,     -- ISO 8601 date, 'YYYY-MM-DD'
    created_at            TEXT    NOT NULL,     -- ISO 8601 timestamp
    loan_payment_batch_id INTEGER,              -- NULL = still outstanding
    CONSTRAINT ck_loan_amount_positive CHECK (amount_cents > 0),
    CONSTRAINT fk_loan_currency FOREIGN KEY (currency_id) REFERENCES currency (id),
    CONSTRAINT fk_loan_payment_batch FOREIGN KEY (loan_payment_batch_id) REFERENCES loan_payment_batch (id)
);

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

-- The hard duplicate rule: one capture session cannot produce the same
-- signature twice. A statement scanned twice by mistake is rejected.
CREATE UNIQUE INDEX uq_expense_batch_signature ON expense (capture_batch_id, duplicate_signature);

-- Monthly spend per currency, and the paid history range filters.
CREATE INDEX ix_expense_currency_spent_on ON expense (currency_id, spent_on);

-- Spend per card.
CREATE INDEX ix_expense_card ON expense (card_id);

-- Settlement detail screens: which expenses belong to a payment batch.
CREATE INDEX ix_expense_payment_batch ON expense (payment_batch_id);

-- Duplicate review screens: which copies point at an original.
CREATE INDEX ix_detected_duplicate_original ON detected_duplicate (original_expense_id);

-- Settlement batch lists ordered by date.
CREATE INDEX ix_payment_batch_paid_on ON payment_batch (currency_id, paid_on);
CREATE INDEX ix_loan_payment_batch_paid_on ON loan_payment_batch (currency_id, paid_on);

-- Outstanding loans per currency.
CREATE INDEX ix_loan_currency_lent_on ON loan (currency_id, lent_on);
CREATE INDEX ix_loan_payment_batch ON loan (loan_payment_batch_id);

-- ---------------------------------------------------------------------------
-- Integrity view
-- ---------------------------------------------------------------------------

-- Every expense that repeats an earlier signature must be declared in
-- detected_duplicate. The view lists violations; verify.py asserts it is empty
-- for the seed, and it is the query to run after any bulk import.
CREATE VIEW v_undeclared_duplicate AS
SELECT e.id                     AS expense_id,
       e.duplicate_signature    AS duplicate_signature,
       e.description            AS description,
       e.amount_cents           AS amount_cents,
       e.spent_on               AS spent_on
FROM expense e
WHERE e.id > (SELECT MIN(first_expense.id)
              FROM expense first_expense
              WHERE first_expense.duplicate_signature = e.duplicate_signature)
  AND NOT EXISTS (SELECT 1
                  FROM detected_duplicate d
                  WHERE d.expense_id = e.id);
