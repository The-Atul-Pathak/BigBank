-- =====================================================================
-- BigBank - Banking Management System
-- File 4 of 4: ACCESS CONTROL (DCL - GRANT / REVOKE)
-- PostgreSQL version (the original MySQL scripts are in database/mysql/).
--
-- Run as the admin user (e.g. avnadmin on Aiven) AFTER the other three files.
--
-- Part A: one role per job, each with only the access it needs.
-- Part B: demo roles, one per job, to show the roles working.
-- Part C: a REVOKE example.
-- Part D: the account the website itself connects with.
--
-- In PostgreSQL "users" and "roles" are the same thing: a user is just a
-- role that is allowed to LOGIN.
-- =====================================================================

SET search_path = banking_system;

-- Clean re-run support: take back what each role was given, then drop it.
DO $$
DECLARE
    r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY['rahul_db', 'meera_db', 'arjun_db', 'kiran_db', 'bigbank_app',
                             'customer_role', 'employee_role', 'manager_role', 'auditor_role'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('REVOKE ALL ON ALL TABLES     IN SCHEMA banking_system FROM %I', r);
            EXECUTE format('REVOKE ALL ON ALL ROUTINES   IN SCHEMA banking_system FROM %I', r);
            EXECUTE format('REVOKE ALL ON SCHEMA banking_system FROM %I', r);
            EXECUTE format('DROP ROLE %I', r);
        END IF;
    END LOOP;
END;
$$;

-- PostgreSQL lets EVERYONE run new functions and procedures by default.
-- Take that away, so only the roles granted below can call them.
REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA banking_system FROM PUBLIC;

-- =====================================================================
-- PART A: ROLES
-- =====================================================================
CREATE ROLE customer_role NOLOGIN;
CREATE ROLE employee_role NOLOGIN;
CREATE ROLE manager_role  NOLOGIN;
CREATE ROLE auditor_role  NOLOGIN;

-- Every role needs to be allowed into the schema first.
GRANT USAGE ON SCHEMA banking_system TO customer_role, employee_role, manager_role, auditor_role;

-- ---------- Customer: reads through views, moves money through procedures
GRANT SELECT ON v_account_overview TO customer_role;
GRANT SELECT ON v_loan_summary     TO customer_role;
GRANT INSERT ON kyc_records        TO customer_role;   -- submit KYC
GRANT INSERT ON loans              TO customer_role;   -- apply for a loan
GRANT INSERT ON transactions       TO customer_role;   -- request deposit / withdrawal
GRANT EXECUTE ON PROCEDURE sp_transfer        TO customer_role;
GRANT EXECUTE ON PROCEDURE sp_pay_installment TO customer_role;
GRANT EXECUTE ON PROCEDURE sp_repay_loan      TO customer_role;

-- ---------- Employee: reads banking data, reviews things
GRANT SELECT ON users, customers, kyc_records, accounts, transactions,
                loans, loan_installments,
                v_account_overview, v_loan_summary, v_overdue_installments
      TO employee_role;

-- Column-level privileges: an employee may change ONLY these columns.
-- (e.g. they can freeze an account, but can never edit its balance)
GRANT UPDATE (status, reviewed_by_employee_id, remarks) ON kyc_records TO employee_role;
GRANT UPDATE (status)                                   ON accounts    TO employee_role;
GRANT UPDATE (status, reviewed_by_employee_id)          ON loans       TO employee_role;

GRANT EXECUTE ON PROCEDURE sp_review_transaction  TO employee_role;
GRANT EXECUTE ON PROCEDURE sp_reverse_transaction TO employee_role;
GRANT EXECUTE ON PROCEDURE sp_approve_loan        TO employee_role;
GRANT EXECUTE ON PROCEDURE sp_mark_overdue        TO employee_role;

-- ---------- Branch manager: everything an employee has, plus branch summaries
GRANT employee_role TO manager_role;                    -- a role inside a role
GRANT SELECT ON v_branch_summary TO manager_role;
GRANT EXECUTE ON PROCEDURE sp_add_employee TO manager_role;   -- onboard staff

-- ---------- Auditor: can only READ the audit log
GRANT SELECT ON audit_logs TO auditor_role;

-- Note: nobody gets UPDATE or DELETE on audit_logs. Even if someone did,
-- the triggers trg_audit_no_update / trg_audit_no_delete would block it.

-- =====================================================================
-- PART B: DEMO ROLES (one per job)
-- They are NOLOGIN, because this database is reachable from the internet
-- and a well-known demo password would be a real risk. Try them from an
-- admin session with SET ROLE instead:
--
--   GRANT kiran_db TO CURRENT_USER;
--   SET ROLE kiran_db;
--   SELECT * FROM audit_logs;      -- works
--   SELECT * FROM accounts;        -- ERROR: permission denied for table accounts
--   DELETE FROM audit_logs;        -- ERROR: permission denied for table audit_logs
--   RESET ROLE;
-- =====================================================================
CREATE ROLE rahul_db NOLOGIN IN ROLE customer_role;
CREATE ROLE meera_db NOLOGIN IN ROLE employee_role;
CREATE ROLE arjun_db NOLOGIN IN ROLE manager_role;
CREATE ROLE kiran_db NOLOGIN IN ROLE auditor_role;

-- See what a role can do:
--   SELECT table_name, privilege_type FROM information_schema.role_table_grants
--   WHERE grantee = 'auditor_role';

-- =====================================================================
-- PART C: REVOKE example
-- The auditor is given temporary read access to accounts for an
-- investigation, and it is taken back afterwards.
-- =====================================================================
GRANT  SELECT ON accounts TO kiran_db;
REVOKE SELECT ON accounts FROM kiran_db;

-- =====================================================================
-- PART D: THE WEBSITE'S OWN DATABASE ACCOUNT
-- The website logs in as ONE user. It can read, insert, update and
-- call procedures, but it has no DELETE and no DROP/ALTER at all.
-- Which customer sees which rows is decided by the website, which adds
-- "WHERE customer_id = <logged-in user>" to every customer query.
--
-- No password is set here, so none ends up in this file. Set one yourself:
--   ALTER ROLE bigbank_app PASSWORD '<a long random password>';
-- =====================================================================
CREATE ROLE bigbank_app LOGIN;
GRANT USAGE ON SCHEMA banking_system TO bigbank_app;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA banking_system TO bigbank_app;
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA banking_system TO bigbank_app;

-- Every connection of the website starts in the right schema and time zone.
ALTER ROLE bigbank_app SET search_path = banking_system;
ALTER ROLE bigbank_app SET timezone = 'Asia/Kolkata';
