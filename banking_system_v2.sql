-- =====================================================================
-- Banking System Database v2 (MySQL 8.0.16+)
-- 14 tables, created in dependency order, one by one.
-- Changes from v1:
--   * NEW table ledger_entries (immutable debit/credit ledger)
--   * accounts: UNIQUE (account_id, customer_id) to support ownership FK
--   * loans: composite FK so linked account must belong to the same customer
--   * triggers making ledger_entries insert-only
--   * view v_balance_reconciliation to prove balances match the ledger
-- =====================================================================

DROP DATABASE IF EXISTS banking_system;
CREATE DATABASE banking_system CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE banking_system;

-- ---------------------------------------------------------------------
-- 1. branches
-- ---------------------------------------------------------------------
CREATE TABLE branches (
    branch_id    INT AUTO_INCREMENT PRIMARY KEY,
    branch_code  VARCHAR(10)  NOT NULL UNIQUE,
    branch_name  VARCHAR(100) NOT NULL,
    address      VARCHAR(255) NOT NULL,
    city         VARCHAR(50)  NOT NULL,
    status       ENUM('ACTIVE','INACTIVE') NOT NULL DEFAULT 'ACTIVE'
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 2. users
-- ---------------------------------------------------------------------
CREATE TABLE users (
    user_id        INT AUTO_INCREMENT PRIMARY KEY,
    email          VARCHAR(150) NOT NULL UNIQUE,
    password_hash  VARCHAR(255) NOT NULL,
    role           ENUM('CUSTOMER','EMPLOYEE','ADMIN') NOT NULL,
    status         ENUM('ACTIVE','INACTIVE','LOCKED','SUSPENDED') NOT NULL DEFAULT 'ACTIVE',
    created_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 3. customers  (1:1 with users via UNIQUE user_id)
-- ---------------------------------------------------------------------
CREATE TABLE customers (
    customer_id              INT AUTO_INCREMENT PRIMARY KEY,
    user_id                  INT NOT NULL UNIQUE,
    full_name                VARCHAR(100) NOT NULL,
    date_of_birth            DATE NOT NULL,
    phone                    VARCHAR(15)  NOT NULL,
    address                  VARCHAR(255) NOT NULL,
    monthly_spending_budget  DECIMAL(15,2) NULL,
    spending_alerts_enabled  BOOLEAN NOT NULL DEFAULT FALSE,
    CONSTRAINT fk_customers_user
        FOREIGN KEY (user_id) REFERENCES users(user_id),
    CONSTRAINT chk_customers_budget
        CHECK (monthly_spending_budget IS NULL OR monthly_spending_budget >= 0)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 4. employees  (1:1 with users; self-referencing manager)
-- ---------------------------------------------------------------------
CREATE TABLE employees (
    employee_id          INT AUTO_INCREMENT PRIMARY KEY,
    user_id              INT NOT NULL UNIQUE,
    employee_code        VARCHAR(20) NOT NULL UNIQUE,
    branch_id            INT NOT NULL,
    designation          VARCHAR(80) NOT NULL,
    manager_employee_id  INT NULL,
    date_joined          DATE NOT NULL,
    status               ENUM('ACTIVE','ON_LEAVE','TERMINATED') NOT NULL DEFAULT 'ACTIVE',
    CONSTRAINT fk_employees_user
        FOREIGN KEY (user_id) REFERENCES users(user_id),
    CONSTRAINT fk_employees_branch
        FOREIGN KEY (branch_id) REFERENCES branches(branch_id),
    CONSTRAINT fk_employees_manager
        FOREIGN KEY (manager_employee_id) REFERENCES employees(employee_id)
) ENGINE=InnoDB;

-- MySQL does not allow a CHECK constraint to reference an AUTO_INCREMENT
-- column (error 3818), so "an employee cannot be their own manager" is
-- enforced with a trigger instead. (On INSERT it cannot happen, because the
-- manager row must already exist; it can only happen on UPDATE.)
DELIMITER $$

CREATE TRIGGER trg_employees_no_self_manager
BEFORE UPDATE ON employees
FOR EACH ROW
BEGIN
    IF NEW.manager_employee_id IS NOT NULL
       AND NEW.manager_employee_id = NEW.employee_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'An employee cannot be their own manager';
    END IF;
END$$

DELIMITER ;

-- ---------------------------------------------------------------------
-- 5. kyc_records
-- ---------------------------------------------------------------------
CREATE TABLE kyc_records (
    kyc_id                      INT AUTO_INCREMENT PRIMARY KEY,
    customer_id                 INT NOT NULL,
    document_type               ENUM('AADHAAR','PAN','PASSPORT','VOTER_ID','DRIVING_LICENSE') NOT NULL,
    masked_document_reference   VARCHAR(30) NOT NULL,
    status                      ENUM('PENDING','APPROVED','REJECTED') NOT NULL DEFAULT 'PENDING',
    submitted_at                TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    reviewed_by_employee_id     INT NULL,
    reviewed_at                 TIMESTAMP NULL,
    review_note                 VARCHAR(500) NULL,
    CONSTRAINT fk_kyc_customer
        FOREIGN KEY (customer_id) REFERENCES customers(customer_id),
    CONSTRAINT fk_kyc_reviewer
        FOREIGN KEY (reviewed_by_employee_id) REFERENCES employees(employee_id),
    CONSTRAINT chk_kyc_review_consistency
        CHECK (status = 'PENDING' OR (reviewed_by_employee_id IS NOT NULL AND reviewed_at IS NOT NULL))
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 6. account_types
-- ---------------------------------------------------------------------
CREATE TABLE account_types (
    account_type_id                 INT AUTO_INCREMENT PRIMARY KEY,
    type_name                       VARCHAR(50) NOT NULL UNIQUE,
    annual_interest_rate            DECIMAL(5,2)  NOT NULL DEFAULT 0.00,
    minimum_balance                 DECIMAL(15,2) NOT NULL DEFAULT 0.00,
    default_daily_withdrawal_limit  DECIMAL(15,2) NOT NULL,
    status                          ENUM('ACTIVE','INACTIVE') NOT NULL DEFAULT 'ACTIVE',
    CONSTRAINT chk_acctype_values
        CHECK (annual_interest_rate >= 0 AND minimum_balance >= 0 AND default_daily_withdrawal_limit >= 0)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 7. accounts
--    UNIQUE (account_id, customer_id) lets other tables prove that an
--    account belongs to a specific customer through a composite FK.
-- ---------------------------------------------------------------------
CREATE TABLE accounts (
    account_id              INT AUTO_INCREMENT PRIMARY KEY,
    account_number          VARCHAR(20) NOT NULL UNIQUE,
    customer_id             INT NOT NULL,
    account_type_id         INT NOT NULL,
    branch_id               INT NOT NULL,
    current_balance         DECIMAL(15,2) NOT NULL DEFAULT 0.00,
    status                  ENUM('ACTIVE','FROZEN','DORMANT','CLOSED') NOT NULL DEFAULT 'ACTIVE',
    transfer_limit_override DECIMAL(15,2) NULL,
    low_balance_threshold   DECIMAL(15,2) NULL,
    opened_at               TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_accounts_customer
        FOREIGN KEY (customer_id) REFERENCES customers(customer_id),
    CONSTRAINT fk_accounts_type
        FOREIGN KEY (account_type_id) REFERENCES account_types(account_type_id),
    CONSTRAINT fk_accounts_branch
        FOREIGN KEY (branch_id) REFERENCES branches(branch_id),
    CONSTRAINT uq_accounts_id_customer
        UNIQUE (account_id, customer_id),
    CONSTRAINT chk_accounts_balance
        CHECK (current_balance >= 0),
    CONSTRAINT chk_accounts_limits
        CHECK ((transfer_limit_override IS NULL OR transfer_limit_override >= 0)
           AND (low_balance_threshold   IS NULL OR low_balance_threshold   >= 0))
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 8. beneficiaries
-- ---------------------------------------------------------------------
CREATE TABLE beneficiaries (
    beneficiary_id          INT AUTO_INCREMENT PRIMARY KEY,
    customer_id             INT NOT NULL,
    beneficiary_account_id  INT NOT NULL,
    beneficiary_name        VARCHAR(100) NOT NULL,
    nickname                VARCHAR(50)  NULL,
    relationship_type       VARCHAR(30)  NULL,
    status                  ENUM('PENDING','ACTIVE','REJECTED','REMOVED') NOT NULL DEFAULT 'PENDING',
    added_at                TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    approved_at             TIMESTAMP NULL,
    daily_transfer_limit    DECIMAL(15,2) NULL,
    CONSTRAINT fk_benef_customer
        FOREIGN KEY (customer_id) REFERENCES customers(customer_id),
    CONSTRAINT fk_benef_account
        FOREIGN KEY (beneficiary_account_id) REFERENCES accounts(account_id),
    CONSTRAINT uq_benef_customer_account
        UNIQUE (customer_id, beneficiary_account_id),
    CONSTRAINT chk_benef_limit
        CHECK (daily_transfer_limit IS NULL OR daily_transfer_limit >= 0)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 9. transactions  (self-referencing reversal)
-- ---------------------------------------------------------------------
CREATE TABLE transactions (
    transaction_id              BIGINT AUTO_INCREMENT PRIMARY KEY,
    reference_number            VARCHAR(30) NOT NULL UNIQUE,
    transaction_type            ENUM('DEPOSIT','WITHDRAWAL','TRANSFER',
                                     'LOAN_DISBURSEMENT','LOAN_REPAYMENT',
                                     'INTEREST','REVERSAL') NOT NULL,
    source_account_id           INT NULL,
    destination_account_id      INT NULL,
    beneficiary_id              INT NULL,
    amount                      DECIMAL(15,2) NOT NULL,
    status                      ENUM('PENDING','PENDING_REVIEW','POSTED','FAILED','REJECTED','REVERSED')
                                NOT NULL DEFAULT 'PENDING',
    initiated_by_user_id        INT NOT NULL,
    reviewed_by_employee_id     INT NULL,
    branch_id                   INT NULL,
    review_note                 VARCHAR(500) NULL,
    idempotency_key             VARCHAR(64) NOT NULL UNIQUE,
    reversal_of_transaction_id  BIGINT NULL,
    created_at                  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    posted_at                   TIMESTAMP NULL,
    CONSTRAINT fk_txn_source
        FOREIGN KEY (source_account_id) REFERENCES accounts(account_id),
    CONSTRAINT fk_txn_destination
        FOREIGN KEY (destination_account_id) REFERENCES accounts(account_id),
    CONSTRAINT fk_txn_beneficiary
        FOREIGN KEY (beneficiary_id) REFERENCES beneficiaries(beneficiary_id),
    CONSTRAINT fk_txn_initiator
        FOREIGN KEY (initiated_by_user_id) REFERENCES users(user_id),
    CONSTRAINT fk_txn_reviewer
        FOREIGN KEY (reviewed_by_employee_id) REFERENCES employees(employee_id),
    CONSTRAINT fk_txn_branch
        FOREIGN KEY (branch_id) REFERENCES branches(branch_id),
    CONSTRAINT fk_txn_reversal
        FOREIGN KEY (reversal_of_transaction_id) REFERENCES transactions(transaction_id),
    CONSTRAINT chk_txn_amount
        CHECK (amount > 0),
    CONSTRAINT chk_txn_accounts_differ
        CHECK (source_account_id IS NULL OR destination_account_id IS NULL
               OR source_account_id <> destination_account_id),
    CONSTRAINT chk_txn_type_accounts
        CHECK (
            (transaction_type = 'DEPOSIT'    AND destination_account_id IS NOT NULL AND source_account_id IS NULL)
         OR (transaction_type = 'WITHDRAWAL' AND source_account_id IS NOT NULL      AND destination_account_id IS NULL)
         OR (transaction_type = 'TRANSFER'   AND source_account_id IS NOT NULL      AND destination_account_id IS NOT NULL)
         OR (transaction_type IN ('LOAN_DISBURSEMENT','LOAN_REPAYMENT','INTEREST','REVERSAL')
             AND (source_account_id IS NOT NULL OR destination_account_id IS NOT NULL))
        ),
    CONSTRAINT chk_txn_reversal
        CHECK ((transaction_type = 'REVERSAL' AND reversal_of_transaction_id IS NOT NULL)
            OR (transaction_type <> 'REVERSAL' AND reversal_of_transaction_id IS NULL))
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 10. ledger_entries  (NEW: immutable debit/credit ledger)
--     Every posted transaction writes one DEBIT row (source account)
--     and/or one CREDIT row (destination account) in the same database
--     transaction that updates accounts.current_balance.
--     Rows are insert-only (enforced by triggers below).
-- ---------------------------------------------------------------------
CREATE TABLE ledger_entries (
    entry_id        BIGINT AUTO_INCREMENT PRIMARY KEY,
    transaction_id  BIGINT NOT NULL,
    account_id      INT    NOT NULL,
    entry_type      ENUM('DEBIT','CREDIT') NOT NULL,
    amount          DECIMAL(15,2) NOT NULL,
    balance_after   DECIMAL(15,2) NOT NULL,
    created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_ledger_txn
        FOREIGN KEY (transaction_id) REFERENCES transactions(transaction_id),
    CONSTRAINT fk_ledger_account
        FOREIGN KEY (account_id) REFERENCES accounts(account_id),
    CONSTRAINT uq_ledger_txn_account_type
        UNIQUE (transaction_id, account_id, entry_type),
    CONSTRAINT chk_ledger_amount
        CHECK (amount > 0),
    CONSTRAINT chk_ledger_balance_after
        CHECK (balance_after >= 0)
) ENGINE=InnoDB;

-- Statement lookups: all entries of an account in order
CREATE INDEX idx_ledger_account_entry ON ledger_entries (account_id, entry_id);

-- Immutability: ledger rows can never be changed or removed.
-- Corrections are made by posting a REVERSAL transaction with new entries.
DELIMITER $$

CREATE TRIGGER trg_ledger_no_update
BEFORE UPDATE ON ledger_entries
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'ledger_entries is immutable: updates are not allowed';
END$$

CREATE TRIGGER trg_ledger_no_delete
BEFORE DELETE ON ledger_entries
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'ledger_entries is immutable: deletes are not allowed';
END$$

DELIMITER ;

-- ---------------------------------------------------------------------
-- 11. loans
--     Composite FK (linked_account_id, customer_id) guarantees the linked
--     account belongs to the same customer who holds the loan.
-- ---------------------------------------------------------------------
CREATE TABLE loans (
    loan_id                      INT AUTO_INCREMENT PRIMARY KEY,
    customer_id                  INT NOT NULL,
    linked_account_id            INT NOT NULL,
    requested_amount             DECIMAL(15,2) NOT NULL,
    approved_amount              DECIMAL(15,2) NULL,
    annual_interest_rate         DECIMAL(5,2)  NOT NULL,
    tenure_months                INT NOT NULL,
    status                       ENUM('PENDING','APPROVED','REJECTED','DISBURSED','CLOSED','DEFAULTED')
                                 NOT NULL DEFAULT 'PENDING',
    applied_at                   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    reviewed_by_employee_id      INT NULL,
    disbursement_transaction_id  BIGINT NULL UNIQUE,
    CONSTRAINT fk_loans_customer
        FOREIGN KEY (customer_id) REFERENCES customers(customer_id),
    CONSTRAINT fk_loans_account_owner
        FOREIGN KEY (linked_account_id, customer_id)
        REFERENCES accounts(account_id, customer_id),
    CONSTRAINT fk_loans_reviewer
        FOREIGN KEY (reviewed_by_employee_id) REFERENCES employees(employee_id),
    CONSTRAINT fk_loans_disbursement
        FOREIGN KEY (disbursement_transaction_id) REFERENCES transactions(transaction_id),
    CONSTRAINT chk_loans_values
        CHECK (requested_amount > 0
           AND (approved_amount IS NULL OR approved_amount > 0)
           AND annual_interest_rate >= 0
           AND tenure_months > 0)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 12. loan_installments
-- ---------------------------------------------------------------------
CREATE TABLE loan_installments (
    installment_id          INT AUTO_INCREMENT PRIMARY KEY,
    loan_id                 INT NOT NULL,
    installment_number      INT NOT NULL,
    due_date                DATE NOT NULL,
    principal_due           DECIMAL(15,2) NOT NULL,
    interest_due            DECIMAL(15,2) NOT NULL,
    status                  ENUM('PENDING','PAID','OVERDUE') NOT NULL DEFAULT 'PENDING',
    payment_transaction_id  BIGINT NULL UNIQUE,
    paid_at                 TIMESTAMP NULL,
    CONSTRAINT fk_inst_loan
        FOREIGN KEY (loan_id) REFERENCES loans(loan_id),
    CONSTRAINT fk_inst_payment
        FOREIGN KEY (payment_transaction_id) REFERENCES transactions(transaction_id),
    CONSTRAINT uq_inst_loan_number
        UNIQUE (loan_id, installment_number),
    CONSTRAINT chk_inst_values
        CHECK (installment_number > 0 AND principal_due >= 0 AND interest_due >= 0),
    CONSTRAINT chk_inst_paid
        CHECK (status <> 'PAID' OR (payment_transaction_id IS NOT NULL AND paid_at IS NOT NULL))
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 13. audit_logs
-- ---------------------------------------------------------------------
CREATE TABLE audit_logs (
    audit_id       BIGINT AUTO_INCREMENT PRIMARY KEY,
    actor_user_id  INT NULL,                       -- NULL = system-generated action
    action         VARCHAR(50) NOT NULL,
    entity_type    VARCHAR(50) NOT NULL,           -- polymorphic: table name
    entity_id      BIGINT NOT NULL,                -- polymorphic: row id (not a real FK)
    old_values     JSON NULL,
    new_values     JSON NULL,
    reason         VARCHAR(500) NULL,
    created_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_audit_actor
        FOREIGN KEY (actor_user_id) REFERENCES users(user_id)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 14. notifications
-- ---------------------------------------------------------------------
CREATE TABLE notifications (
    notification_id    BIGINT AUTO_INCREMENT PRIMARY KEY,
    user_id            INT NOT NULL,
    transaction_id     BIGINT NULL,
    notification_type  VARCHAR(40) NOT NULL,       -- e.g. LOW_BALANCE, SPENDING_ALERT, TXN_POSTED
    message            VARCHAR(500) NOT NULL,
    is_read            BOOLEAN NOT NULL DEFAULT FALSE,
    created_at         TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_notif_user
        FOREIGN KEY (user_id) REFERENCES users(user_id),
    CONSTRAINT fk_notif_txn
        FOREIGN KEY (transaction_id) REFERENCES transactions(transaction_id)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- Helpful indexes for common lookups
-- (MySQL already indexes PKs, UNIQUE columns and FK columns)
-- ---------------------------------------------------------------------
CREATE INDEX idx_txn_created_at      ON transactions (created_at);
CREATE INDEX idx_txn_source_created  ON transactions (source_account_id, created_at);
CREATE INDEX idx_txn_dest_created    ON transactions (destination_account_id, created_at);
CREATE INDEX idx_inst_due_status     ON loan_installments (due_date, status);
CREATE INDEX idx_notif_user_unread   ON notifications (user_id, is_read);
CREATE INDEX idx_audit_entity        ON audit_logs (entity_type, entity_id);

-- ---------------------------------------------------------------------
-- Reconciliation view: current_balance must equal the net of the ledger.
-- Assumes accounts start at 0 and every balance change is ledgered
-- (opening deposits are posted as DEPOSIT transactions).
-- Any row with is_consistent = 0 signals a balance/ledger mismatch.
-- Usage: SELECT * FROM v_balance_reconciliation WHERE is_consistent = 0;
-- ---------------------------------------------------------------------
CREATE VIEW v_balance_reconciliation AS
SELECT
    a.account_id,
    a.account_number,
    a.current_balance,
    COALESCE(SUM(CASE WHEN l.entry_type = 'CREDIT' THEN l.amount
                      WHEN l.entry_type = 'DEBIT'  THEN -l.amount END), 0) AS ledger_balance,
    (a.current_balance = COALESCE(SUM(CASE WHEN l.entry_type = 'CREDIT' THEN l.amount
                                           WHEN l.entry_type = 'DEBIT'  THEN -l.amount END), 0)) AS is_consistent
FROM accounts a
LEFT JOIN ledger_entries l ON l.account_id = a.account_id
GROUP BY a.account_id, a.account_number, a.current_balance;
