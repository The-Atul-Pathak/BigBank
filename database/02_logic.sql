-- =====================================================================
-- BigBank - Banking Management System
-- File 2 of 4: TRIGGERS, VIEWS, FUNCTION, STORED PROCEDURES, SCHEDULED JOB
-- PostgreSQL version (the original MySQL scripts are in database/mysql/).
--
-- This is where the bank's rules live. Because they are inside the
-- database, the website (or anyone typing SQL) cannot skip them.
--
-- How a trigger knows WHO did something:
--   the website runs  SELECT set_config('app.user_id', '<logged-in user id>', false)
--   on every connection, and the audit triggers read it back with
--   current_setting('app.user_id', true).
--   (When testing in psql, run  SET app.user_id = '201';  first.)
--
-- How errors work:
--   MySQL's  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '...'
--   becomes  RAISE EXCEPTION '...'
--   The website shows the message to the user.
--
-- Triggers and procedures are SECURITY DEFINER: like MySQL's default,
-- they run with the rights of the user who created them, so a role that
-- may only CALL sp_transfer can still move money through it.
-- =====================================================================

SET search_path = banking_system;

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
          AND created_at >= date_trunc('month', CURRENT_DATE)   -- 1st of this month
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
       COUNT(*) FILTER (WHERE i.status = 'Paid')                               AS installments_paid,
       MIN(CASE WHEN i.status <> 'Paid' THEN i.installment_no END)              AS next_installment_no,
       MIN(CASE WHEN i.status <> 'Paid' THEN i.due_date END)                    AS next_due_date
FROM loans l
JOIN users u    ON u.user_id = l.customer_id
JOIN accounts a ON a.account_id = l.linked_account_id
LEFT JOIN loan_installments i ON i.loan_id = l.loan_id
GROUP BY l.loan_id, u.user_id, a.account_id;

-- Overdue installments and how many days late they are.
CREATE OR REPLACE VIEW v_overdue_installments AS
SELECT i.loan_id,
       i.installment_no,
       l.customer_id,
       u.name                               AS customer_name,
       a.branch_id,
       i.due_date,
       i.principal_part + i.interest_part   AS emi,
       CURRENT_DATE - i.due_date            AS days_overdue
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


-- =====================================================================
-- PART 2: FUNCTION
-- =====================================================================

-- How much money has already left this account today (used for daily limit).
CREATE FUNCTION fn_spent_today(p_account_id INT) RETURNS DECIMAL(12,2)
LANGUAGE plpgsql STABLE
SET search_path = banking_system
AS $$
DECLARE
    v_total DECIMAL(12,2);
BEGIN
    SELECT COALESCE(SUM(amount), 0) INTO v_total
    FROM transactions
    WHERE source_account_id = p_account_id
      AND status = 'Success'
      AND created_at::date = CURRENT_DATE;
    RETURN v_total;
END;
$$;


-- =====================================================================
-- PART 3: TRIGGERS
-- In PostgreSQL a trigger calls a trigger FUNCTION, so each rule below is
-- a function (the code) plus a CREATE TRIGGER (when to run it).
-- =====================================================================

-- Rule: an account can be opened only if the customer's KYC is Approved,
-- and its daily limit cannot be more than its account type allows.
CREATE FUNCTION trg_accounts_before_insert() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = banking_system
AS $$
DECLARE
    v_kyc       VARCHAR(15);
    v_max_limit DECIMAL(12,2);
BEGIN
    SELECT kyc_status INTO v_kyc FROM customers WHERE user_id = NEW.customer_id;
    IF v_kyc IS NULL OR v_kyc <> 'Approved' THEN
        RAISE EXCEPTION 'KYC must be approved before opening an account';
    END IF;

    SELECT max_daily_limit INTO v_max_limit
    FROM account_types WHERE account_type_id = NEW.account_type_id;
    IF NEW.daily_limit > v_max_limit THEN
        RAISE EXCEPTION 'Daily limit is higher than this account type allows';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_accounts_before_insert
BEFORE INSERT ON accounts
FOR EACH ROW EXECUTE FUNCTION trg_accounts_before_insert();

-- Same daily limit rule when a customer changes their limit later.
CREATE FUNCTION trg_accounts_before_update() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = banking_system
AS $$
DECLARE
    v_max_limit DECIMAL(12,2);
BEGIN
    SELECT max_daily_limit INTO v_max_limit
    FROM account_types WHERE account_type_id = NEW.account_type_id;
    IF NEW.daily_limit > v_max_limit THEN
        RAISE EXCEPTION 'Daily limit is higher than this account type allows';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_accounts_before_update
BEFORE UPDATE ON accounts
FOR EACH ROW EXECUTE FUNCTION trg_accounts_before_update();

-- Audit: record every change of account status (Active / Frozen / Closed).
CREATE FUNCTION trg_accounts_after_update() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = banking_system
AS $$
BEGIN
    IF OLD.status <> NEW.status THEN
        INSERT INTO audit_logs (actor_user_id, action, table_name, record_id, old_value, new_value)
        VALUES (NULLIF(current_setting('app.user_id', true), '')::INT,
                'ACCOUNT_' || UPPER(NEW.status), 'accounts',
                NEW.account_id::TEXT, OLD.status, NEW.status);

        INSERT INTO notifications (user_id, category, message)
        VALUES (NEW.customer_id, 'Security',
                'Your account ' || NEW.account_id || ' is now ' || NEW.status);
    END IF;
    RETURN NULL;
END;
$$;
CREATE TRIGGER trg_accounts_after_update
AFTER UPDATE ON accounts
FOR EACH ROW EXECUTE FUNCTION trg_accounts_after_update();

-- When an employee reviews a KYC record:
--   1. copy the decision to customers.kyc_status
--   2. write the audit log
--   3. notify the customer
CREATE FUNCTION trg_kyc_after_update() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = banking_system
AS $$
BEGIN
    IF OLD.status <> NEW.status THEN
        IF NEW.status IN ('Approved', 'Rejected') THEN
            UPDATE customers SET kyc_status = NEW.status WHERE user_id = NEW.customer_id;
        END IF;

        INSERT INTO audit_logs (actor_user_id, action, table_name, record_id, old_value, new_value)
        VALUES (NEW.reviewed_by_employee_id, 'KYC_' || UPPER(NEW.status), 'customers',
                NEW.customer_id::TEXT, OLD.status, NEW.status);

        INSERT INTO notifications (user_id, category, message)
        VALUES (NEW.customer_id, 'KYC',
                'Your KYC is ' || NEW.status || COALESCE(': ' || NEW.remarks, ''));
    END IF;
    RETURN NULL;
END;
$$;
CREATE TRIGGER trg_kyc_after_update
AFTER UPDATE ON kyc_records
FOR EACH ROW EXECUTE FUNCTION trg_kyc_after_update();

-- Rule: the account linked to a loan must belong to the same customer.
CREATE FUNCTION trg_loans_before_insert() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = banking_system
AS $$
DECLARE
    v_owner INT;
BEGIN
    SELECT customer_id INTO v_owner FROM accounts WHERE account_id = NEW.linked_account_id;
    IF v_owner IS NULL OR v_owner <> NEW.customer_id THEN
        RAISE EXCEPTION 'A loan must be linked to your own account';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_loans_before_insert
BEFORE INSERT ON loans
FOR EACH ROW EXECUTE FUNCTION trg_loans_before_insert();

-- Audit + notify whenever a loan changes status.
CREATE FUNCTION trg_loans_after_update() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = banking_system
AS $$
BEGIN
    IF OLD.status <> NEW.status THEN
        INSERT INTO audit_logs (actor_user_id, action, table_name, record_id, old_value, new_value)
        VALUES (COALESCE(NULLIF(current_setting('app.user_id', true), '')::INT,
                         NEW.reviewed_by_employee_id),
                CASE NEW.status WHEN 'Active'   THEN 'LOAN_APPROVED'
                                WHEN 'Rejected' THEN 'LOAN_REJECTED'
                                ELSE                 'LOAN_CLOSED' END,
                'loans', NEW.loan_id::TEXT, OLD.status, NEW.status);

        INSERT INTO notifications (user_id, category, message)
        VALUES (NEW.customer_id, 'Loan',
                'Your loan ' || NEW.loan_id || ' is now ' || NEW.status);
    END IF;
    RETURN NULL;
END;
$$;
CREATE TRIGGER trg_loans_after_update
AFTER UPDATE ON loans
FOR EACH ROW EXECUTE FUNCTION trg_loans_after_update();

-- Audit whenever an employee approves or rejects a pending transaction.
CREATE FUNCTION trg_txn_after_update() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = banking_system
AS $$
BEGIN
    IF OLD.status <> NEW.status THEN
        INSERT INTO audit_logs (actor_user_id, action, table_name, record_id, old_value, new_value)
        VALUES (NEW.reviewed_by_employee_id, 'TXN_' || UPPER(NEW.status), 'transactions',
                NEW.transaction_id::TEXT, OLD.status, NEW.status);
    END IF;
    RETURN NULL;
END;
$$;
CREATE TRIGGER trg_txn_after_update
AFTER UPDATE ON transactions
FOR EACH ROW EXECUTE FUNCTION trg_txn_after_update();

-- Rule: transactions are history. They are never deleted
-- (mistakes are fixed with a reversal, see sp_reverse_transaction).
CREATE FUNCTION trg_txn_no_delete() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'Transactions cannot be deleted. Post a reversal instead.';
END;
$$;
CREATE TRIGGER trg_txn_no_delete
BEFORE DELETE ON transactions
FOR EACH ROW EXECUTE FUNCTION trg_txn_no_delete();

-- Rule: the audit log is append-only.
CREATE FUNCTION trg_audit_no_update() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'Audit log cannot be changed';
END;
$$;
CREATE TRIGGER trg_audit_no_update
BEFORE UPDATE ON audit_logs
FOR EACH ROW EXECUTE FUNCTION trg_audit_no_update();

CREATE FUNCTION trg_audit_no_delete() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'Audit log cannot be deleted';
END;
$$;
CREATE TRIGGER trg_audit_no_delete
BEFORE DELETE ON audit_logs
FOR EACH ROW EXECUTE FUNCTION trg_audit_no_delete();


-- =====================================================================
-- PART 4: STORED PROCEDURES
-- Every procedure that moves money follows the same pattern:
--   lock the rows with SELECT ... FOR UPDATE
--   check the rules (RAISE EXCEPTION if one fails)
--   update balances + insert the transaction row
-- A CALL runs as ONE database transaction: if ANY error is raised, PostgreSQL
-- rolls back everything the procedure did, so nothing is half done.
-- (MySQL needed START TRANSACTION / COMMIT and an EXIT HANDLER with ROLLBACK
--  for this; in PostgreSQL the statement itself is atomic.)
-- =====================================================================

-- Small helper: after money leaves an account, warn the owner if they
-- have gone over their monthly spending budget.
CREATE PROCEDURE sp_check_budget(p_account_id INT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = banking_system
AS $$
DECLARE
    v_owner     INT;
    v_remaining DECIMAL(12,2);
BEGIN
    SELECT customer_id, budget_remaining INTO v_owner, v_remaining
    FROM v_account_overview WHERE account_id = p_account_id;

    IF v_remaining IS NOT NULL AND v_remaining < 0 THEN
        INSERT INTO notifications (user_id, category, message)
        VALUES (v_owner, 'Budget',
                'Account ' || p_account_id || ' is over its monthly budget by Rs ' || -v_remaining);
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- 1. TRANSFER money from one account to another (instant, atomic).
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_transfer(
    p_user_id INT,              -- who is sending (must own the source account)
    p_from    INT,
    p_to      INT,
    p_amount  DECIMAL(12,2),
    p_key     VARCHAR(40))      -- idempotency key from the form
LANGUAGE plpgsql SECURITY DEFINER SET search_path = banking_system
AS $$
DECLARE
    v_amount      DECIMAL(12,2) := p_amount;
    v_owner       INT;
    v_balance     DECIMAL(12,2);
    v_from_status VARCHAR(10);
    v_to_owner    INT;
    v_to_status   VARCHAR(10);
    v_min_balance DECIMAL(12,2);
    v_daily_limit DECIMAL(12,2);
    v_txn_id      INT;
BEGIN
    IF v_amount IS NULL OR v_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be greater than zero';
    END IF;
    IF p_from = p_to THEN
        RAISE EXCEPTION 'Cannot transfer to the same account';
    END IF;

    -- Lock both rows, always the smaller account_id first.
    -- (If two transfers lock in opposite order they can deadlock.)
    PERFORM 1 FROM accounts WHERE account_id = LEAST(p_from, p_to)    FOR UPDATE;
    PERFORM 1 FROM accounts WHERE account_id = GREATEST(p_from, p_to) FOR UPDATE;

    -- Now read the details we need (rows are already locked).
    SELECT a.customer_id, a.balance, a.status, a.daily_limit, t.min_balance
      INTO v_owner, v_balance, v_from_status, v_daily_limit, v_min_balance
    FROM accounts a JOIN account_types t ON t.account_type_id = a.account_type_id
    WHERE a.account_id = p_from;

    SELECT customer_id, status INTO v_to_owner, v_to_status
    FROM accounts WHERE account_id = p_to;

    -- Validate
    IF v_owner IS NULL OR v_owner <> p_user_id THEN
        RAISE EXCEPTION 'You can only send money from your own account';
    END IF;
    IF v_to_owner IS NULL THEN
        RAISE EXCEPTION 'Destination account does not exist';
    END IF;
    IF v_from_status <> 'Active' OR v_to_status <> 'Active' THEN
        RAISE EXCEPTION 'Both accounts must be Active';
    END IF;
    IF v_balance - v_amount < v_min_balance THEN
        RAISE EXCEPTION 'Insufficient balance (minimum balance must be kept)';
    END IF;
    IF fn_spent_today(p_from) + v_amount > v_daily_limit THEN
        RAISE EXCEPTION 'Daily limit exceeded';
    END IF;

    -- Move the money
    UPDATE accounts SET balance = balance - v_amount WHERE account_id = p_from;
    UPDATE accounts SET balance = balance + v_amount WHERE account_id = p_to;

    -- Record it (a repeated idempotency_key fails here because it is UNIQUE)
    INSERT INTO transactions (source_account_id, destination_account_id, initiated_by_user_id,
                              type, amount, status, idempotency_key)
    VALUES (p_from, p_to, p_user_id, 'Transfer', v_amount, 'Success', p_key)
    RETURNING transaction_id INTO v_txn_id;

    INSERT INTO notifications (user_id, category, message, transaction_id) VALUES
        (v_owner,    'Transaction', 'Rs ' || v_amount || ' sent from account ' || p_from || ' to ' || p_to, v_txn_id),
        (v_to_owner, 'Transaction', 'Rs ' || v_amount || ' received in account ' || p_to, v_txn_id);

    CALL sp_check_budget(p_from);
END;
$$;

-- ---------------------------------------------------------------------
-- 2. REVIEW a pending deposit / withdrawal (employee approves or rejects).
--    Only an approved request changes the balance.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_review_transaction(
    p_employee_id INT,
    p_txn_id      INT,
    p_decision    VARCHAR(10))      -- 'Approve' or 'Reject'
LANGUAGE plpgsql SECURITY DEFINER SET search_path = banking_system
AS $$
DECLARE
    v_type        VARCHAR(10);
    v_amount      DECIMAL(12,2);
    v_status      VARCHAR(10);
    v_account     INT;
    v_owner       INT;
    v_balance     DECIMAL(12,2);
    v_acc_status  VARCHAR(10);
    v_min_balance DECIMAL(12,2);
    v_daily_limit DECIMAL(12,2);
    v_branch      INT;    -- the employee's branch
    v_acc_branch  INT;    -- the account's branch
BEGIN
    SELECT branch_id INTO v_branch FROM employees WHERE user_id = p_employee_id;
    IF v_branch IS NULL THEN
        RAISE EXCEPTION 'Only an employee can review transactions';
    END IF;

    -- Lock the transaction row
    SELECT type, amount, status, COALESCE(source_account_id, destination_account_id)
      INTO v_type, v_amount, v_status, v_account
    FROM transactions WHERE transaction_id = p_txn_id FOR UPDATE;

    IF v_status IS NULL OR v_status <> 'Pending' THEN
        RAISE EXCEPTION 'This transaction is not pending';
    END IF;

    -- Lock the account row
    SELECT a.customer_id, a.balance, a.status, a.daily_limit, t.min_balance, a.branch_id
      INTO v_owner, v_balance, v_acc_status, v_daily_limit, v_min_balance, v_acc_branch
    FROM accounts a JOIN account_types t ON t.account_type_id = a.account_type_id
    WHERE a.account_id = v_account FOR UPDATE OF a;

    -- Staff can only act on accounts of their own branch
    IF v_acc_branch <> v_branch THEN
        RAISE EXCEPTION 'This account belongs to another branch';
    END IF;

    IF p_decision = 'Reject' THEN
        UPDATE transactions
           SET status = 'Rejected', reviewed_by_employee_id = p_employee_id, branch_id = v_branch
         WHERE transaction_id = p_txn_id;
    ELSE
        IF v_acc_status <> 'Active' THEN
            RAISE EXCEPTION 'Account is not Active';
        END IF;

        IF v_type = 'Withdrawal' THEN
            IF v_balance - v_amount < v_min_balance THEN
                RAISE EXCEPTION 'Insufficient balance (minimum balance must be kept)';
            END IF;
            IF fn_spent_today(v_account) + v_amount > v_daily_limit THEN
                RAISE EXCEPTION 'Daily limit exceeded';
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
            'Your ' || LOWER(v_type) || ' of Rs ' || v_amount || ' was ' ||
            CASE WHEN p_decision = 'Reject' THEN 'rejected' ELSE 'approved' END,
            p_txn_id);

    IF p_decision <> 'Reject' AND v_type = 'Withdrawal' THEN
        CALL sp_check_budget(v_account);
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- 3. REVERSE a mistaken transaction.
--    Nothing is deleted. A new row is posted that moves the same amount
--    the opposite way (source and destination swapped).
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_reverse_transaction(
    p_employee_id INT,
    p_txn_id      INT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = banking_system
AS $$
DECLARE
    v_type     VARCHAR(10);
    v_amount   DECIMAL(12,2);
    v_status   VARCHAR(10);
    v_src      INT;
    v_dst      INT;
    v_is_rev   INT;
    v_balance  DECIMAL(12,2);
    v_branch   INT;
    v_new_type VARCHAR(10);
    v_new_id   INT;
BEGIN
    SELECT branch_id INTO v_branch FROM employees WHERE user_id = p_employee_id;
    IF v_branch IS NULL THEN
        RAISE EXCEPTION 'Only an employee can reverse transactions';
    END IF;

    SELECT type, amount, status, source_account_id, destination_account_id, reversal_of_transaction_id
      INTO v_type, v_amount, v_status, v_src, v_dst, v_is_rev
    FROM transactions WHERE transaction_id = p_txn_id FOR UPDATE;

    IF v_status IS NULL OR v_status <> 'Success' THEN
        RAISE EXCEPTION 'Only a successful transaction can be reversed';
    END IF;
    IF v_is_rev IS NOT NULL THEN
        RAISE EXCEPTION 'A reversal cannot be reversed again';
    END IF;
    IF EXISTS (SELECT 1 FROM transactions WHERE reversal_of_transaction_id = p_txn_id) THEN
        RAISE EXCEPTION 'This transaction is already reversed';
    END IF;
    -- At least one of the two accounts must be in the employee's branch
    IF NOT EXISTS (SELECT 1 FROM accounts
                   WHERE branch_id = v_branch AND account_id IN (v_src, v_dst)) THEN
        RAISE EXCEPTION 'This transaction belongs to another branch';
    END IF;

    -- Swap the direction: money goes back from the old destination to the old source.
    v_new_type := CASE v_type WHEN 'Deposit'    THEN 'Withdrawal'
                              WHEN 'Withdrawal' THEN 'Deposit'
                              ELSE                   'Transfer' END;

    -- Take the money back from the account that received it
    IF v_dst IS NOT NULL THEN
        SELECT balance INTO v_balance FROM accounts WHERE account_id = v_dst FOR UPDATE;
        IF v_balance < v_amount THEN
            RAISE EXCEPTION 'Not enough balance to reverse this transaction';
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
            v_new_type, v_amount, 'Success', 'REV-' || p_txn_id)
    RETURNING transaction_id INTO v_new_id;

    INSERT INTO audit_logs (actor_user_id, action, table_name, record_id, old_value, new_value)
    VALUES (p_employee_id, 'TXN_REVERSED', 'transactions', p_txn_id::TEXT, 'Success',
            'reversed by ' || v_new_id);
END;
$$;

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
    p_employee_id INT,
    p_loan_id     INT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = banking_system
AS $$
DECLARE
    v_status     VARCHAR(10);
    v_principal  DECIMAL(12,2);
    v_rate       DECIMAL(4,2);
    v_tenure     INT;
    v_account    INT;
    v_acc_status VARCHAR(10);
    v_branch     INT;    -- the employee's branch
    v_acc_branch INT;    -- the linked account's branch
    v_txn_id     INT;
    v_i          INT := 1;
    v_remaining  DECIMAL(12,2);
    v_part       DECIMAL(10,2);
BEGIN
    SELECT branch_id INTO v_branch FROM employees WHERE user_id = p_employee_id;
    IF v_branch IS NULL THEN
        RAISE EXCEPTION 'Only an employee can approve loans';
    END IF;

    SELECT status, principal, interest_rate, tenure_months, linked_account_id
      INTO v_status, v_principal, v_rate, v_tenure, v_account
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;

    IF v_status IS NULL OR v_status <> 'Requested' THEN
        RAISE EXCEPTION 'This loan is not waiting for approval';
    END IF;

    SELECT status, branch_id INTO v_acc_status, v_acc_branch
    FROM accounts WHERE account_id = v_account FOR UPDATE;
    IF v_acc_branch <> v_branch THEN
        RAISE EXCEPTION 'This loan belongs to another branch';
    END IF;
    IF v_acc_status <> 'Active' THEN
        RAISE EXCEPTION 'Linked account is not Active';
    END IF;

    -- a) pay out the loan
    UPDATE accounts SET balance = balance + v_principal WHERE account_id = v_account;

    INSERT INTO transactions (destination_account_id, branch_id, initiated_by_user_id,
                              reviewed_by_employee_id, type, amount, status, idempotency_key)
    VALUES (v_account, v_branch, p_employee_id, p_employee_id,
            'Deposit', v_principal, 'Success', 'LOAN-' || p_loan_id)
    RETURNING transaction_id INTO v_txn_id;

    -- b) create the repayment schedule
    v_remaining := v_principal;
    v_part      := ROUND(v_principal / v_tenure, 2);

    WHILE v_i <= v_tenure LOOP
        IF v_i = v_tenure THEN
            v_part := v_remaining;     -- last month takes any rounding difference
        END IF;

        INSERT INTO loan_installments (loan_id, installment_no, due_date, principal_part, interest_part)
        VALUES (p_loan_id, v_i,
                (CURRENT_DATE + make_interval(months => v_i))::DATE,
                v_part,
                ROUND(v_remaining * v_rate / 12 / 100, 2));

        v_remaining := v_remaining - v_part;
        v_i := v_i + 1;
    END LOOP;

    -- c) activate the loan (trigger writes the audit log + notification)
    UPDATE loans
       SET status = 'Active', reviewed_by_employee_id = p_employee_id,
           disbursement_transaction_id = v_txn_id
     WHERE loan_id = p_loan_id;
END;
$$;

-- ---------------------------------------------------------------------
-- 5. PAY one installment (EMI) from the loan's linked account.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_pay_installment(
    p_user_id        INT,
    p_loan_id        INT,
    p_installment_no INT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = banking_system
AS $$
DECLARE
    v_owner       INT;
    v_loan_status VARCHAR(10);
    v_account     INT;
    v_inst_status VARCHAR(10);
    v_emi         DECIMAL(12,2);
    v_balance     DECIMAL(12,2);
    v_min_balance DECIMAL(12,2);
    v_acc_status  VARCHAR(10);
    v_txn_id      INT;
BEGIN
    SELECT customer_id, status, linked_account_id INTO v_owner, v_loan_status, v_account
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;

    IF v_owner IS NULL OR v_owner <> p_user_id THEN
        RAISE EXCEPTION 'Loan not found';
    END IF;
    IF v_loan_status <> 'Active' THEN
        RAISE EXCEPTION 'Loan is not active';
    END IF;

    SELECT status, principal_part + interest_part INTO v_inst_status, v_emi
    FROM loan_installments
    WHERE loan_id = p_loan_id AND installment_no = p_installment_no FOR UPDATE;

    IF v_inst_status IS NULL THEN
        RAISE EXCEPTION 'Installment not found';
    END IF;
    IF v_inst_status = 'Paid' THEN
        RAISE EXCEPTION 'Installment is already paid';
    END IF;

    SELECT a.balance, a.status, t.min_balance INTO v_balance, v_acc_status, v_min_balance
    FROM accounts a JOIN account_types t ON t.account_type_id = a.account_type_id
    WHERE a.account_id = v_account FOR UPDATE OF a;

    IF v_acc_status <> 'Active' THEN
        RAISE EXCEPTION 'Linked account is not Active';
    END IF;
    IF v_balance - v_emi < v_min_balance THEN
        RAISE EXCEPTION 'Insufficient balance to pay this installment';
    END IF;

    UPDATE accounts SET balance = balance - v_emi WHERE account_id = v_account;

    INSERT INTO transactions (source_account_id, initiated_by_user_id, type, amount, status, idempotency_key)
    VALUES (v_account, p_user_id, 'Withdrawal', v_emi, 'Success',
            'EMI-' || p_loan_id || '-' || p_installment_no)
    RETURNING transaction_id INTO v_txn_id;

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
            'Installment ' || p_installment_no || ' of loan ' || p_loan_id || ' paid: Rs ' || v_emi, v_txn_id);
END;
$$;

-- ---------------------------------------------------------------------
-- 6. REPAY THE WHOLE LOAN at once.
--    Same as paying every remaining installment today: each unpaid
--    installment gets its own Withdrawal transaction (oldest first),
--    then the loan is Closed. All in ONE database transaction, so either
--    every installment is paid or none is.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_repay_loan(
    p_user_id INT,
    p_loan_id INT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = banking_system
AS $$
DECLARE
    v_owner       INT;
    v_loan_status VARCHAR(10);
    v_account     INT;
    v_total       DECIMAL(12,2);
    v_balance     DECIMAL(12,2);
    v_min_balance DECIMAL(12,2);
    v_acc_status  VARCHAR(10);
    v_no          INT;
    v_emi         DECIMAL(12,2);
    v_txn_id      INT;
BEGIN
    SELECT customer_id, status, linked_account_id INTO v_owner, v_loan_status, v_account
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;

    IF v_owner IS NULL OR v_owner <> p_user_id THEN
        RAISE EXCEPTION 'Loan not found';
    END IF;
    IF v_loan_status <> 'Active' THEN
        RAISE EXCEPTION 'Loan is not active';
    END IF;

    -- Lock the unpaid installments, then add them up
    PERFORM 1 FROM loan_installments
    WHERE loan_id = p_loan_id AND status <> 'Paid' FOR UPDATE;

    SELECT SUM(principal_part + interest_part) INTO v_total
    FROM loan_installments
    WHERE loan_id = p_loan_id AND status <> 'Paid';

    SELECT a.balance, a.status, t.min_balance INTO v_balance, v_acc_status, v_min_balance
    FROM accounts a JOIN account_types t ON t.account_type_id = a.account_type_id
    WHERE a.account_id = v_account FOR UPDATE OF a;

    IF v_acc_status <> 'Active' THEN
        RAISE EXCEPTION 'Linked account is not Active';
    END IF;
    IF v_balance - v_total < v_min_balance THEN
        RAISE EXCEPTION 'Insufficient balance to repay the whole loan';
    END IF;

    -- Pay the unpaid installments one by one, oldest first
    SELECT MIN(installment_no) INTO v_no
    FROM loan_installments WHERE loan_id = p_loan_id AND status <> 'Paid';

    WHILE v_no IS NOT NULL LOOP
        SELECT principal_part + interest_part INTO v_emi
        FROM loan_installments WHERE loan_id = p_loan_id AND installment_no = v_no;

        UPDATE accounts SET balance = balance - v_emi WHERE account_id = v_account;

        INSERT INTO transactions (source_account_id, initiated_by_user_id, type, amount, status, idempotency_key)
        VALUES (v_account, p_user_id, 'Withdrawal', v_emi, 'Success',
                'EMI-' || p_loan_id || '-' || v_no)
        RETURNING transaction_id INTO v_txn_id;

        UPDATE loan_installments
           SET status = 'Paid', payment_transaction_id = v_txn_id
         WHERE loan_id = p_loan_id AND installment_no = v_no;

        -- next unpaid installment (MIN returns NULL when none are left, ending the loop)
        SELECT MIN(installment_no) INTO v_no
        FROM loan_installments WHERE loan_id = p_loan_id AND status <> 'Paid';
    END LOOP;

    UPDATE loans SET status = 'Closed' WHERE loan_id = p_loan_id;

    INSERT INTO notifications (user_id, category, message)
    VALUES (p_user_id, 'Loan', 'Loan ' || p_loan_id || ' fully repaid: Rs ' || v_total);
END;
$$;

-- ---------------------------------------------------------------------
-- 7. MARK OVERDUE installments (run daily by the scheduled job below,
--    or by an employee from the website).
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_mark_overdue()
LANGUAGE plpgsql SECURITY DEFINER SET search_path = banking_system
AS $$
BEGIN
    -- Notify first (while the rows are still 'Pending' so we can find them)
    INSERT INTO notifications (user_id, category, message)
    SELECT l.customer_id, 'Loan',
           'Installment ' || i.installment_no || ' of loan ' || i.loan_id ||
           ' was due on ' || i.due_date || ' and is now overdue'
    FROM loan_installments i
    JOIN loans l ON l.loan_id = i.loan_id
    WHERE i.status = 'Pending' AND i.due_date < CURRENT_DATE;

    UPDATE loan_installments
       SET status = 'Overdue'
     WHERE status = 'Pending' AND due_date < CURRENT_DATE;
END;
$$;

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
LANGUAGE plpgsql SECURITY DEFINER SET search_path = banking_system
AS $$
DECLARE
    v_role   VARCHAR(20);
    v_branch INT;
BEGIN
    SELECT u.role, e.branch_id INTO v_role, v_branch
    FROM users u JOIN employees e ON e.user_id = u.user_id
    WHERE u.user_id = p_manager_id;

    IF v_role IS NULL OR v_role <> 'BranchManager' THEN
        RAISE EXCEPTION 'Only a branch manager can add employees';
    END IF;

    INSERT INTO users (name, email, phone, password_hash, role)
    VALUES (p_name, p_email, p_phone, p_password_hash, 'Employee')
    RETURNING user_id INTO p_new_user_id;

    INSERT INTO employees (user_id, branch_id, designation, manager_employee_id)
    VALUES (p_new_user_id, v_branch, p_designation, p_manager_id);

    INSERT INTO audit_logs (actor_user_id, action, table_name, record_id, old_value, new_value)
    VALUES (p_manager_id, 'EMPLOYEE_ADDED', 'employees', p_new_user_id::TEXT, NULL,
            p_designation || ' at branch ' || v_branch);
END;
$$;


-- =====================================================================
-- PART 5: SCHEDULED JOB - run the overdue check automatically once a day
-- PostgreSQL has no built-in event scheduler; the pg_cron extension
-- (available on Aiven and most hosted PostgreSQL) does the same job as
-- MySQL's CREATE EVENT. If pg_cron is not available, this part is skipped
-- with a notice and the website's "Run overdue check" button still works.
-- =====================================================================
DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule('ev_mark_overdue_daily', '5 0 * * *',
                          'CALL banking_system.sp_mark_overdue()');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron not available, daily overdue job not scheduled: %', SQLERRM;
END;
$$;
