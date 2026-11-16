-- =====================================================================
-- Banking System: functions, triggers and stored procedures (MySQL 8.0.16+)
-- Run AFTER banking_system_v2.sql (sample data is optional).
--
-- Design rules enforced here:
--   * Every money-moving operation runs as ONE database transaction:
--       START TRANSACTION -> lock accounts -> validate -> write the
--       transaction row + ledger entries + balance updates -> COMMIT.
--     Any error triggers ROLLBACK, so a half-applied transfer is impossible.
--   * Accounts are locked with SELECT ... FOR UPDATE, always in ascending
--     account_id order, so two opposite transfers cannot deadlock.
--   * The acting user id must come from the authenticated session, never
--     from a client-supplied value. Procedures check ownership/role themselves.
--   * Posted transactions and ledger entries are immutable (triggers).
--   * Applications should be granted EXECUTE on sp_* only, with no direct
--     INSERT/UPDATE on accounts, transactions or ledger_entries.
--
-- NOTE: START TRANSACTION inside a procedure commits any transaction the
-- caller already had open, so call these procedures in autocommit mode.
-- =====================================================================

USE banking_system;

-- ---------------------------------------------------------------------
-- Clean re-run support
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_txn_no_delete;
DROP TRIGGER IF EXISTS trg_txn_posted_immutable;
DROP TRIGGER IF EXISTS trg_txn_beneficiary_check;
DROP TRIGGER IF EXISTS trg_benef_not_own_account_ins;
DROP TRIGGER IF EXISTS trg_benef_not_own_account_upd;

DROP FUNCTION IF EXISTS fn_is_active_user;
DROP FUNCTION IF EXISTS fn_employee_id;
DROP FUNCTION IF EXISTS fn_is_active_employee;
DROP FUNCTION IF EXISTS fn_is_manager;
DROP FUNCTION IF EXISTS fn_is_loan_staff;
DROP FUNCTION IF EXISTS fn_is_kyc_staff;
DROP FUNCTION IF EXISTS fn_customer_id_of_user;
DROP FUNCTION IF EXISTS fn_is_account_owner;
DROP FUNCTION IF EXISTS fn_has_approved_kyc;

DROP PROCEDURE IF EXISTS sp_internal_post_entry;
DROP PROCEDURE IF EXISTS sp_internal_check_idempotency;
DROP PROCEDURE IF EXISTS sp_deposit;
DROP PROCEDURE IF EXISTS sp_withdraw;
DROP PROCEDURE IF EXISTS sp_transfer;
DROP PROCEDURE IF EXISTS sp_reverse_transaction;
DROP PROCEDURE IF EXISTS sp_apply_loan;
DROP PROCEDURE IF EXISTS sp_approve_loan;
DROP PROCEDURE IF EXISTS sp_reject_loan;
DROP PROCEDURE IF EXISTS sp_disburse_loan;
DROP PROCEDURE IF EXISTS sp_pay_installment;
DROP PROCEDURE IF EXISTS sp_open_account;
DROP PROCEDURE IF EXISTS sp_add_beneficiary;
DROP PROCEDURE IF EXISTS sp_approve_beneficiary;
DROP PROCEDURE IF EXISTS sp_review_kyc;
DROP PROCEDURE IF EXISTS sp_get_account_statement;
DROP PROCEDURE IF EXISTS sp_reconcile_balances;

DELIMITER $$

-- =====================================================================
-- PART 1: TRIGGERS
-- =====================================================================

-- Transactions can never be deleted.
CREATE TRIGGER trg_txn_no_delete
BEFORE DELETE ON transactions
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Transactions cannot be deleted';
END$$

-- Once POSTED or REVERSED, a transaction is frozen. The only allowed change
-- is POSTED -> REVERSED (done by sp_reverse_transaction).
CREATE TRIGGER trg_txn_posted_immutable
BEFORE UPDATE ON transactions
FOR EACH ROW
BEGIN
    IF OLD.status IN ('POSTED', 'REVERSED') THEN
        IF NOT (OLD.status = 'POSTED'
                AND NEW.status = 'REVERSED'
                AND NEW.reference_number = OLD.reference_number
                AND NEW.transaction_type = OLD.transaction_type
                AND NEW.source_account_id <=> OLD.source_account_id
                AND NEW.destination_account_id <=> OLD.destination_account_id
                AND NEW.beneficiary_id <=> OLD.beneficiary_id
                AND NEW.amount = OLD.amount
                AND NEW.posted_at <=> OLD.posted_at) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Posted transactions are immutable';
        END IF;
    END IF;
END$$

-- A transaction's beneficiary must belong to the owner of the source account,
-- and the destination must be that beneficiary's account.
CREATE TRIGGER trg_txn_beneficiary_check
BEFORE INSERT ON transactions
FOR EACH ROW
BEGIN
    DECLARE v_benef_customer INT;
    DECLARE v_benef_account  INT;
    DECLARE v_src_customer   INT;

    IF NEW.beneficiary_id IS NOT NULL THEN
        SELECT customer_id, beneficiary_account_id
          INTO v_benef_customer, v_benef_account
          FROM beneficiaries
         WHERE beneficiary_id = NEW.beneficiary_id;

        SELECT customer_id INTO v_src_customer
          FROM accounts
         WHERE account_id = NEW.source_account_id;

        IF v_src_customer IS NULL OR v_benef_customer IS NULL
           OR v_src_customer <> v_benef_customer THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Beneficiary does not belong to the source account owner';
        END IF;

        IF NEW.destination_account_id IS NULL
           OR NEW.destination_account_id <> v_benef_account THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Destination account does not match the beneficiary account';
        END IF;
    END IF;
END$$

-- A customer cannot register one of their own accounts as a beneficiary.
CREATE TRIGGER trg_benef_not_own_account_ins
BEFORE INSERT ON beneficiaries
FOR EACH ROW
BEGIN
    DECLARE v_owner INT;
    SELECT customer_id INTO v_owner FROM accounts WHERE account_id = NEW.beneficiary_account_id;
    IF v_owner IS NOT NULL AND v_owner = NEW.customer_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'You cannot add your own account as a beneficiary';
    END IF;
END$$

CREATE TRIGGER trg_benef_not_own_account_upd
BEFORE UPDATE ON beneficiaries
FOR EACH ROW
BEGIN
    DECLARE v_owner INT;
    SELECT customer_id INTO v_owner FROM accounts WHERE account_id = NEW.beneficiary_account_id;
    IF v_owner IS NOT NULL AND v_owner = NEW.customer_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'You cannot add your own account as a beneficiary';
    END IF;
END$$

-- =====================================================================
-- PART 2: HELPER FUNCTIONS (authorization and checks)
-- =====================================================================

CREATE FUNCTION fn_is_active_user(p_user_id INT) RETURNS TINYINT(1)
READS SQL DATA
BEGIN
    RETURN EXISTS (SELECT 1 FROM users WHERE user_id = p_user_id AND status = 'ACTIVE');
END$$

-- Returns the employee_id of an ACTIVE employee whose user is ACTIVE, else NULL.
CREATE FUNCTION fn_employee_id(p_user_id INT) RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v_id INT DEFAULT NULL;
    SELECT e.employee_id INTO v_id
      FROM employees e
      JOIN users u ON u.user_id = e.user_id
     WHERE e.user_id = p_user_id AND e.status = 'ACTIVE' AND u.status = 'ACTIVE'
     LIMIT 1;
    RETURN v_id;
END$$

CREATE FUNCTION fn_is_active_employee(p_user_id INT) RETURNS TINYINT(1)
READS SQL DATA
BEGIN
    RETURN fn_employee_id(p_user_id) IS NOT NULL;
END$$

CREATE FUNCTION fn_is_manager(p_user_id INT) RETURNS TINYINT(1)
READS SQL DATA
BEGIN
    RETURN EXISTS (SELECT 1 FROM employees e JOIN users u ON u.user_id = e.user_id
                    WHERE e.user_id = p_user_id AND e.status = 'ACTIVE' AND u.status = 'ACTIVE'
                      AND e.designation IN ('Branch Manager', 'Regional Manager'));
END$$

CREATE FUNCTION fn_is_loan_staff(p_user_id INT) RETURNS TINYINT(1)
READS SQL DATA
BEGIN
    RETURN EXISTS (SELECT 1 FROM employees e JOIN users u ON u.user_id = e.user_id
                    WHERE e.user_id = p_user_id AND e.status = 'ACTIVE' AND u.status = 'ACTIVE'
                      AND e.designation IN ('Loan Officer', 'Branch Manager', 'Regional Manager'));
END$$

CREATE FUNCTION fn_is_kyc_staff(p_user_id INT) RETURNS TINYINT(1)
READS SQL DATA
BEGIN
    RETURN EXISTS (SELECT 1 FROM employees e JOIN users u ON u.user_id = e.user_id
                    WHERE e.user_id = p_user_id AND e.status = 'ACTIVE' AND u.status = 'ACTIVE'
                      AND e.designation IN ('KYC Officer', 'Branch Manager', 'Regional Manager'));
END$$

CREATE FUNCTION fn_customer_id_of_user(p_user_id INT) RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v_id INT DEFAULT NULL;
    SELECT customer_id INTO v_id FROM customers WHERE user_id = p_user_id LIMIT 1;
    RETURN v_id;
END$$

-- TRUE if the user is the customer who owns the account.
CREATE FUNCTION fn_is_account_owner(p_user_id INT, p_account_id INT) RETURNS TINYINT(1)
READS SQL DATA
BEGIN
    RETURN EXISTS (SELECT 1
                     FROM accounts a
                     JOIN customers c ON c.customer_id = a.customer_id
                    WHERE a.account_id = p_account_id AND c.user_id = p_user_id);
END$$

CREATE FUNCTION fn_has_approved_kyc(p_customer_id INT) RETURNS TINYINT(1)
READS SQL DATA
BEGIN
    RETURN EXISTS (SELECT 1 FROM kyc_records
                    WHERE customer_id = p_customer_id AND status = 'APPROVED');
END$$

-- =====================================================================
-- PART 3: INTERNAL HELPERS (called by the money procedures, not by users)
-- =====================================================================

-- Applies one ledger entry: updates the balance and inserts the ledger row.
-- The caller must already be inside a transaction.
CREATE PROCEDURE sp_internal_post_entry(
    IN p_transaction_id BIGINT,
    IN p_account_id     INT,
    IN p_entry_type     VARCHAR(6),     -- 'DEBIT' or 'CREDIT'
    IN p_amount         DECIMAL(15,2))
BEGIN
    DECLARE v_balance     DECIMAL(15,2);
    DECLARE v_new_balance DECIMAL(15,2);

    SELECT current_balance INTO v_balance
      FROM accounts WHERE account_id = p_account_id FOR UPDATE;

    IF v_balance IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Account not found while posting ledger entry';
    END IF;

    IF p_entry_type = 'DEBIT' THEN
        SET v_new_balance = v_balance - p_amount;
    ELSEIF p_entry_type = 'CREDIT' THEN
        SET v_new_balance = v_balance + p_amount;
    ELSE
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid ledger entry type';
    END IF;

    IF v_new_balance < 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient balance';
    END IF;

    UPDATE accounts SET current_balance = v_new_balance WHERE account_id = p_account_id;

    INSERT INTO ledger_entries (transaction_id, account_id, entry_type, amount, balance_after)
    VALUES (p_transaction_id, p_account_id, p_entry_type, p_amount, v_new_balance);

    -- Low-balance alert for the account owner after a debit
    IF p_entry_type = 'DEBIT' THEN
        INSERT INTO notifications (user_id, transaction_id, notification_type, message)
        SELECT c.user_id, p_transaction_id, 'LOW_BALANCE',
               CONCAT('Balance in account ending ', RIGHT(a.account_number, 4),
                      ' is below your alert threshold.')
          FROM accounts a
          JOIN customers c ON c.customer_id = a.customer_id
         WHERE a.account_id = p_account_id
           AND a.low_balance_threshold IS NOT NULL
           AND a.current_balance < a.low_balance_threshold;
    END IF;
END$$

-- If this idempotency key was already processed, returns that transaction id
-- (the caller then returns it instead of processing the money again).
-- If the key was used for a DIFFERENT request, raises an error.
CREATE PROCEDURE sp_internal_check_idempotency(
    IN  p_key         VARCHAR(64),
    IN  p_type        VARCHAR(20),
    IN  p_src         INT,
    IN  p_dst         INT,
    IN  p_amount      DECIMAL(15,2),
    OUT p_existing_id BIGINT)
BEGIN
    DECLARE v_type   VARCHAR(20);
    DECLARE v_src    INT;
    DECLARE v_dst    INT;
    DECLARE v_amount DECIMAL(15,2);

    SET p_existing_id = NULL;

    SELECT transaction_id, transaction_type, source_account_id, destination_account_id, amount
      INTO p_existing_id, v_type, v_src, v_dst, v_amount
      FROM transactions
     WHERE idempotency_key = p_key;

    IF p_existing_id IS NOT NULL THEN
        IF NOT (v_type = p_type AND (v_src <=> p_src) AND (v_dst <=> p_dst) AND v_amount = p_amount) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Idempotency key was already used for a different request';
        END IF;
    END IF;
END$$

-- =====================================================================
-- PART 4: MONEY-MOVING PROCEDURES
-- =====================================================================

-- ---------------------------------------------------------------------
-- sp_deposit: customer (owner) or active employee deposits into an account
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_deposit(
    IN  p_acting_user_id  INT,
    IN  p_account_id      INT,
    IN  p_amount          DECIMAL(15,2),
    IN  p_idempotency_key VARCHAR(64),
    OUT p_transaction_id  BIGINT)
main: BEGIN
    DECLARE v_status   VARCHAR(10);
    DECLARE v_branch   INT;
    DECLARE v_existing BIGINT DEFAULT NULL;
    DECLARE v_ref      VARCHAR(30);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Amount must be greater than zero';
    END IF;
    IF p_idempotency_key IS NULL OR p_idempotency_key = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Idempotency key is required';
    END IF;
    IF NOT fn_is_active_user(p_acting_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Acting user is not active';
    END IF;
    IF NOT (fn_is_account_owner(p_acting_user_id, p_account_id)
            OR fn_is_active_employee(p_acting_user_id)) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Not authorised to deposit into this account';
    END IF;

    START TRANSACTION;

    -- Lock first, so the reads below see the latest committed data
    SELECT status, branch_id INTO v_status, v_branch
      FROM accounts WHERE account_id = p_account_id FOR UPDATE;
    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Account not found';
    END IF;

    CALL sp_internal_check_idempotency(p_idempotency_key, 'DEPOSIT', NULL, p_account_id, p_amount, v_existing);
    IF v_existing IS NOT NULL THEN
        SET p_transaction_id = v_existing;
        COMMIT;
        LEAVE main;
    END IF;

    IF v_status <> 'ACTIVE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Account is not active';
    END IF;

    INSERT INTO transactions (reference_number, transaction_type, destination_account_id, amount,
                              status, initiated_by_user_id, branch_id, idempotency_key)
    VALUES (CONCAT('TMP', UUID_SHORT()), 'DEPOSIT', p_account_id, p_amount,
            'PENDING', p_acting_user_id, v_branch, p_idempotency_key);
    SET p_transaction_id = LAST_INSERT_ID();

    UPDATE transactions
       SET reference_number = CONCAT('TXN', DATE_FORMAT(created_at, '%Y%m%d'), LPAD(transaction_id, 8, '0'))
     WHERE transaction_id = p_transaction_id;

    CALL sp_internal_post_entry(p_transaction_id, p_account_id, 'CREDIT', p_amount);

    UPDATE transactions SET status = 'POSTED', posted_at = NOW()
     WHERE transaction_id = p_transaction_id;

    SELECT reference_number INTO v_ref FROM transactions WHERE transaction_id = p_transaction_id;

    INSERT INTO notifications (user_id, transaction_id, notification_type, message)
    SELECT c.user_id, p_transaction_id, 'TXN_POSTED',
           CONCAT('Rs.', FORMAT(p_amount, 2), ' credited to account ending ',
                  RIGHT(a.account_number, 4), '. Ref ', v_ref)
      FROM accounts a JOIN customers c ON c.customer_id = a.customer_id
     WHERE a.account_id = p_account_id;

    COMMIT;
END$$

-- ---------------------------------------------------------------------
-- sp_withdraw: owner or active employee withdraws from an account
--   checks: account ACTIVE, minimum balance, daily withdrawal limit
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_withdraw(
    IN  p_acting_user_id  INT,
    IN  p_account_id      INT,
    IN  p_amount          DECIMAL(15,2),
    IN  p_idempotency_key VARCHAR(64),
    OUT p_transaction_id  BIGINT)
main: BEGIN
    DECLARE v_status   VARCHAR(10);
    DECLARE v_branch   INT;
    DECLARE v_balance  DECIMAL(15,2);
    DECLARE v_min      DECIMAL(15,2);
    DECLARE v_limit    DECIMAL(15,2);
    DECLARE v_today    DECIMAL(15,2);
    DECLARE v_existing BIGINT DEFAULT NULL;
    DECLARE v_ref      VARCHAR(30);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Amount must be greater than zero';
    END IF;
    IF p_idempotency_key IS NULL OR p_idempotency_key = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Idempotency key is required';
    END IF;
    IF NOT fn_is_active_user(p_acting_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Acting user is not active';
    END IF;
    IF NOT (fn_is_account_owner(p_acting_user_id, p_account_id)
            OR fn_is_active_employee(p_acting_user_id)) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Not authorised to withdraw from this account';
    END IF;

    START TRANSACTION;

    SELECT a.status, a.branch_id, a.current_balance, t.minimum_balance, t.default_daily_withdrawal_limit
      INTO v_status, v_branch, v_balance, v_min, v_limit
      FROM accounts a
      JOIN account_types t ON t.account_type_id = a.account_type_id
     WHERE a.account_id = p_account_id
       FOR UPDATE OF a;
    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Account not found';
    END IF;

    CALL sp_internal_check_idempotency(p_idempotency_key, 'WITHDRAWAL', p_account_id, NULL, p_amount, v_existing);
    IF v_existing IS NOT NULL THEN
        SET p_transaction_id = v_existing;
        COMMIT;
        LEAVE main;
    END IF;

    IF v_status <> 'ACTIVE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Account is not active';
    END IF;
    IF v_balance - p_amount < v_min THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Withdrawal would take balance below the minimum balance';
    END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_today
      FROM transactions
     WHERE source_account_id = p_account_id
       AND transaction_type = 'WITHDRAWAL'
       AND status = 'POSTED'
       AND posted_at >= CURDATE();
    IF v_today + p_amount > v_limit THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Daily withdrawal limit exceeded';
    END IF;

    INSERT INTO transactions (reference_number, transaction_type, source_account_id, amount,
                              status, initiated_by_user_id, branch_id, idempotency_key)
    VALUES (CONCAT('TMP', UUID_SHORT()), 'WITHDRAWAL', p_account_id, p_amount,
            'PENDING', p_acting_user_id, v_branch, p_idempotency_key);
    SET p_transaction_id = LAST_INSERT_ID();

    UPDATE transactions
       SET reference_number = CONCAT('TXN', DATE_FORMAT(created_at, '%Y%m%d'), LPAD(transaction_id, 8, '0'))
     WHERE transaction_id = p_transaction_id;

    CALL sp_internal_post_entry(p_transaction_id, p_account_id, 'DEBIT', p_amount);

    UPDATE transactions SET status = 'POSTED', posted_at = NOW()
     WHERE transaction_id = p_transaction_id;

    SELECT reference_number INTO v_ref FROM transactions WHERE transaction_id = p_transaction_id;

    INSERT INTO notifications (user_id, transaction_id, notification_type, message)
    SELECT c.user_id, p_transaction_id, 'TXN_POSTED',
           CONCAT('Rs.', FORMAT(p_amount, 2), ' withdrawn from account ending ',
                  RIGHT(a.account_number, 4), '. Ref ', v_ref)
      FROM accounts a JOIN customers c ON c.customer_id = a.customer_id
     WHERE a.account_id = p_account_id;

    COMMIT;
END$$

-- ---------------------------------------------------------------------
-- sp_transfer: the account OWNER transfers money.
--   * p_beneficiary_id = NULL  -> transfer between the customer's own accounts
--   * otherwise the beneficiary must belong to the customer, be ACTIVE and
--     point at the destination account
--   checks: ownership, KYC, both accounts ACTIVE, minimum balance,
--           daily transfer limit, beneficiary daily limit
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_transfer(
    IN  p_acting_user_id         INT,
    IN  p_source_account_id      INT,
    IN  p_destination_account_id INT,
    IN  p_beneficiary_id         INT,
    IN  p_amount                 DECIMAL(15,2),
    IN  p_idempotency_key        VARCHAR(64),
    OUT p_transaction_id         BIGINT)
main: BEGIN
    DECLARE v_src_customer INT;
    DECLARE v_src_status   VARCHAR(10);
    DECLARE v_src_branch   INT;
    DECLARE v_src_balance  DECIMAL(15,2);
    DECLARE v_src_override DECIMAL(15,2);
    DECLARE v_src_min      DECIMAL(15,2);
    DECLARE v_src_default  DECIMAL(15,2);
    DECLARE v_limit        DECIMAL(15,2);
    DECLARE v_dst_customer INT;
    DECLARE v_dst_status   VARCHAR(10);
    DECLARE v_b_customer   INT;
    DECLARE v_b_account    INT;
    DECLARE v_b_status     VARCHAR(10);
    DECLARE v_b_limit      DECIMAL(15,2);
    DECLARE v_today        DECIMAL(15,2);
    DECLARE v_existing     BIGINT DEFAULT NULL;
    DECLARE v_ref          VARCHAR(30);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Amount must be greater than zero';
    END IF;
    IF p_idempotency_key IS NULL OR p_idempotency_key = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Idempotency key is required';
    END IF;
    IF p_source_account_id = p_destination_account_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Source and destination accounts must be different';
    END IF;
    IF NOT fn_is_active_user(p_acting_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Acting user is not active';
    END IF;
    IF NOT fn_is_account_owner(p_acting_user_id, p_source_account_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'You can only transfer from your own account';
    END IF;

    START TRANSACTION;

    -- Lock both accounts in ascending account_id order (deadlock avoidance)
    IF p_source_account_id < p_destination_account_id THEN
        SELECT a.customer_id, a.status, a.branch_id, a.current_balance, a.transfer_limit_override,
               t.minimum_balance, t.default_daily_withdrawal_limit
          INTO v_src_customer, v_src_status, v_src_branch, v_src_balance, v_src_override,
               v_src_min, v_src_default
          FROM accounts a JOIN account_types t ON t.account_type_id = a.account_type_id
         WHERE a.account_id = p_source_account_id FOR UPDATE OF a;

        SELECT customer_id, status INTO v_dst_customer, v_dst_status
          FROM accounts WHERE account_id = p_destination_account_id FOR UPDATE;
    ELSE
        SELECT customer_id, status INTO v_dst_customer, v_dst_status
          FROM accounts WHERE account_id = p_destination_account_id FOR UPDATE;

        SELECT a.customer_id, a.status, a.branch_id, a.current_balance, a.transfer_limit_override,
               t.minimum_balance, t.default_daily_withdrawal_limit
          INTO v_src_customer, v_src_status, v_src_branch, v_src_balance, v_src_override,
               v_src_min, v_src_default
          FROM accounts a JOIN account_types t ON t.account_type_id = a.account_type_id
         WHERE a.account_id = p_source_account_id FOR UPDATE OF a;
    END IF;

    IF v_src_status IS NULL OR v_dst_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Source or destination account not found';
    END IF;

    CALL sp_internal_check_idempotency(p_idempotency_key, 'TRANSFER',
                                       p_source_account_id, p_destination_account_id, p_amount, v_existing);
    IF v_existing IS NOT NULL THEN
        SET p_transaction_id = v_existing;
        COMMIT;
        LEAVE main;
    END IF;

    IF v_src_status <> 'ACTIVE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Source account is not active';
    END IF;
    IF v_dst_status <> 'ACTIVE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Destination account is not active';
    END IF;
    IF NOT fn_has_approved_kyc(v_src_customer) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'KYC is not approved for this customer';
    END IF;

    -- Own-account transfer vs. beneficiary transfer
    IF p_beneficiary_id IS NULL THEN
        IF v_dst_customer <> v_src_customer THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Transfers to other customers require an approved beneficiary';
        END IF;
    ELSE
        SELECT customer_id, beneficiary_account_id, status, daily_transfer_limit
          INTO v_b_customer, v_b_account, v_b_status, v_b_limit
          FROM beneficiaries WHERE beneficiary_id = p_beneficiary_id;

        IF v_b_customer IS NULL OR v_b_customer <> v_src_customer THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Beneficiary does not belong to you';
        END IF;
        IF v_b_account <> p_destination_account_id THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Beneficiary account does not match destination';
        END IF;
        IF v_b_status <> 'ACTIVE' THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Beneficiary is not approved';
        END IF;

        IF v_b_limit IS NOT NULL THEN
            SELECT COALESCE(SUM(amount), 0) INTO v_today
              FROM transactions
             WHERE beneficiary_id = p_beneficiary_id
               AND status = 'POSTED'
               AND posted_at >= CURDATE();
            IF v_today + p_amount > v_b_limit THEN
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Beneficiary daily transfer limit exceeded';
            END IF;
        END IF;
    END IF;

    IF v_src_balance - p_amount < v_src_min THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transfer would take balance below the minimum balance';
    END IF;

    SET v_limit = COALESCE(v_src_override, v_src_default);
    SELECT COALESCE(SUM(amount), 0) INTO v_today
      FROM transactions
     WHERE source_account_id = p_source_account_id
       AND transaction_type = 'TRANSFER'
       AND status = 'POSTED'
       AND posted_at >= CURDATE();
    IF v_today + p_amount > v_limit THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Daily transfer limit exceeded';
    END IF;

    INSERT INTO transactions (reference_number, transaction_type, source_account_id, destination_account_id,
                              beneficiary_id, amount, status, initiated_by_user_id, branch_id, idempotency_key)
    VALUES (CONCAT('TMP', UUID_SHORT()), 'TRANSFER', p_source_account_id, p_destination_account_id,
            p_beneficiary_id, p_amount, 'PENDING', p_acting_user_id, v_src_branch, p_idempotency_key);
    SET p_transaction_id = LAST_INSERT_ID();

    UPDATE transactions
       SET reference_number = CONCAT('TXN', DATE_FORMAT(created_at, '%Y%m%d'), LPAD(transaction_id, 8, '0'))
     WHERE transaction_id = p_transaction_id;

    CALL sp_internal_post_entry(p_transaction_id, p_source_account_id,      'DEBIT',  p_amount);
    CALL sp_internal_post_entry(p_transaction_id, p_destination_account_id, 'CREDIT', p_amount);

    UPDATE transactions SET status = 'POSTED', posted_at = NOW()
     WHERE transaction_id = p_transaction_id;

    SELECT reference_number INTO v_ref FROM transactions WHERE transaction_id = p_transaction_id;

    INSERT INTO notifications (user_id, transaction_id, notification_type, message)
    SELECT c.user_id, p_transaction_id, 'TXN_POSTED',
           CONCAT('Rs.', FORMAT(p_amount, 2), ' debited from account ending ',
                  RIGHT(a.account_number, 4), '. Ref ', v_ref)
      FROM accounts a JOIN customers c ON c.customer_id = a.customer_id
     WHERE a.account_id = p_source_account_id
    UNION ALL
    SELECT c.user_id, p_transaction_id, 'TXN_POSTED',
           CONCAT('Rs.', FORMAT(p_amount, 2), ' credited to account ending ',
                  RIGHT(a.account_number, 4), '. Ref ', v_ref)
      FROM accounts a JOIN customers c ON c.customer_id = a.customer_id
     WHERE a.account_id = p_destination_account_id;

    COMMIT;
END$$

-- ---------------------------------------------------------------------
-- sp_reverse_transaction: a MANAGER reverses a POSTED deposit, withdrawal
-- or transfer by posting an opposite REVERSAL transaction. Nothing is edited
-- or deleted; the original is only marked REVERSED.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_reverse_transaction(
    IN  p_employee_user_id        INT,
    IN  p_original_transaction_id BIGINT,
    IN  p_reason                  VARCHAR(255),
    IN  p_idempotency_key         VARCHAR(64),
    OUT p_reversal_id             BIGINT)
main: BEGIN
    DECLARE v_emp      INT;
    DECLARE v_type     VARCHAR(20);
    DECLARE v_src      INT;
    DECLARE v_dst      INT;
    DECLARE v_amount   DECIMAL(15,2);
    DECLARE v_status   VARCHAR(20);
    DECLARE v_branch   INT;
    DECLARE v_a1       INT;
    DECLARE v_a2       INT;
    DECLARE v_dummy    INT;
    DECLARE v_existing BIGINT DEFAULT NULL;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_reason IS NULL OR p_reason = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A reason is required for a reversal';
    END IF;
    IF p_idempotency_key IS NULL OR p_idempotency_key = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Idempotency key is required';
    END IF;
    IF NOT fn_is_manager(p_employee_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only an active manager can reverse a transaction';
    END IF;
    SET v_emp = fn_employee_id(p_employee_user_id);

    START TRANSACTION;

    SELECT transaction_type, source_account_id, destination_account_id, amount, status, branch_id
      INTO v_type, v_src, v_dst, v_amount, v_status, v_branch
      FROM transactions WHERE transaction_id = p_original_transaction_id FOR UPDATE;
    IF v_type IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Original transaction not found';
    END IF;

    -- The reversal swaps source and destination of the original
    CALL sp_internal_check_idempotency(p_idempotency_key, 'REVERSAL', v_dst, v_src, v_amount, v_existing);
    IF v_existing IS NOT NULL THEN
        SET p_reversal_id = v_existing;
        COMMIT;
        LEAVE main;
    END IF;

    IF v_status <> 'POSTED' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only POSTED transactions can be reversed';
    END IF;
    IF v_type NOT IN ('DEPOSIT', 'WITHDRAWAL', 'TRANSFER') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This transaction type cannot be reversed here';
    END IF;

    -- Lock the affected account(s) in ascending id order
    SET v_a1 = LEAST(COALESCE(v_src, v_dst), COALESCE(v_dst, v_src));
    SET v_a2 = GREATEST(COALESCE(v_src, v_dst), COALESCE(v_dst, v_src));
    SELECT account_id INTO v_dummy FROM accounts WHERE account_id = v_a1 FOR UPDATE;
    IF v_a2 <> v_a1 THEN
        SELECT account_id INTO v_dummy FROM accounts WHERE account_id = v_a2 FOR UPDATE;
    END IF;

    INSERT INTO transactions (reference_number, transaction_type, source_account_id, destination_account_id,
                              amount, status, initiated_by_user_id, reviewed_by_employee_id, branch_id,
                              review_note, idempotency_key, reversal_of_transaction_id)
    VALUES (CONCAT('TMP', UUID_SHORT()), 'REVERSAL', v_dst, v_src,
            v_amount, 'PENDING', p_employee_user_id, v_emp, v_branch,
            p_reason, p_idempotency_key, p_original_transaction_id);
    SET p_reversal_id = LAST_INSERT_ID();

    UPDATE transactions
       SET reference_number = CONCAT('TXN', DATE_FORMAT(created_at, '%Y%m%d'), LPAD(transaction_id, 8, '0'))
     WHERE transaction_id = p_reversal_id;

    -- Opposite entries: the original destination is debited, the original source credited
    IF v_dst IS NOT NULL THEN
        CALL sp_internal_post_entry(p_reversal_id, v_dst, 'DEBIT', v_amount);
    END IF;
    IF v_src IS NOT NULL THEN
        CALL sp_internal_post_entry(p_reversal_id, v_src, 'CREDIT', v_amount);
    END IF;

    UPDATE transactions SET status = 'POSTED', posted_at = NOW()
     WHERE transaction_id = p_reversal_id;
    UPDATE transactions SET status = 'REVERSED'
     WHERE transaction_id = p_original_transaction_id;

    INSERT INTO audit_logs (actor_user_id, action, entity_type, entity_id, old_values, new_values, reason)
    VALUES (p_employee_user_id, 'TRANSACTION_REVERSED', 'transactions', p_original_transaction_id,
            JSON_OBJECT('status', 'POSTED'), JSON_OBJECT('status', 'REVERSED', 'reversal_id', p_reversal_id),
            p_reason);

    COMMIT;
END$$

-- =====================================================================
-- PART 5: LOAN PROCEDURES
-- =====================================================================

-- ---------------------------------------------------------------------
-- sp_apply_loan: a customer applies for a loan (status PENDING)
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_apply_loan(
    IN  p_acting_user_id    INT,
    IN  p_account_id        INT,
    IN  p_requested_amount  DECIMAL(15,2),
    IN  p_tenure_months     INT,
    OUT p_loan_id           INT)
BEGIN
    DECLARE v_customer     INT;
    DECLARE v_acct_cust    INT;
    DECLARE v_acct_status  VARCHAR(10);
    DECLARE v_in_progress  INT DEFAULT 0;
    DECLARE v_rate         DECIMAL(5,2);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_requested_amount IS NULL OR p_requested_amount <= 0 OR p_requested_amount > 5000000 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Requested amount must be between 1 and 5,000,000';
    END IF;
    IF p_tenure_months IS NULL OR p_tenure_months < 1 OR p_tenure_months > 84 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Tenure must be between 1 and 84 months';
    END IF;
    IF NOT fn_is_active_user(p_acting_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Acting user is not active';
    END IF;

    SET v_customer = fn_customer_id_of_user(p_acting_user_id);
    IF v_customer IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only customers can apply for a loan';
    END IF;

    START TRANSACTION;

    -- Lock the customer row so two simultaneous applications cannot both pass the check
    SELECT customer_id INTO v_customer FROM customers WHERE customer_id = v_customer FOR UPDATE;

    SELECT customer_id, status INTO v_acct_cust, v_acct_status
      FROM accounts WHERE account_id = p_account_id;
    IF v_acct_cust IS NULL OR v_acct_cust <> v_customer THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Linked account does not belong to you';
    END IF;
    IF v_acct_status <> 'ACTIVE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Linked account is not active';
    END IF;
    IF NOT fn_has_approved_kyc(v_customer) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'KYC must be approved before applying for a loan';
    END IF;

    SELECT COUNT(*) INTO v_in_progress
      FROM loans WHERE customer_id = v_customer AND status IN ('PENDING', 'APPROVED');
    IF v_in_progress > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'You already have a loan application in progress';
    END IF;

    -- Indicative rate by tenure; the officer can change it at approval
    SET v_rate = CASE WHEN p_tenure_months <= 12 THEN 11.00
                      WHEN p_tenure_months <= 36 THEN 11.75
                      ELSE 12.50 END;

    INSERT INTO loans (customer_id, linked_account_id, requested_amount, annual_interest_rate,
                       tenure_months, status)
    VALUES (v_customer, p_account_id, p_requested_amount, v_rate, p_tenure_months, 'PENDING');
    SET p_loan_id = LAST_INSERT_ID();

    INSERT INTO audit_logs (actor_user_id, action, entity_type, entity_id, old_values, new_values, reason)
    VALUES (p_acting_user_id, 'LOAN_APPLIED', 'loans', p_loan_id, NULL,
            JSON_OBJECT('status', 'PENDING', 'requested_amount', p_requested_amount,
                        'tenure_months', p_tenure_months),
            'Customer application');

    COMMIT;
END$$

-- ---------------------------------------------------------------------
-- sp_approve_loan: loan staff approve a PENDING loan
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_approve_loan(
    IN p_employee_user_id     INT,
    IN p_loan_id              INT,
    IN p_approved_amount      DECIMAL(15,2),
    IN p_annual_interest_rate DECIMAL(5,2),
    IN p_note                 VARCHAR(255))
BEGIN
    DECLARE v_emp       INT;
    DECLARE v_customer  INT;
    DECLARE v_requested DECIMAL(15,2);
    DECLARE v_status    VARCHAR(12);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF NOT fn_is_loan_staff(p_employee_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only loan staff can approve loans';
    END IF;
    SET v_emp = fn_employee_id(p_employee_user_id);

    START TRANSACTION;

    SELECT customer_id, requested_amount, status INTO v_customer, v_requested, v_status
      FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Loan not found';
    END IF;
    IF v_status <> 'PENDING' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only PENDING loans can be approved';
    END IF;
    IF p_approved_amount IS NULL OR p_approved_amount <= 0 OR p_approved_amount > v_requested THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Approved amount must be positive and not above the requested amount';
    END IF;
    IF p_annual_interest_rate IS NULL OR p_annual_interest_rate < 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid interest rate';
    END IF;

    UPDATE loans
       SET status = 'APPROVED', approved_amount = p_approved_amount,
           annual_interest_rate = p_annual_interest_rate, reviewed_by_employee_id = v_emp
     WHERE loan_id = p_loan_id;

    INSERT INTO audit_logs (actor_user_id, action, entity_type, entity_id, old_values, new_values, reason)
    VALUES (p_employee_user_id, 'LOAN_APPROVED', 'loans', p_loan_id,
            JSON_OBJECT('status', 'PENDING'),
            JSON_OBJECT('status', 'APPROVED', 'approved_amount', p_approved_amount,
                        'annual_interest_rate', p_annual_interest_rate),
            p_note);

    INSERT INTO notifications (user_id, transaction_id, notification_type, message)
    SELECT c.user_id, NULL, 'LOAN_APPROVED',
           CONCAT('Your loan application #', p_loan_id, ' for Rs.', FORMAT(p_approved_amount, 2),
                  ' has been approved.')
      FROM customers c WHERE c.customer_id = v_customer;

    COMMIT;
END$$

-- ---------------------------------------------------------------------
-- sp_reject_loan: loan staff reject a PENDING loan
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_reject_loan(
    IN p_employee_user_id INT,
    IN p_loan_id          INT,
    IN p_reason           VARCHAR(255))
BEGIN
    DECLARE v_emp      INT;
    DECLARE v_customer INT;
    DECLARE v_status   VARCHAR(12);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF NOT fn_is_loan_staff(p_employee_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only loan staff can reject loans';
    END IF;
    IF p_reason IS NULL OR p_reason = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A reason is required to reject a loan';
    END IF;
    SET v_emp = fn_employee_id(p_employee_user_id);

    START TRANSACTION;

    SELECT customer_id, status INTO v_customer, v_status
      FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Loan not found';
    END IF;
    IF v_status <> 'PENDING' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only PENDING loans can be rejected';
    END IF;

    UPDATE loans SET status = 'REJECTED', reviewed_by_employee_id = v_emp WHERE loan_id = p_loan_id;

    INSERT INTO audit_logs (actor_user_id, action, entity_type, entity_id, old_values, new_values, reason)
    VALUES (p_employee_user_id, 'LOAN_REJECTED', 'loans', p_loan_id,
            JSON_OBJECT('status', 'PENDING'), JSON_OBJECT('status', 'REJECTED'), p_reason);

    INSERT INTO notifications (user_id, transaction_id, notification_type, message)
    SELECT c.user_id, NULL, 'LOAN_REJECTED',
           CONCAT('Your loan application #', p_loan_id, ' was not approved.')
      FROM customers c WHERE c.customer_id = v_customer;

    COMMIT;
END$$

-- ---------------------------------------------------------------------
-- sp_disburse_loan: a MANAGER disburses an APPROVED loan.
--   Four-eyes rule: the disbursing employee must differ from the approver.
--   One database transaction: LOAN_DISBURSEMENT transaction + CREDIT ledger
--   entry + balance update + installment schedule + loan status.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_disburse_loan(
    IN  p_employee_user_id INT,
    IN  p_loan_id          INT,
    OUT p_transaction_id   BIGINT)
BEGIN
    DECLARE v_emp         INT;
    DECLARE v_customer    INT;
    DECLARE v_account     INT;
    DECLARE v_amount      DECIMAL(15,2);
    DECLARE v_rate        DECIMAL(5,2);
    DECLARE v_n           INT;
    DECLARE v_status      VARCHAR(12);
    DECLARE v_reviewer    INT;
    DECLARE v_acc_status  VARCHAR(10);
    DECLARE v_branch      INT;
    DECLARE v_r           DOUBLE;
    DECLARE v_emi         DECIMAL(15,2);
    DECLARE v_bal         DECIMAL(15,2);
    DECLARE v_int         DECIMAL(15,2);
    DECLARE v_prin        DECIMAL(15,2);
    DECLARE v_k           INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF NOT fn_is_manager(p_employee_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only a manager can disburse a loan';
    END IF;
    SET v_emp = fn_employee_id(p_employee_user_id);

    START TRANSACTION;

    SELECT customer_id, linked_account_id, approved_amount, annual_interest_rate,
           tenure_months, status, reviewed_by_employee_id
      INTO v_customer, v_account, v_amount, v_rate, v_n, v_status, v_reviewer
      FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Loan not found';
    END IF;
    IF v_status <> 'APPROVED' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only APPROVED loans can be disbursed';
    END IF;
    IF v_reviewer = v_emp THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Disbursement must be done by a different employee than the approver';
    END IF;

    SELECT status, branch_id INTO v_acc_status, v_branch
      FROM accounts WHERE account_id = v_account FOR UPDATE;
    IF v_acc_status IS NULL OR v_acc_status <> 'ACTIVE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Linked account is not active';
    END IF;

    -- Disbursement transaction (idempotency key makes a second disbursement impossible)
    INSERT INTO transactions (reference_number, transaction_type, destination_account_id, amount,
                              status, initiated_by_user_id, reviewed_by_employee_id, branch_id,
                              review_note, idempotency_key)
    VALUES (CONCAT('TMP', UUID_SHORT()), 'LOAN_DISBURSEMENT', v_account, v_amount,
            'PENDING', p_employee_user_id, v_emp, v_branch,
            CONCAT('Disbursement of loan #', p_loan_id), CONCAT('LOAN-DISB-', p_loan_id));
    SET p_transaction_id = LAST_INSERT_ID();

    UPDATE transactions
       SET reference_number = CONCAT('TXN', DATE_FORMAT(created_at, '%Y%m%d'), LPAD(transaction_id, 8, '0'))
     WHERE transaction_id = p_transaction_id;

    CALL sp_internal_post_entry(p_transaction_id, v_account, 'CREDIT', v_amount);

    UPDATE transactions SET status = 'POSTED', posted_at = NOW()
     WHERE transaction_id = p_transaction_id;

    -- EMI schedule (reducing balance); the last installment clears the remaining principal
    SET v_r = v_rate / 1200;
    IF v_r = 0 THEN
        SET v_emi = ROUND(v_amount / v_n, 2);
    ELSE
        SET v_emi = ROUND(v_amount * v_r * POW(1 + v_r, v_n) / (POW(1 + v_r, v_n) - 1), 2);
    END IF;

    SET v_bal = v_amount;
    SET v_k = 1;
    WHILE v_k <= v_n DO
        SET v_int = ROUND(v_bal * v_r, 2);
        IF v_k < v_n THEN
            SET v_prin = ROUND(v_emi - v_int, 2);
        ELSE
            SET v_prin = v_bal;
        END IF;
        SET v_bal = v_bal - v_prin;

        INSERT INTO loan_installments (loan_id, installment_number, due_date,
                                       principal_due, interest_due, status)
        VALUES (p_loan_id, v_k, DATE_ADD(CURDATE(), INTERVAL v_k MONTH), v_prin, v_int, 'PENDING');

        SET v_k = v_k + 1;
    END WHILE;

    UPDATE loans
       SET status = 'DISBURSED', disbursement_transaction_id = p_transaction_id
     WHERE loan_id = p_loan_id;

    INSERT INTO audit_logs (actor_user_id, action, entity_type, entity_id, old_values, new_values, reason)
    VALUES (p_employee_user_id, 'LOAN_DISBURSED', 'loans', p_loan_id,
            JSON_OBJECT('status', 'APPROVED'),
            JSON_OBJECT('status', 'DISBURSED', 'transaction_id', p_transaction_id),
            'Loan amount credited to linked account');

    INSERT INTO notifications (user_id, transaction_id, notification_type, message)
    SELECT c.user_id, p_transaction_id, 'LOAN_DISBURSED',
           CONCAT('Rs.', FORMAT(v_amount, 2), ' from your loan #', p_loan_id,
                  ' has been credited to your account.')
      FROM customers c WHERE c.customer_id = v_customer;

    COMMIT;
END$$

-- ---------------------------------------------------------------------
-- sp_pay_installment: the account holder pays one EMI from the linked account.
--   Installments must be paid in order; the last payment closes the loan.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_pay_installment(
    IN  p_acting_user_id  INT,
    IN  p_installment_id  INT,
    OUT p_transaction_id  BIGINT)
BEGIN
    DECLARE v_loan         INT;
    DECLARE v_number       INT;
    DECLARE v_prin         DECIMAL(15,2);
    DECLARE v_int          DECIMAL(15,2);
    DECLARE v_inst_status  VARCHAR(10);
    DECLARE v_account      INT;
    DECLARE v_loan_status  VARCHAR(12);
    DECLARE v_earlier      INT DEFAULT 0;
    DECLARE v_remaining    INT DEFAULT 0;
    DECLARE v_acc_status   VARCHAR(10);
    DECLARE v_branch       INT;
    DECLARE v_balance      DECIMAL(15,2);
    DECLARE v_min          DECIMAL(15,2);
    DECLARE v_amount       DECIMAL(15,2);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF NOT fn_is_active_user(p_acting_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Acting user is not active';
    END IF;

    START TRANSACTION;

    SELECT loan_id, installment_number, principal_due, interest_due, status
      INTO v_loan, v_number, v_prin, v_int, v_inst_status
      FROM loan_installments WHERE installment_id = p_installment_id FOR UPDATE;
    IF v_inst_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Installment not found';
    END IF;
    IF v_inst_status = 'PAID' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Installment is already paid';
    END IF;

    SELECT linked_account_id, status INTO v_account, v_loan_status
      FROM loans WHERE loan_id = v_loan FOR UPDATE;
    IF v_loan_status <> 'DISBURSED' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Loan is not active for repayment';
    END IF;
    IF NOT fn_is_account_owner(p_acting_user_id, v_account) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only the account holder can pay this installment';
    END IF;

    SELECT COUNT(*) INTO v_earlier
      FROM loan_installments
     WHERE loan_id = v_loan AND installment_number < v_number AND status <> 'PAID';
    IF v_earlier > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Earlier installments must be paid first';
    END IF;

    SELECT a.status, a.branch_id, a.current_balance, t.minimum_balance
      INTO v_acc_status, v_branch, v_balance, v_min
      FROM accounts a JOIN account_types t ON t.account_type_id = a.account_type_id
     WHERE a.account_id = v_account FOR UPDATE OF a;
    IF v_acc_status <> 'ACTIVE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Linked account is not active';
    END IF;

    SET v_amount = v_prin + v_int;
    IF v_balance - v_amount < v_min THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient balance to pay this installment';
    END IF;

    INSERT INTO transactions (reference_number, transaction_type, source_account_id, amount,
                              status, initiated_by_user_id, branch_id, review_note, idempotency_key)
    VALUES (CONCAT('TMP', UUID_SHORT()), 'LOAN_REPAYMENT', v_account, v_amount,
            'PENDING', p_acting_user_id, v_branch,
            CONCAT('Loan ', v_loan, ' EMI ', v_number), CONCAT('LOAN-EMI-', p_installment_id));
    SET p_transaction_id = LAST_INSERT_ID();

    UPDATE transactions
       SET reference_number = CONCAT('TXN', DATE_FORMAT(created_at, '%Y%m%d'), LPAD(transaction_id, 8, '0'))
     WHERE transaction_id = p_transaction_id;

    CALL sp_internal_post_entry(p_transaction_id, v_account, 'DEBIT', v_amount);

    UPDATE transactions SET status = 'POSTED', posted_at = NOW()
     WHERE transaction_id = p_transaction_id;

    UPDATE loan_installments
       SET status = 'PAID', payment_transaction_id = p_transaction_id, paid_at = NOW()
     WHERE installment_id = p_installment_id;

    SELECT COUNT(*) INTO v_remaining
      FROM loan_installments WHERE loan_id = v_loan AND status <> 'PAID';
    IF v_remaining = 0 THEN
        UPDATE loans SET status = 'CLOSED' WHERE loan_id = v_loan;

        INSERT INTO notifications (user_id, transaction_id, notification_type, message)
        SELECT c.user_id, p_transaction_id, 'LOAN_CLOSED',
               CONCAT('Congratulations! Your loan #', v_loan, ' has been fully repaid.')
          FROM loans l JOIN customers c ON c.customer_id = l.customer_id
         WHERE l.loan_id = v_loan;
    END IF;

    INSERT INTO notifications (user_id, transaction_id, notification_type, message)
    SELECT c.user_id, p_transaction_id, 'TXN_POSTED',
           CONCAT('EMI ', v_number, ' of Rs.', FORMAT(v_amount, 2), ' paid for loan #', v_loan, '.')
      FROM loans l JOIN customers c ON c.customer_id = l.customer_id
     WHERE l.loan_id = v_loan;

    COMMIT;
END$$

-- =====================================================================
-- PART 6: ACCOUNT, KYC AND BENEFICIARY PROCEDURES
-- =====================================================================

-- ---------------------------------------------------------------------
-- sp_open_account: an employee opens an account for a KYC-approved customer
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_open_account(
    IN  p_employee_user_id INT,
    IN  p_customer_id      INT,
    IN  p_account_type_id  INT,
    IN  p_branch_id        INT,
    OUT p_account_id       INT)
BEGIN
    DECLARE v_cust_user    INT;
    DECLARE v_type_status  VARCHAR(10);
    DECLARE v_branch_status VARCHAR(10);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF NOT fn_is_active_employee(p_employee_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only an active employee can open an account';
    END IF;

    START TRANSACTION;

    SELECT user_id INTO v_cust_user FROM customers WHERE customer_id = p_customer_id FOR UPDATE;
    IF v_cust_user IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Customer not found';
    END IF;
    IF NOT fn_has_approved_kyc(p_customer_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Customer KYC is not approved';
    END IF;

    SELECT status INTO v_type_status FROM account_types WHERE account_type_id = p_account_type_id;
    IF v_type_status IS NULL OR v_type_status <> 'ACTIVE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Account type not found or inactive';
    END IF;
    SELECT status INTO v_branch_status FROM branches WHERE branch_id = p_branch_id;
    IF v_branch_status IS NULL OR v_branch_status <> 'ACTIVE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Branch not found or inactive';
    END IF;

    INSERT INTO accounts (account_number, customer_id, account_type_id, branch_id, current_balance, status)
    VALUES (SUBSTRING(CONCAT('T', UUID_SHORT()), 1, 20), p_customer_id, p_account_type_id, p_branch_id, 0.00, 'ACTIVE');
    SET p_account_id = LAST_INSERT_ID();

    UPDATE accounts
       SET account_number = CONCAT(LPAD(p_branch_id, 3, '0'), LPAD(p_account_type_id, 3, '0'),
                                   LPAD(p_account_id, 6, '0'))
     WHERE account_id = p_account_id;

    INSERT INTO audit_logs (actor_user_id, action, entity_type, entity_id, old_values, new_values, reason)
    VALUES (p_employee_user_id, 'ACCOUNT_OPENED', 'accounts', p_account_id, NULL,
            JSON_OBJECT('customer_id', p_customer_id, 'account_type_id', p_account_type_id,
                        'branch_id', p_branch_id),
            'New account opened');

    INSERT INTO notifications (user_id, transaction_id, notification_type, message)
    VALUES (v_cust_user, NULL, 'ACCOUNT_OPENED', 'Your new account has been opened.');

    COMMIT;
END$$

-- ---------------------------------------------------------------------
-- sp_review_kyc: KYC staff approve or reject a PENDING KYC record
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_review_kyc(
    IN p_employee_user_id INT,
    IN p_kyc_id           INT,
    IN p_decision         VARCHAR(10),      -- 'APPROVED' or 'REJECTED'
    IN p_note             VARCHAR(500))
BEGIN
    DECLARE v_emp      INT;
    DECLARE v_customer INT;
    DECLARE v_status   VARCHAR(10);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_decision NOT IN ('APPROVED', 'REJECTED') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Decision must be APPROVED or REJECTED';
    END IF;
    IF NOT fn_is_kyc_staff(p_employee_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only KYC staff can review KYC records';
    END IF;
    SET v_emp = fn_employee_id(p_employee_user_id);

    START TRANSACTION;

    SELECT customer_id, status INTO v_customer, v_status
      FROM kyc_records WHERE kyc_id = p_kyc_id FOR UPDATE;
    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'KYC record not found';
    END IF;
    IF v_status <> 'PENDING' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only PENDING KYC records can be reviewed';
    END IF;

    UPDATE kyc_records
       SET status = p_decision, reviewed_by_employee_id = v_emp,
           reviewed_at = NOW(), review_note = p_note
     WHERE kyc_id = p_kyc_id;

    INSERT INTO audit_logs (actor_user_id, action, entity_type, entity_id, old_values, new_values, reason)
    VALUES (p_employee_user_id, CONCAT('KYC_', p_decision), 'kyc_records', p_kyc_id,
            JSON_OBJECT('status', 'PENDING'), JSON_OBJECT('status', p_decision), p_note);

    INSERT INTO notifications (user_id, transaction_id, notification_type, message)
    SELECT c.user_id, NULL, CONCAT('KYC_', p_decision),
           CASE p_decision WHEN 'APPROVED' THEN 'Your KYC documents have been verified successfully.'
                           ELSE 'Your KYC documents were rejected. Please resubmit.' END
      FROM customers c WHERE c.customer_id = v_customer;

    COMMIT;
END$$

-- ---------------------------------------------------------------------
-- sp_add_beneficiary: a customer adds a beneficiary (status PENDING).
-- Single-row insert, so no explicit database transaction is needed.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_add_beneficiary(
    IN  p_acting_user_id        INT,
    IN  p_beneficiary_account_id INT,
    IN  p_beneficiary_name      VARCHAR(100),
    IN  p_nickname              VARCHAR(50),
    IN  p_relationship_type     VARCHAR(30),
    OUT p_beneficiary_id        INT)
BEGIN
    DECLARE v_customer INT;
    DECLARE v_owner    INT;
    DECLARE v_status   VARCHAR(10);
    DECLARE v_dupe     INT DEFAULT 0;

    IF NOT fn_is_active_user(p_acting_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Acting user is not active';
    END IF;
    SET v_customer = fn_customer_id_of_user(p_acting_user_id);
    IF v_customer IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only customers can add beneficiaries';
    END IF;
    IF NOT fn_has_approved_kyc(v_customer) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'KYC must be approved before adding beneficiaries';
    END IF;
    IF p_beneficiary_name IS NULL OR p_beneficiary_name = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Beneficiary name is required';
    END IF;

    SELECT customer_id, status INTO v_owner, v_status
      FROM accounts WHERE account_id = p_beneficiary_account_id;
    IF v_owner IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Beneficiary account not found';
    END IF;
    IF v_status <> 'ACTIVE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Beneficiary account is not active';
    END IF;
    IF v_owner = v_customer THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'You cannot add your own account as a beneficiary';
    END IF;

    SELECT COUNT(*) INTO v_dupe FROM beneficiaries
     WHERE customer_id = v_customer AND beneficiary_account_id = p_beneficiary_account_id;
    IF v_dupe > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This beneficiary already exists';
    END IF;

    INSERT INTO beneficiaries (customer_id, beneficiary_account_id, beneficiary_name,
                               nickname, relationship_type, status)
    VALUES (v_customer, p_beneficiary_account_id, p_beneficiary_name,
            p_nickname, p_relationship_type, 'PENDING');
    SET p_beneficiary_id = LAST_INSERT_ID();
END$$

-- ---------------------------------------------------------------------
-- sp_approve_beneficiary: an employee activates a PENDING beneficiary
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_approve_beneficiary(
    IN p_employee_user_id    INT,
    IN p_beneficiary_id      INT,
    IN p_daily_transfer_limit DECIMAL(15,2))   -- NULL = no per-beneficiary limit
BEGIN
    DECLARE v_customer INT;
    DECLARE v_status   VARCHAR(10);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF NOT fn_is_active_employee(p_employee_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only an active employee can approve beneficiaries';
    END IF;
    IF p_daily_transfer_limit IS NOT NULL AND p_daily_transfer_limit < 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Daily limit cannot be negative';
    END IF;

    START TRANSACTION;

    SELECT customer_id, status INTO v_customer, v_status
      FROM beneficiaries WHERE beneficiary_id = p_beneficiary_id FOR UPDATE;
    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Beneficiary not found';
    END IF;
    IF v_status <> 'PENDING' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only PENDING beneficiaries can be approved';
    END IF;

    UPDATE beneficiaries
       SET status = 'ACTIVE', approved_at = NOW(), daily_transfer_limit = p_daily_transfer_limit
     WHERE beneficiary_id = p_beneficiary_id;

    INSERT INTO audit_logs (actor_user_id, action, entity_type, entity_id, old_values, new_values, reason)
    VALUES (p_employee_user_id, 'BENEFICIARY_APPROVED', 'beneficiaries', p_beneficiary_id,
            JSON_OBJECT('status', 'PENDING'), JSON_OBJECT('status', 'ACTIVE'), 'Beneficiary verified');

    INSERT INTO notifications (user_id, transaction_id, notification_type, message)
    SELECT c.user_id, NULL, 'BENEFICIARY_APPROVED', 'Your new beneficiary is now active.'
      FROM customers c WHERE c.customer_id = v_customer;

    COMMIT;
END$$

-- =====================================================================
-- PART 7: READ-ONLY REPORTING PROCEDURES
-- =====================================================================

-- Account statement with running balance (owner or active employee only)
CREATE PROCEDURE sp_get_account_statement(
    IN p_acting_user_id INT,
    IN p_account_id     INT,
    IN p_from_date      DATE,
    IN p_to_date        DATE)
BEGIN
    IF NOT (fn_is_account_owner(p_acting_user_id, p_account_id)
            OR fn_is_active_employee(p_acting_user_id)) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Not authorised to view this statement';
    END IF;

    SELECT l.created_at, t.reference_number, t.transaction_type, l.entry_type,
           l.amount, l.balance_after, t.review_note AS remarks
      FROM ledger_entries l
      JOIN transactions t ON t.transaction_id = l.transaction_id
     WHERE l.account_id = p_account_id
       AND l.created_at >= p_from_date
       AND l.created_at <  DATE_ADD(p_to_date, INTERVAL 1 DAY)
     ORDER BY l.entry_id;
END$$

-- Lists accounts whose stored balance does not match the ledger (should be empty)
CREATE PROCEDURE sp_reconcile_balances()
BEGIN
    SELECT * FROM v_balance_reconciliation WHERE is_consistent = 0;
END$$

DELIMITER ;

-- =====================================================================
-- DEMO (run these one block at a time AFTER loading banking_sample_data.sql)
-- User ids: 8 = Aarav Mehta (owns accounts 1 and 11), 10 = Rohan Gupta (account 3),
--           2 = Rajesh Sharma (Regional Manager), 6 = Mohammed Faisal (Loan Officer)
-- =====================================================================
--
-- -- 1) Transfer Rs.1,000 from Aarav (acc 1) to Priyanka (acc 4) via beneficiary 1
-- CALL sp_transfer(8, 1, 4, 1, 1000.00, 'demo-transfer-001', @txn);
-- SELECT @txn;
-- -- same key again returns the SAME transaction id, money is not moved twice
-- CALL sp_transfer(8, 1, 4, 1, 1000.00, 'demo-transfer-001', @txn2);
-- SELECT @txn2;
--
-- -- 2) Authorization failure: user 10 tries to move money out of Aarav's account
-- CALL sp_transfer(10, 1, 4, 1, 500.00, 'demo-transfer-002', @txn3);   -- ERROR
--
-- -- 3) Statement and reconciliation
-- CALL sp_get_account_statement(8, 1, '2026-10-01', '2026-10-31');
-- CALL sp_reconcile_balances();                                          -- empty = consistent
--
-- -- 4) Loan flow for Rohan Gupta (customer 3, account 3)
-- CALL sp_apply_loan(10, 3, 50000.00, 6, @loan);
-- CALL sp_approve_loan(6, @loan, 50000.00, 11.00, 'Documents verified');
-- CALL sp_disburse_loan(2, @loan, @disb_txn);
-- SELECT installment_id INTO @inst FROM loan_installments
--  WHERE loan_id = @loan AND installment_number = 1;
-- CALL sp_pay_installment(10, @inst, @emi_txn);
-- SELECT * FROM loan_installments WHERE loan_id = @loan;
-- CALL sp_reconcile_balances();
