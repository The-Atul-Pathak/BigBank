-- =====================================================================
-- Banking System: login lookup and role-based views (MySQL 8.0.16+)
-- Run AFTER banking_procedures.sql.
--
-- How access levels work:
--   1. The application verifies email + password (bcrypt/argon2 hash check
--      happens in the app, never in SQL) and then keeps the user_id in the
--      server-side session.
--   2. Every call below receives that user_id as its FIRST argument.
--   3. Each procedure decides what that user may see, so a customer can only
--      read their own rows and each employee sees what their designation allows.
--
-- Roles:  CUSTOMER  -> sp_my_* procedures (own data only)
--         EMPLOYEE  -> sp_staff_* procedures (by designation and branch)
--         ADMIN     -> sp_admin_* procedures (audit trail)
-- =====================================================================

USE banking_system;

DROP FUNCTION  IF EXISTS fn_is_admin;
DROP PROCEDURE IF EXISTS sp_get_login_info;
DROP PROCEDURE IF EXISTS sp_my_accounts;
DROP PROCEDURE IF EXISTS sp_my_loans;
DROP PROCEDURE IF EXISTS sp_my_installments;
DROP PROCEDURE IF EXISTS sp_my_beneficiaries;
DROP PROCEDURE IF EXISTS sp_my_notifications;
DROP PROCEDURE IF EXISTS sp_mark_notification_read;
DROP PROCEDURE IF EXISTS sp_staff_branch_accounts;
DROP PROCEDURE IF EXISTS sp_staff_pending_work;
DROP PROCEDURE IF EXISTS sp_admin_audit_logs;

DELIMITER $$

CREATE FUNCTION fn_is_admin(p_user_id INT) RETURNS TINYINT(1)
READS SQL DATA
BEGIN
    RETURN EXISTS (SELECT 1 FROM users
                    WHERE user_id = p_user_id AND role = 'ADMIN' AND status = 'ACTIVE');
END$$

-- ---------------------------------------------------------------------
-- LOGIN: returns what the application needs to authenticate a user and to
-- decide which screens to show. The app compares the password with
-- password_hash itself and must refuse any status other than ACTIVE.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_get_login_info(IN p_email VARCHAR(150))
BEGIN
    SELECT u.user_id, u.email, u.password_hash, u.role, u.status,
           c.customer_id, e.employee_id, e.designation, e.branch_id
      FROM users u
      LEFT JOIN customers c ON c.user_id = u.user_id
      LEFT JOIN employees e ON e.user_id = u.user_id
     WHERE u.email = p_email;
END$$

-- =====================================================================
-- CUSTOMER LEVEL: a customer sees only their own data
-- =====================================================================

CREATE PROCEDURE sp_my_accounts(IN p_user_id INT)
BEGIN
    DECLARE v_customer INT;

    IF NOT fn_is_active_user(p_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User is not active';
    END IF;
    SET v_customer = fn_customer_id_of_user(p_user_id);
    IF v_customer IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only customers can view this';
    END IF;

    SELECT a.account_id, a.account_number, t.type_name, b.branch_name,
           a.current_balance, a.status, a.opened_at
      FROM accounts a
      JOIN account_types t ON t.account_type_id = a.account_type_id
      JOIN branches b      ON b.branch_id = a.branch_id
     WHERE a.customer_id = v_customer
     ORDER BY a.account_id;
END$$

CREATE PROCEDURE sp_my_loans(IN p_user_id INT)
BEGIN
    DECLARE v_customer INT;

    IF NOT fn_is_active_user(p_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User is not active';
    END IF;
    SET v_customer = fn_customer_id_of_user(p_user_id);
    IF v_customer IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only customers can view this';
    END IF;

    SELECT l.loan_id, l.requested_amount, l.approved_amount, l.annual_interest_rate,
           l.tenure_months, l.status, l.applied_at,
           (SELECT MIN(i.due_date) FROM loan_installments i
             WHERE i.loan_id = l.loan_id AND i.status <> 'PAID') AS next_due_date
      FROM loans l
     WHERE l.customer_id = v_customer
     ORDER BY l.loan_id;
END$$

CREATE PROCEDURE sp_my_installments(IN p_user_id INT, IN p_loan_id INT)
BEGIN
    DECLARE v_customer INT;
    DECLARE v_owner    INT;

    IF NOT fn_is_active_user(p_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User is not active';
    END IF;
    SET v_customer = fn_customer_id_of_user(p_user_id);
    IF v_customer IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only customers can view this';
    END IF;

    SELECT customer_id INTO v_owner FROM loans WHERE loan_id = p_loan_id;
    IF v_owner IS NULL OR v_owner <> v_customer THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Loan not found';
    END IF;

    SELECT installment_id, installment_number, due_date, principal_due, interest_due,
           principal_due + interest_due AS emi, status, paid_at
      FROM loan_installments
     WHERE loan_id = p_loan_id
     ORDER BY installment_number;
END$$

CREATE PROCEDURE sp_my_beneficiaries(IN p_user_id INT)
BEGIN
    DECLARE v_customer INT;

    IF NOT fn_is_active_user(p_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User is not active';
    END IF;
    SET v_customer = fn_customer_id_of_user(p_user_id);
    IF v_customer IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only customers can view this';
    END IF;

    SELECT b.beneficiary_id, b.beneficiary_name, b.nickname, b.relationship_type,
           CONCAT('XXXXXXXX', RIGHT(a.account_number, 4)) AS account_masked,
           b.status, b.daily_transfer_limit
      FROM beneficiaries b
      JOIN accounts a ON a.account_id = b.beneficiary_account_id
     WHERE b.customer_id = v_customer
     ORDER BY b.beneficiary_id;
END$$

-- Any logged-in user (customer or employee) can read their own notifications
CREATE PROCEDURE sp_my_notifications(IN p_user_id INT, IN p_unread_only TINYINT)
BEGIN
    IF NOT fn_is_active_user(p_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User is not active';
    END IF;

    SELECT notification_id, notification_type, message, is_read, created_at
      FROM notifications
     WHERE user_id = p_user_id
       AND (p_unread_only = 0 OR is_read = FALSE)
     ORDER BY created_at DESC, notification_id DESC
     LIMIT 50;
END$$

CREATE PROCEDURE sp_mark_notification_read(IN p_user_id INT, IN p_notification_id BIGINT)
BEGIN
    DECLARE v_found INT DEFAULT 0;

    IF NOT fn_is_active_user(p_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User is not active';
    END IF;

    SELECT COUNT(*) INTO v_found FROM notifications
     WHERE notification_id = p_notification_id AND user_id = p_user_id;
    IF v_found = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Notification not found';
    END IF;

    UPDATE notifications SET is_read = TRUE
     WHERE notification_id = p_notification_id AND user_id = p_user_id;
END$$

-- =====================================================================
-- EMPLOYEE LEVEL: what staff see depends on designation and branch
-- =====================================================================

-- Regional Managers see every branch; all other staff see only their own branch
CREATE PROCEDURE sp_staff_branch_accounts(IN p_employee_user_id INT)
BEGIN
    DECLARE v_emp         INT;
    DECLARE v_branch      INT;
    DECLARE v_designation VARCHAR(80);

    SET v_emp = fn_employee_id(p_employee_user_id);
    IF v_emp IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only an active employee can view this';
    END IF;

    SELECT branch_id, designation INTO v_branch, v_designation
      FROM employees WHERE employee_id = v_emp;

    SELECT a.account_id, a.account_number, c.full_name, t.type_name,
           a.current_balance, a.status, a.branch_id
      FROM accounts a
      JOIN customers c     ON c.customer_id = a.customer_id
      JOIN account_types t ON t.account_type_id = a.account_type_id
     WHERE v_designation = 'Regional Manager' OR a.branch_id = v_branch
     ORDER BY a.branch_id, a.account_id;
END$$

-- Work queue: each employee gets only the queues their designation covers.
-- (Each queue is a separate result set.)
CREATE PROCEDURE sp_staff_pending_work(IN p_employee_user_id INT)
BEGIN
    IF NOT fn_is_active_employee(p_employee_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only an active employee can view this';
    END IF;

    -- KYC staff: pending KYC documents
    IF fn_is_kyc_staff(p_employee_user_id) THEN
        SELECT k.kyc_id, c.full_name, k.document_type, k.masked_document_reference, k.submitted_at
          FROM kyc_records k JOIN customers c ON c.customer_id = k.customer_id
         WHERE k.status = 'PENDING'
         ORDER BY k.submitted_at;
    END IF;

    -- Loan staff: applications waiting for a decision, and approved loans waiting for disbursement
    IF fn_is_loan_staff(p_employee_user_id) THEN
        SELECT l.loan_id, c.full_name, l.requested_amount, l.approved_amount,
               l.tenure_months, l.status, l.applied_at
          FROM loans l JOIN customers c ON c.customer_id = l.customer_id
         WHERE l.status IN ('PENDING', 'APPROVED')
         ORDER BY l.applied_at;
    END IF;

    -- Every employee: beneficiaries waiting for approval
    SELECT b.beneficiary_id, c.full_name AS added_by, b.beneficiary_name, b.relationship_type, b.added_at
      FROM beneficiaries b JOIN customers c ON c.customer_id = b.customer_id
     WHERE b.status = 'PENDING'
     ORDER BY b.added_at;
END$$

-- =====================================================================
-- ADMIN LEVEL
-- =====================================================================

CREATE PROCEDURE sp_admin_audit_logs(IN p_admin_user_id INT, IN p_limit INT)
BEGIN
    IF NOT fn_is_admin(p_admin_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only an administrator can view the audit log';
    END IF;
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 500 THEN
        SET p_limit = 50;
    END IF;

    SELECT a.audit_id, a.created_at, u.email AS actor, a.action, a.entity_type, a.entity_id, a.reason
      FROM audit_logs a
      LEFT JOIN users u ON u.user_id = a.actor_user_id
     ORDER BY a.audit_id DESC
     LIMIT p_limit;
END$$

DELIMITER ;

-- =====================================================================
-- OPTIONAL: database account for the application (run as root/admin).
-- The app connects as ONE MySQL user that may only run the procedures below.
-- It has no SELECT/INSERT/UPDATE on any table, so it cannot bypass the rules.
-- (Procedures run with their definer's rights, so they still reach the tables.)
-- Change the password before using this anywhere real.
-- =====================================================================
-- CREATE USER IF NOT EXISTS 'bank_app'@'localhost' IDENTIFIED BY 'Change_Me_123!';
--
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_get_login_info        TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_deposit               TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_withdraw              TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_transfer              TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_reverse_transaction   TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_apply_loan            TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_approve_loan          TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_reject_loan           TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_disburse_loan         TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_pay_installment       TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_open_account          TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_review_kyc            TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_add_beneficiary       TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_approve_beneficiary   TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_get_account_statement TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_my_accounts           TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_my_loans              TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_my_installments       TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_my_beneficiaries      TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_my_notifications      TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_mark_notification_read TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_staff_branch_accounts TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_staff_pending_work    TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_admin_audit_logs      TO 'bank_app'@'localhost';
-- GRANT EXECUTE ON PROCEDURE banking_system.sp_reconcile_balances    TO 'bank_app'@'localhost';
-- (The sp_internal_* helpers and fn_* functions are NOT granted: users cannot call them directly.)

-- =====================================================================
-- DEMO: simulate three logins by passing their user_id
-- =====================================================================
--
-- -- Login lookup (the app would now check the password hash)
-- CALL sp_get_login_info('aarav.mehta@example.com');     -- role CUSTOMER, customer_id 1
-- CALL sp_get_login_info('priya.nair@samplebank.in');    -- role EMPLOYEE, Branch Manager, branch 2
-- CALL sp_get_login_info('admin@samplebank.in');         -- role ADMIN
--
-- -- CUSTOMER view: Aarav (user 8) sees only his accounts 1 and 11
-- CALL sp_my_accounts(8);
-- CALL sp_my_beneficiaries(8);
-- CALL sp_my_notifications(8, 1);                        -- unread only
-- -- An employee cannot use the customer view.      EXPECTED ERROR: Only customers can view this
-- CALL sp_my_accounts(3);
-- -- Aarav asking for someone else's loan.           EXPECTED ERROR: Loan not found
-- CALL sp_my_installments(8, 2);
--
-- -- EMPLOYEE view: Branch Manager (user 3, Mumbai) sees branch 2 only: accounts 2, 8, 12
-- CALL sp_staff_branch_accounts(3);
-- -- Regional Manager (user 2) sees all 12 accounts
-- CALL sp_staff_branch_accounts(2);
-- -- A customer cannot use the staff view.           EXPECTED ERROR: Only an active employee can view this
-- CALL sp_staff_branch_accounts(8);
-- -- Work queues by designation: KYC Officer (5) gets KYC + beneficiaries,
-- -- Loan Officer (6) gets loans + beneficiaries, Branch Manager (3) gets all three
-- CALL sp_staff_pending_work(5);
-- CALL sp_staff_pending_work(6);
-- CALL sp_staff_pending_work(3);
--
-- -- ADMIN view
-- CALL sp_admin_audit_logs(1, 10);
-- -- A manager is not an admin.                      EXPECTED ERROR: Only an administrator can view the audit log
-- CALL sp_admin_audit_logs(3, 10);
