-- =====================================================================
-- BigBank - Banking Management System
-- File 2 of 4: TRIGGERS, VIEWS, FUNCTION, STORED PROCEDURES, EVENT
--
-- This is where the bank's rules live. Because they are inside the
-- database, the website (or anyone typing SQL) cannot skip them.
--
-- How a trigger knows WHO did something:
--   the website runs  SET @app_user_id = <logged-in user id>  on every
--   connection, and the audit triggers read @app_user_id.
--   (When testing in the terminal, run  SET @app_user_id = 201;  first.)
-- =====================================================================

USE banking_system;

-- =====================================================================
-- PART 1: VIEWS (derived attributes - calculated, never stored)
-- =====================================================================

-- Every account with its type, branch, owner and this month's spending.
-- spent_this_month = money that left the account (successful rows) this month.
CREATE OR REPLACE VIEW v_account_overview AS
SELECT a.account_id,
       a.customer_id,
       u.name                                   AS customer_name,
       t.name                                   AS account_type,
       t.interest_rate,
       t.min_balance,
       b.name                                   AS branch_name,
       a.branch_id,
       a.balance,
       a.daily_limit,
       a.spending_budget,
       a.status,
       a.opened_at,
       COALESCE(s.spent, 0)                     AS spent_this_month,
       a.spending_budget - COALESCE(s.spent, 0) AS budget_remaining  -- NULL if no budget
FROM accounts a
JOIN users u         ON u.user_id = a.customer_id
JOIN account_types t ON t.account_type_id = a.account_type_id
JOIN branches b      ON b.branch_id = a.branch_id
LEFT JOIN (
        SELECT source_account_id, SUM(amount) AS spent
        FROM transactions
        WHERE status = 'Success'
          AND created_at >= DATE_FORMAT(CURDATE(), '%Y-%m-01')   -- 1st of this month
        GROUP BY source_account_id
     ) s ON s.source_account_id = a.account_id;

-- Every loan with its outstanding balance and next due date.
CREATE OR REPLACE VIEW v_loan_summary AS
SELECT l.loan_id,
       l.customer_id,
       u.name AS customer_name,
       l.linked_account_id,
       a.branch_id,                       -- a loan belongs to the branch of its account
       l.principal,
       l.interest_rate,
       l.tenure_months,
       l.status,
       l.requested_at,
       COALESCE(SUM(CASE WHEN i.status <> 'Paid' THEN i.principal_part END), 0) AS outstanding_balance,
       COALESCE(SUM(CASE WHEN i.status <> 'Paid'
                         THEN i.principal_part + i.interest_part END), 0)       AS amount_to_close,
       COALESCE(SUM(i.status = 'Paid'), 0)                                     AS installments_paid,
       MIN(CASE WHEN i.status <> 'Paid' THEN i.installment_no END)              AS next_installment_no,
       MIN(CASE WHEN i.status <> 'Paid' THEN i.due_date END)                    AS next_due_date
FROM loans l
JOIN users u    ON u.user_id = l.customer_id
JOIN accounts a ON a.account_id = l.linked_account_id
LEFT JOIN loan_installments i ON i.loan_id = l.loan_id
GROUP BY l.loan_id;

-- Overdue installments and how many days late they are.
CREATE OR REPLACE VIEW v_overdue_installments AS
SELECT i.loan_id,
       i.installment_no,
       l.customer_id,
       u.name                               AS customer_name,
       a.branch_id,
       i.due_date,
       i.principal_part + i.interest_part   AS emi,
       DATEDIFF(CURDATE(), i.due_date)      AS days_overdue
FROM loan_installments i
JOIN loans l    ON l.loan_id = i.loan_id
JOIN users u    ON u.user_id = l.customer_id
JOIN accounts a ON a.account_id = l.linked_account_id
WHERE i.status = 'Overdue';

-- One row per branch, for the branch manager.
CREATE OR REPLACE VIEW v_branch_summary AS
SELECT b.branch_id,
       b.name,
       b.ifsc,
       (SELECT COUNT(*) FROM employees e WHERE e.branch_id = b.branch_id)  AS employees,
       (SELECT COUNT(*) FROM accounts a  WHERE a.branch_id = b.branch_id)  AS accounts,
       (SELECT COALESCE(SUM(a.balance), 0) FROM accounts a
         WHERE a.branch_id = b.branch_id)                                  AS total_balance,
       (SELECT COUNT(*) FROM loans l
          JOIN accounts a ON a.account_id = l.linked_account_id
         WHERE a.branch_id = b.branch_id AND l.status = 'Active')          AS active_loans
FROM branches b;


DELIMITER $$

-- =====================================================================
-- PART 2: FUNCTION
-- =====================================================================

-- How much money has already left this account today (used for daily limit).
CREATE FUNCTION fn_spent_today(p_account_id INT) RETURNS DECIMAL(12,2)
READS SQL DATA
BEGIN
    DECLARE v_total DECIMAL(12,2);
    SELECT COALESCE(SUM(amount), 0) INTO v_total
    FROM transactions
    WHERE source_account_id = p_account_id
      AND status = 'Success'
      AND DATE(created_at) = CURDATE();
    RETURN v_total;
END$$


-- =====================================================================
-- PART 3: TRIGGERS
-- =====================================================================

-- Rule: an account can be opened only if the customer's KYC is Approved,
-- and its daily limit cannot be more than its account type allows.
CREATE TRIGGER trg_accounts_before_insert
BEFORE INSERT ON accounts
FOR EACH ROW
BEGIN
    DECLARE v_kyc       VARCHAR(15);
    DECLARE v_max_limit DECIMAL(12,2);

    SELECT kyc_status INTO v_kyc FROM customers WHERE user_id = NEW.customer_id;
    IF v_kyc IS NULL OR v_kyc <> 'Approved' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'KYC must be approved before opening an account';
    END IF;

    SELECT max_daily_limit INTO v_max_limit
    FROM account_types WHERE account_type_id = NEW.account_type_id;
    IF NEW.daily_limit > v_max_limit THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Daily limit is higher than this account type allows';
    END IF;
END$$

-- Same daily limit rule when a customer changes their limit later.
CREATE TRIGGER trg_accounts_before_update
BEFORE UPDATE ON accounts
FOR EACH ROW
BEGIN
    DECLARE v_max_limit DECIMAL(12,2);

    SELECT max_daily_limit INTO v_max_limit
    FROM account_types WHERE account_type_id = NEW.account_type_id;
    IF NEW.daily_limit > v_max_limit THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Daily limit is higher than this account type allows';
    END IF;
END$$

-- Audit: record every change of account status (Active / Frozen / Closed).
CREATE TRIGGER trg_accounts_after_update
AFTER UPDATE ON accounts
FOR EACH ROW
BEGIN
    IF OLD.status <> NEW.status THEN
        INSERT INTO audit_logs (actor_user_id, action, table_name, record_id, old_value, new_value)
        VALUES (@app_user_id, CONCAT('ACCOUNT_', UPPER(NEW.status)), 'accounts',
                NEW.account_id, OLD.status, NEW.status);

        INSERT INTO notifications (user_id, category, message)
        VALUES (NEW.customer_id, 'Security',
                CONCAT('Your account ', NEW.account_id, ' is now ', NEW.status));
    END IF;
END$$

-- When an employee reviews a KYC record:
--   1. copy the decision to customers.kyc_status
--   2. write the audit log
--   3. notify the customer
CREATE TRIGGER trg_kyc_after_update
AFTER UPDATE ON kyc_records
FOR EACH ROW
BEGIN
    IF OLD.status <> NEW.status THEN
        IF NEW.status IN ('Approved', 'Rejected') THEN
            UPDATE customers SET kyc_status = NEW.status WHERE user_id = NEW.customer_id;
        END IF;

        INSERT INTO audit_logs (actor_user_id, action, table_name, record_id, old_value, new_value)
        VALUES (NEW.reviewed_by_employee_id, CONCAT('KYC_', UPPER(NEW.status)), 'customers',
                NEW.customer_id, OLD.status, NEW.status);

        INSERT INTO notifications (user_id, category, message)
        VALUES (NEW.customer_id, 'KYC',
                CONCAT('Your KYC is ', NEW.status, IFNULL(CONCAT(': ', NEW.remarks), '')));
    END IF;
END$$

-- Rule: the account linked to a loan must belong to the same customer.
CREATE TRIGGER trg_loans_before_insert
BEFORE INSERT ON loans
FOR EACH ROW
BEGIN
    DECLARE v_owner INT;
    SELECT customer_id INTO v_owner FROM accounts WHERE account_id = NEW.linked_account_id;
    IF v_owner IS NULL OR v_owner <> NEW.customer_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A loan must be linked to your own account';
    END IF;
END$$

-- Audit + notify whenever a loan changes status.
CREATE TRIGGER trg_loans_after_update
AFTER UPDATE ON loans
FOR EACH ROW
BEGIN
    IF OLD.status <> NEW.status THEN
        INSERT INTO audit_logs (actor_user_id, action, table_name, record_id, old_value, new_value)
        VALUES (COALESCE(@app_user_id, NEW.reviewed_by_employee_id),
                CASE NEW.status WHEN 'Active'   THEN 'LOAN_APPROVED'
                                WHEN 'Rejected' THEN 'LOAN_REJECTED'
                                ELSE                 'LOAN_CLOSED' END,
                'loans', NEW.loan_id, OLD.status, NEW.status);

        INSERT INTO notifications (user_id, category, message)
        VALUES (NEW.customer_id, 'Loan',
                CONCAT('Your loan ', NEW.loan_id, ' is now ', NEW.status));
    END IF;
END$$

-- Audit whenever an employee approves or rejects a pending transaction.
CREATE TRIGGER trg_txn_after_update
AFTER UPDATE ON transactions
FOR EACH ROW
BEGIN
    IF OLD.status <> NEW.status THEN
        INSERT INTO audit_logs (actor_user_id, action, table_name, record_id, old_value, new_value)
        VALUES (NEW.reviewed_by_employee_id, CONCAT('TXN_', UPPER(NEW.status)), 'transactions',
                NEW.transaction_id, OLD.status, NEW.status);
    END IF;
END$$

-- Rule: transactions are history. They are never deleted
-- (mistakes are fixed with a reversal, see sp_reverse_transaction).
CREATE TRIGGER trg_txn_no_delete
BEFORE DELETE ON transactions
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transactions cannot be deleted. Post a reversal instead.';
END$$

-- Rule: the audit log is append-only.
CREATE TRIGGER trg_audit_no_update
BEFORE UPDATE ON audit_logs
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Audit log cannot be changed';
END$$

CREATE TRIGGER trg_audit_no_delete
BEFORE DELETE ON audit_logs
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Audit log cannot be deleted';
END$$


-- =====================================================================
-- PART 4: STORED PROCEDURES
-- Every procedure that moves money follows the same pattern:
--   START TRANSACTION
--   lock the rows with SELECT ... FOR UPDATE
--   check the rules (SIGNAL an error if one fails)
--   update balances + insert the transaction row
--   COMMIT
-- If ANY error happens, the EXIT HANDLER runs ROLLBACK, so nothing is half done.
-- =====================================================================

-- Small helper: after money leaves an account, warn the owner if they
-- have gone over their monthly spending budget.
CREATE PROCEDURE sp_check_budget(IN p_account_id INT)
BEGIN
    DECLARE v_owner     INT;
    DECLARE v_remaining DECIMAL(12,2);

    SELECT customer_id, budget_remaining INTO v_owner, v_remaining
    FROM v_account_overview WHERE account_id = p_account_id;

    IF v_remaining IS NOT NULL AND v_remaining < 0 THEN
        INSERT INTO notifications (user_id, category, message)
        VALUES (v_owner, 'Budget',
                CONCAT('Account ', p_account_id, ' is over its monthly budget by Rs ', -v_remaining));
    END IF;
END$$

-- ---------------------------------------------------------------------
-- 1. TRANSFER money from one account to another (instant, atomic).
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_transfer(
    IN p_user_id INT,           -- who is sending (must own the source account)
    IN p_from    INT,
    IN p_to      INT,
    IN p_amount  DECIMAL(12,2),
    IN p_key     VARCHAR(40))   -- idempotency key from the form
BEGIN
    DECLARE v_owner       INT;
    DECLARE v_balance     DECIMAL(12,2);
    DECLARE v_from_status VARCHAR(10);
    DECLARE v_to_owner    INT;
    DECLARE v_to_status   VARCHAR(10);
    DECLARE v_min_balance DECIMAL(12,2);
    DECLARE v_daily_limit DECIMAL(12,2);
    DECLARE v_txn_id      INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;   -- undo everything
        RESIGNAL;   -- pass the error message on to the website
    END;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Amount must be greater than zero';
    END IF;
    IF p_from = p_to THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cannot transfer to the same account';
    END IF;

    START TRANSACTION;

    -- Lock both rows, always the smaller account_id first.
    -- (If two transfers lock in opposite order they can deadlock.)
    SELECT status INTO v_from_status FROM accounts WHERE account_id = LEAST(p_from, p_to)    FOR UPDATE;
    SELECT status INTO v_from_status FROM accounts WHERE account_id = GREATEST(p_from, p_to) FOR UPDATE;

    -- Now read the details we need (rows are already locked).
    SELECT a.customer_id, a.balance, a.status, a.daily_limit, t.min_balance
      INTO v_owner, v_balance, v_from_status, v_daily_limit, v_min_balance
    FROM accounts a JOIN account_types t ON t.account_type_id = a.account_type_id
    WHERE a.account_id = p_from;

    SELECT customer_id, status INTO v_to_owner, v_to_status
    FROM accounts WHERE account_id = p_to;

    -- Validate
    IF v_owner IS NULL OR v_owner <> p_user_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'You can only send money from your own account';
    END IF;
    IF v_to_owner IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Destination account does not exist';
    END IF;
    IF v_from_status <> 'Active' OR v_to_status <> 'Active' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Both accounts must be Active';
    END IF;
    IF v_balance - p_amount < v_min_balance THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient balance (minimum balance must be kept)';
    END IF;
    IF fn_spent_today(p_from) + p_amount > v_daily_limit THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Daily limit exceeded';
    END IF;

    -- Move the money
    UPDATE accounts SET balance = balance - p_amount WHERE account_id = p_from;
    UPDATE accounts SET balance = balance + p_amount WHERE account_id = p_to;

    -- Record it (a repeated idempotency_key fails here because it is UNIQUE)
    INSERT INTO transactions (source_account_id, destination_account_id, initiated_by_user_id,
                              type, amount, status, idempotency_key)
    VALUES (p_from, p_to, p_user_id, 'Transfer', p_amount, 'Success', p_key);
    SET v_txn_id = LAST_INSERT_ID();

    INSERT INTO notifications (user_id, category, message, transaction_id) VALUES
        (v_owner,    'Transaction', CONCAT('Rs ', p_amount, ' sent from account ', p_from, ' to ', p_to), v_txn_id),
        (v_to_owner, 'Transaction', CONCAT('Rs ', p_amount, ' received in account ', p_to), v_txn_id);

    CALL sp_check_budget(p_from);

    COMMIT;
END$$

-- ---------------------------------------------------------------------
-- 2. REVIEW a pending deposit / withdrawal (employee approves or rejects).
--    Only an approved request changes the balance.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_review_transaction(
    IN p_employee_id INT,
    IN p_txn_id      INT,
    IN p_decision    VARCHAR(10))   -- 'Approve' or 'Reject'
BEGIN
    DECLARE v_type        VARCHAR(10);
    DECLARE v_amount      DECIMAL(12,2);
    DECLARE v_status      VARCHAR(10);
    DECLARE v_account     INT;
    DECLARE v_owner       INT;
    DECLARE v_balance     DECIMAL(12,2);
    DECLARE v_acc_status  VARCHAR(10);
    DECLARE v_min_balance DECIMAL(12,2);
    DECLARE v_daily_limit DECIMAL(12,2);
    DECLARE v_branch      INT;    -- the employee's branch
    DECLARE v_acc_branch  INT;    -- the account's branch

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SELECT branch_id INTO v_branch FROM employees WHERE user_id = p_employee_id;
    IF v_branch IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only an employee can review transactions';
    END IF;

    START TRANSACTION;

    -- Lock the transaction row
    SELECT type, amount, status, COALESCE(source_account_id, destination_account_id)
      INTO v_type, v_amount, v_status, v_account
    FROM transactions WHERE transaction_id = p_txn_id FOR UPDATE;

    IF v_status IS NULL OR v_status <> 'Pending' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This transaction is not pending';
    END IF;

    -- Lock the account row
    SELECT a.customer_id, a.balance, a.status, a.daily_limit, t.min_balance, a.branch_id
      INTO v_owner, v_balance, v_acc_status, v_daily_limit, v_min_balance, v_acc_branch
    FROM accounts a JOIN account_types t ON t.account_type_id = a.account_type_id
    WHERE a.account_id = v_account FOR UPDATE;

    -- Staff can only act on accounts of their own branch
    IF v_acc_branch <> v_branch THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This account belongs to another branch';
    END IF;

    IF p_decision = 'Reject' THEN
        UPDATE transactions
           SET status = 'Rejected', reviewed_by_employee_id = p_employee_id, branch_id = v_branch
         WHERE transaction_id = p_txn_id;
    ELSE
        IF v_acc_status <> 'Active' THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Account is not Active';
        END IF;

        IF v_type = 'Withdrawal' THEN
            IF v_balance - v_amount < v_min_balance THEN
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient balance (minimum balance must be kept)';
            END IF;
            IF fn_spent_today(v_account) + v_amount > v_daily_limit THEN
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Daily limit exceeded';
            END IF;
            UPDATE accounts SET balance = balance - v_amount WHERE account_id = v_account;
        ELSE
            UPDATE accounts SET balance = balance + v_amount WHERE account_id = v_account;
        END IF;

        UPDATE transactions
           SET status = 'Success', reviewed_by_employee_id = p_employee_id, branch_id = v_branch
         WHERE transaction_id = p_txn_id;
    END IF;

    INSERT INTO notifications (user_id, category, message, transaction_id)
    VALUES (v_owner, 'Transaction',
            CONCAT('Your ', LOWER(v_type), ' of Rs ', v_amount, ' was ',
                   IF(p_decision = 'Reject', 'rejected', 'approved')),
            p_txn_id);

    IF p_decision <> 'Reject' AND v_type = 'Withdrawal' THEN
        CALL sp_check_budget(v_account);
    END IF;

    COMMIT;
END$$

-- ---------------------------------------------------------------------
-- 3. REVERSE a mistaken transaction.
--    Nothing is deleted. A new row is posted that moves the same amount
--    the opposite way (source and destination swapped).
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_reverse_transaction(
    IN p_employee_id INT,
    IN p_txn_id      INT)
BEGIN
    DECLARE v_type     VARCHAR(10);
    DECLARE v_amount   DECIMAL(12,2);
    DECLARE v_status   VARCHAR(10);
    DECLARE v_src      INT;
    DECLARE v_dst      INT;
    DECLARE v_is_rev   INT;
    DECLARE v_balance  DECIMAL(12,2);
    DECLARE v_branch   INT;
    DECLARE v_new_type VARCHAR(10);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SELECT branch_id INTO v_branch FROM employees WHERE user_id = p_employee_id;
    IF v_branch IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only an employee can reverse transactions';
    END IF;

    START TRANSACTION;

    SELECT type, amount, status, source_account_id, destination_account_id, reversal_of_transaction_id
      INTO v_type, v_amount, v_status, v_src, v_dst, v_is_rev
    FROM transactions WHERE transaction_id = p_txn_id FOR UPDATE;

    IF v_status IS NULL OR v_status <> 'Success' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only a successful transaction can be reversed';
    END IF;
    IF v_is_rev IS NOT NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A reversal cannot be reversed again';
    END IF;
    IF EXISTS (SELECT 1 FROM transactions WHERE reversal_of_transaction_id = p_txn_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This transaction is already reversed';
    END IF;
    -- At least one of the two accounts must be in the employee's branch
    IF NOT EXISTS (SELECT 1 FROM accounts
                   WHERE branch_id = v_branch AND account_id IN (v_src, v_dst)) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This transaction belongs to another branch';
    END IF;

    -- Swap the direction: money goes back from the old destination to the old source.
    SET v_new_type = CASE v_type WHEN 'Deposit'    THEN 'Withdrawal'
                                 WHEN 'Withdrawal' THEN 'Deposit'
                                 ELSE                   'Transfer' END;

    -- Take the money back from the account that received it
    IF v_dst IS NOT NULL THEN
        SELECT balance INTO v_balance FROM accounts WHERE account_id = v_dst FOR UPDATE;
        IF v_balance < v_amount THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Not enough balance to reverse this transaction';
        END IF;
        UPDATE accounts SET balance = balance - v_amount WHERE account_id = v_dst;
    END IF;

    -- Give it back to the account it came from
    IF v_src IS NOT NULL THEN
        UPDATE accounts SET balance = balance + v_amount WHERE account_id = v_src;
    END IF;

    INSERT INTO transactions (source_account_id, destination_account_id, branch_id,
                              initiated_by_user_id, reviewed_by_employee_id, reversal_of_transaction_id,
                              type, amount, status, idempotency_key)
    VALUES (v_dst, v_src, v_branch, p_employee_id, p_employee_id, p_txn_id,
            v_new_type, v_amount, 'Success', CONCAT('REV-', p_txn_id));

    INSERT INTO audit_logs (actor_user_id, action, table_name, record_id, old_value, new_value)
    VALUES (p_employee_id, 'TXN_REVERSED', 'transactions', p_txn_id, 'Success',
            CONCAT('reversed by ', LAST_INSERT_ID()));

    COMMIT;
END$$

-- ---------------------------------------------------------------------
-- 4. APPROVE a loan:
--    a) pay the principal into the linked account (a Deposit transaction)
--    b) create one row in loan_installments for every month
--    c) mark the loan Active
--
--    Installment formula (same as the sample data in the report):
--      principal_part = principal / tenure_months      (same every month)
--      interest_part  = remaining principal * yearly rate / 12 / 100
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_approve_loan(
    IN p_employee_id INT,
    IN p_loan_id     INT)
BEGIN
    DECLARE v_status     VARCHAR(10);
    DECLARE v_principal  DECIMAL(12,2);
    DECLARE v_rate       DECIMAL(4,2);
    DECLARE v_tenure     INT;
    DECLARE v_account    INT;
    DECLARE v_acc_status VARCHAR(10);
    DECLARE v_branch     INT;    -- the employee's branch
    DECLARE v_acc_branch INT;    -- the linked account's branch
    DECLARE v_txn_id     INT;
    DECLARE v_i          INT DEFAULT 1;
    DECLARE v_remaining  DECIMAL(12,2);
    DECLARE v_part       DECIMAL(10,2);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SELECT branch_id INTO v_branch FROM employees WHERE user_id = p_employee_id;
    IF v_branch IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only an employee can approve loans';
    END IF;

    START TRANSACTION;

    SELECT status, principal, interest_rate, tenure_months, linked_account_id
      INTO v_status, v_principal, v_rate, v_tenure, v_account
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;

    IF v_status IS NULL OR v_status <> 'Requested' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This loan is not waiting for approval';
    END IF;

    SELECT status, branch_id INTO v_acc_status, v_acc_branch
    FROM accounts WHERE account_id = v_account FOR UPDATE;
    IF v_acc_branch <> v_branch THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This loan belongs to another branch';
    END IF;
    IF v_acc_status <> 'Active' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Linked account is not Active';
    END IF;

    -- a) pay out the loan
    UPDATE accounts SET balance = balance + v_principal WHERE account_id = v_account;

    INSERT INTO transactions (destination_account_id, branch_id, initiated_by_user_id,
                              reviewed_by_employee_id, type, amount, status, idempotency_key)
    VALUES (v_account, v_branch, p_employee_id, p_employee_id,
            'Deposit', v_principal, 'Success', CONCAT('LOAN-', p_loan_id));
    SET v_txn_id = LAST_INSERT_ID();

    -- b) create the repayment schedule
    SET v_remaining = v_principal;
    SET v_part      = ROUND(v_principal / v_tenure, 2);

    WHILE v_i <= v_tenure DO
        IF v_i = v_tenure THEN
            SET v_part = v_remaining;     -- last month takes any rounding difference
        END IF;

        INSERT INTO loan_installments (loan_id, installment_no, due_date, principal_part, interest_part)
        VALUES (p_loan_id, v_i,
                DATE_ADD(CURDATE(), INTERVAL v_i MONTH),
                v_part,
                ROUND(v_remaining * v_rate / 12 / 100, 2));

        SET v_remaining = v_remaining - v_part;
        SET v_i = v_i + 1;
    END WHILE;

    -- c) activate the loan (trigger writes the audit log + notification)
    UPDATE loans
       SET status = 'Active', reviewed_by_employee_id = p_employee_id,
           disbursement_transaction_id = v_txn_id
     WHERE loan_id = p_loan_id;

    COMMIT;
END$$

-- ---------------------------------------------------------------------
-- 5. PAY one installment (EMI) from the loan's linked account.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_pay_installment(
    IN p_user_id        INT,
    IN p_loan_id        INT,
    IN p_installment_no INT)
BEGIN
    DECLARE v_owner       INT;
    DECLARE v_loan_status VARCHAR(10);
    DECLARE v_account     INT;
    DECLARE v_inst_status VARCHAR(10);
    DECLARE v_emi         DECIMAL(12,2);
    DECLARE v_balance     DECIMAL(12,2);
    DECLARE v_min_balance DECIMAL(12,2);
    DECLARE v_acc_status  VARCHAR(10);
    DECLARE v_txn_id      INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT customer_id, status, linked_account_id INTO v_owner, v_loan_status, v_account
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;

    IF v_owner IS NULL OR v_owner <> p_user_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Loan not found';
    END IF;
    IF v_loan_status <> 'Active' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Loan is not active';
    END IF;

    SELECT status, principal_part + interest_part INTO v_inst_status, v_emi
    FROM loan_installments
    WHERE loan_id = p_loan_id AND installment_no = p_installment_no FOR UPDATE;

    IF v_inst_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Installment not found';
    END IF;
    IF v_inst_status = 'Paid' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Installment is already paid';
    END IF;

    SELECT a.balance, a.status, t.min_balance INTO v_balance, v_acc_status, v_min_balance
    FROM accounts a JOIN account_types t ON t.account_type_id = a.account_type_id
    WHERE a.account_id = v_account FOR UPDATE;

    IF v_acc_status <> 'Active' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Linked account is not Active';
    END IF;
    IF v_balance - v_emi < v_min_balance THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient balance to pay this installment';
    END IF;

    UPDATE accounts SET balance = balance - v_emi WHERE account_id = v_account;

    INSERT INTO transactions (source_account_id, initiated_by_user_id, type, amount, status, idempotency_key)
    VALUES (v_account, p_user_id, 'Withdrawal', v_emi, 'Success',
            CONCAT('EMI-', p_loan_id, '-', p_installment_no));
    SET v_txn_id = LAST_INSERT_ID();

    UPDATE loan_installments
       SET status = 'Paid', payment_transaction_id = v_txn_id
     WHERE loan_id = p_loan_id AND installment_no = p_installment_no;

    -- Last installment paid? Then the loan is finished.
    IF NOT EXISTS (SELECT 1 FROM loan_installments
                   WHERE loan_id = p_loan_id AND status <> 'Paid') THEN
        UPDATE loans SET status = 'Closed' WHERE loan_id = p_loan_id;
    END IF;

    INSERT INTO notifications (user_id, category, message, transaction_id)
    VALUES (p_user_id, 'Loan',
            CONCAT('Installment ', p_installment_no, ' of loan ', p_loan_id, ' paid: Rs ', v_emi), v_txn_id);

    COMMIT;
END$$

-- ---------------------------------------------------------------------
-- 6. REPAY THE WHOLE LOAN at once.
--    Same as paying every remaining installment today: each unpaid
--    installment gets its own Withdrawal transaction (oldest first),
--    then the loan is Closed. All in ONE database transaction, so either
--    every installment is paid or none is.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_repay_loan(
    IN p_user_id INT,
    IN p_loan_id INT)
BEGIN
    DECLARE v_owner       INT;
    DECLARE v_loan_status VARCHAR(10);
    DECLARE v_account     INT;
    DECLARE v_total       DECIMAL(12,2);
    DECLARE v_balance     DECIMAL(12,2);
    DECLARE v_min_balance DECIMAL(12,2);
    DECLARE v_acc_status  VARCHAR(10);
    DECLARE v_no          INT;
    DECLARE v_emi         DECIMAL(12,2);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT customer_id, status, linked_account_id INTO v_owner, v_loan_status, v_account
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;

    IF v_owner IS NULL OR v_owner <> p_user_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Loan not found';
    END IF;
    IF v_loan_status <> 'Active' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Loan is not active';
    END IF;

    -- Total of all unpaid installments (and lock them)
    SELECT SUM(principal_part + interest_part) INTO v_total
    FROM loan_installments
    WHERE loan_id = p_loan_id AND status <> 'Paid' FOR UPDATE;

    SELECT a.balance, a.status, t.min_balance INTO v_balance, v_acc_status, v_min_balance
    FROM accounts a JOIN account_types t ON t.account_type_id = a.account_type_id
    WHERE a.account_id = v_account FOR UPDATE;

    IF v_acc_status <> 'Active' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Linked account is not Active';
    END IF;
    IF v_balance - v_total < v_min_balance THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient balance to repay the whole loan';
    END IF;

    -- Pay the unpaid installments one by one, oldest first
    SELECT MIN(installment_no) INTO v_no
    FROM loan_installments WHERE loan_id = p_loan_id AND status <> 'Paid';

    WHILE v_no IS NOT NULL DO
        SELECT principal_part + interest_part INTO v_emi
        FROM loan_installments WHERE loan_id = p_loan_id AND installment_no = v_no;

        UPDATE accounts SET balance = balance - v_emi WHERE account_id = v_account;

        INSERT INTO transactions (source_account_id, initiated_by_user_id, type, amount, status, idempotency_key)
        VALUES (v_account, p_user_id, 'Withdrawal', v_emi, 'Success',
                CONCAT('EMI-', p_loan_id, '-', v_no));

        UPDATE loan_installments
           SET status = 'Paid', payment_transaction_id = LAST_INSERT_ID()
         WHERE loan_id = p_loan_id AND installment_no = v_no;

        -- next unpaid installment (MIN returns NULL when none are left, ending the loop)
        SELECT MIN(installment_no) INTO v_no
        FROM loan_installments WHERE loan_id = p_loan_id AND status <> 'Paid';
    END WHILE;

    UPDATE loans SET status = 'Closed' WHERE loan_id = p_loan_id;

    INSERT INTO notifications (user_id, category, message)
    VALUES (p_user_id, 'Loan', CONCAT('Loan ', p_loan_id, ' fully repaid: Rs ', v_total));

    COMMIT;
END$$

-- ---------------------------------------------------------------------
-- 7. MARK OVERDUE installments (run daily by the event below,
--    or by an employee from the website).
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_mark_overdue()
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    -- Notify first (while the rows are still 'Pending' so we can find them)
    INSERT INTO notifications (user_id, category, message)
    SELECT l.customer_id, 'Loan',
           CONCAT('Installment ', i.installment_no, ' of loan ', i.loan_id,
                  ' was due on ', i.due_date, ' and is now overdue')
    FROM loan_installments i
    JOIN loans l ON l.loan_id = i.loan_id
    WHERE i.status = 'Pending' AND i.due_date < CURDATE();

    UPDATE loan_installments
       SET status = 'Overdue'
     WHERE status = 'Pending' AND due_date < CURDATE();

    COMMIT;
END$$

-- ---------------------------------------------------------------------
-- 8. ADD EMPLOYEE (branch manager onboards a new staff member)
--    Creates the login (users) and the staff profile (employees) together.
--    There is NO branch parameter: the new employee always joins the
--    manager's own branch and reports to that manager.
--    The website makes the temporary password and sends only its hash.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_add_employee(
    IN  p_manager_id    INT,
    IN  p_name          VARCHAR(60),
    IN  p_email         VARCHAR(80),
    IN  p_phone         VARCHAR(15),
    IN  p_password_hash VARCHAR(255),
    IN  p_designation   VARCHAR(30),
    OUT p_new_user_id   INT)          -- OUT parameter: sends the new id back to the caller
BEGIN
    DECLARE v_role   VARCHAR(20);
    DECLARE v_branch INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SELECT u.role, e.branch_id INTO v_role, v_branch
    FROM users u JOIN employees e ON e.user_id = u.user_id
    WHERE u.user_id = p_manager_id;

    IF v_role IS NULL OR v_role <> 'BranchManager' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only a branch manager can add employees';
    END IF;

    START TRANSACTION;

    INSERT INTO users (name, email, phone, password_hash, role)
    VALUES (p_name, p_email, p_phone, p_password_hash, 'Employee');
    SET p_new_user_id = LAST_INSERT_ID();

    INSERT INTO employees (user_id, branch_id, designation, manager_employee_id)
    VALUES (p_new_user_id, v_branch, p_designation, p_manager_id);

    INSERT INTO audit_logs (actor_user_id, action, table_name, record_id, old_value, new_value)
    VALUES (p_manager_id, 'EMPLOYEE_ADDED', 'employees', p_new_user_id, NULL,
            CONCAT(p_designation, ' at branch ', v_branch));

    COMMIT;
END$$

DELIMITER ;

-- =====================================================================
-- PART 5: EVENT - run the overdue check automatically once a day
-- (needs the MySQL event scheduler, which is ON by default in MySQL 8+)
-- =====================================================================
CREATE EVENT IF NOT EXISTS ev_mark_overdue_daily
ON SCHEDULE EVERY 1 DAY
DO CALL sp_mark_overdue();
