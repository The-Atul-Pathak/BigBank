-- =====================================================================
-- BigBank - Banking Management System
-- File 4 of 4: ACCESS CONTROL (DCL - GRANT / REVOKE)
--
-- Run as root (or another admin) AFTER the other three files.
--
-- Part A: one MySQL role per job, each with only the access it needs.
-- Part B: demo MySQL logins, one per role, to show the roles working.
-- Part C: a REVOKE example.
-- Part D: the account the website itself connects with.
-- =====================================================================

USE banking_system;

-- Clean re-run support
DROP USER IF EXISTS 'rahul_db'@'localhost', 'meera_db'@'localhost',
                    'arjun_db'@'localhost', 'kiran_db'@'localhost',
                    'bigbank_app'@'localhost';
DROP ROLE IF EXISTS 'customer_role', 'employee_role', 'manager_role', 'auditor_role';

-- =====================================================================
-- PART A: ROLES
-- =====================================================================
CREATE ROLE 'customer_role', 'employee_role', 'manager_role', 'auditor_role';

-- ---------- Customer: reads through views, moves money through procedures
GRANT SELECT ON banking_system.v_account_overview TO 'customer_role';
GRANT SELECT ON banking_system.v_loan_summary     TO 'customer_role';
GRANT INSERT ON banking_system.kyc_records        TO 'customer_role';   -- submit KYC
GRANT INSERT ON banking_system.loans              TO 'customer_role';   -- apply for a loan
GRANT INSERT ON banking_system.transactions       TO 'customer_role';   -- request deposit / withdrawal
GRANT EXECUTE ON PROCEDURE banking_system.sp_transfer        TO 'customer_role';
GRANT EXECUTE ON PROCEDURE banking_system.sp_pay_installment TO 'customer_role';
GRANT EXECUTE ON PROCEDURE banking_system.sp_repay_loan      TO 'customer_role';

-- ---------- Employee: reads banking data, reviews things
GRANT SELECT ON banking_system.users                  TO 'employee_role';
GRANT SELECT ON banking_system.customers              TO 'employee_role';
GRANT SELECT ON banking_system.kyc_records            TO 'employee_role';
GRANT SELECT ON banking_system.accounts               TO 'employee_role';
GRANT SELECT ON banking_system.transactions           TO 'employee_role';
GRANT SELECT ON banking_system.loans                  TO 'employee_role';
GRANT SELECT ON banking_system.loan_installments      TO 'employee_role';
GRANT SELECT ON banking_system.v_account_overview     TO 'employee_role';
GRANT SELECT ON banking_system.v_loan_summary         TO 'employee_role';
GRANT SELECT ON banking_system.v_overdue_installments TO 'employee_role';

-- Column-level privileges: an employee may change ONLY these columns.
-- (e.g. they can freeze an account, but can never edit its balance)
GRANT UPDATE (status, reviewed_by_employee_id, remarks) ON banking_system.kyc_records TO 'employee_role';
GRANT UPDATE (status)                                   ON banking_system.accounts    TO 'employee_role';
GRANT UPDATE (status, reviewed_by_employee_id)          ON banking_system.loans       TO 'employee_role';

GRANT EXECUTE ON PROCEDURE banking_system.sp_review_transaction  TO 'employee_role';
GRANT EXECUTE ON PROCEDURE banking_system.sp_reverse_transaction TO 'employee_role';
GRANT EXECUTE ON PROCEDURE banking_system.sp_approve_loan        TO 'employee_role';
GRANT EXECUTE ON PROCEDURE banking_system.sp_mark_overdue        TO 'employee_role';

-- ---------- Branch manager: everything an employee has, plus branch summaries
GRANT 'employee_role' TO 'manager_role';                 -- a role inside a role
GRANT SELECT ON banking_system.v_branch_summary TO 'manager_role';
GRANT EXECUTE ON PROCEDURE banking_system.sp_add_employee TO 'manager_role';   -- onboard staff

-- ---------- Auditor: can only READ the audit log
GRANT SELECT ON banking_system.audit_logs TO 'auditor_role';

-- Note: nobody gets UPDATE or DELETE on audit_logs. Even if someone did,
-- the triggers trg_audit_no_update / trg_audit_no_delete would block it.

-- =====================================================================
-- PART B: DEMO LOGINS (one per role)
-- =====================================================================
CREATE USER 'rahul_db'@'localhost' IDENTIFIED BY 'password123' DEFAULT ROLE 'customer_role';
CREATE USER 'meera_db'@'localhost' IDENTIFIED BY 'password123' DEFAULT ROLE 'employee_role';
CREATE USER 'arjun_db'@'localhost' IDENTIFIED BY 'password123' DEFAULT ROLE 'manager_role';
CREATE USER 'kiran_db'@'localhost' IDENTIFIED BY 'password123' DEFAULT ROLE 'auditor_role';

-- Try it:
--   mysql -u kiran_db -p banking_system
--   SELECT * FROM audit_logs;      -- works
--   SELECT * FROM accounts;        -- ERROR: SELECT command denied
--   DELETE FROM audit_logs;        -- ERROR: DELETE command denied
--
-- See what a user can do:
--   SHOW GRANTS FOR 'kiran_db'@'localhost' USING 'auditor_role';

-- =====================================================================
-- PART C: REVOKE example
-- The auditor is given temporary read access to accounts for an
-- investigation, and it is taken back afterwards.
-- =====================================================================
GRANT  SELECT ON banking_system.accounts TO 'kiran_db'@'localhost';
REVOKE SELECT ON banking_system.accounts FROM 'kiran_db'@'localhost';

-- =====================================================================
-- PART D: THE WEBSITE'S OWN DATABASE ACCOUNT
-- The website logs in as ONE MySQL user. It can read, insert, update and
-- call procedures, but it has no DELETE and no DROP/ALTER at all.
-- Which customer sees which rows is decided by the website, which adds
-- "WHERE customer_id = <logged-in user>" to every customer query.
-- Change this password if you use it anywhere real.
-- =====================================================================
CREATE USER 'bigbank_app'@'localhost' IDENTIFIED BY 'bigbank123';
GRANT SELECT, INSERT, UPDATE, EXECUTE ON banking_system.* TO 'bigbank_app'@'localhost';
