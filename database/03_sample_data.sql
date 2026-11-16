-- =====================================================================
-- BigBank - Banking Management System
-- File 3 of 4: SAMPLE DATA + EXAMPLE QUERIES
--
-- The same people and numbers as section 6 of the project report.
-- Every sample user's password is:  password123
-- (stored as a hash, never as plain text)
--
-- Balances below are OPENING balances: the bank already had this money
-- before our system started, so they are not the sum of the sample
-- transactions.
-- =====================================================================

USE banking_system;

SET @pw = 'pbkdf2:sha256:1000000$eLlGBlXFfRDAkeUB$f923f8f8065ca87423d63b39afffa31d145fe229f6e56a1e11c1db719cf594c1';

-- ---------------------------------------------------------------------
INSERT INTO branches (branch_id, name, ifsc) VALUES
    (1, 'Dwarka Main',     'BNKS0000101'),
    (2, 'Rohini Sector 7', 'BNKS0000102');

-- ---------------------------------------------------------------------
INSERT INTO users (user_id, name, email, phone, password_hash, role) VALUES
    (101, 'Rahul Verma',    'rahul@bigbank.in', '9810000101', @pw, 'Customer'),
    (102, 'Sneha Rao',      'sneha@bigbank.in', '9810000102', @pw, 'Customer'),
    (103, 'Aman Singh',     'aman@bigbank.in',  '9810000103', @pw, 'Customer'),
    (201, 'Meera Kapoor',   'meera@bigbank.in', '9810000201', @pw, 'Employee'),
    (301, 'Arjun Malhotra', 'arjun@bigbank.in', '9810000301', @pw, 'BranchManager'),
    (401, 'Kiran Nair',     'kiran@bigbank.in', '9810000401', @pw, 'Auditor');

-- ---------------------------------------------------------------------
INSERT INTO customers (user_id, dob, address, kyc_status) VALUES
    (101, '1998-04-12', 'Sector 10, Dwarka, New Delhi', 'Approved'),
    (102, '2000-09-23', 'Sector 7, Rohini, New Delhi',  'Approved'),
    (103, '2002-01-30', 'Janakpuri, New Delhi',         'Pending');   -- no accounts yet

-- Manager first, because Meera's row points to Arjun (recursive FK).
-- The auditor (401) has no row here: an auditor is a user but not branch staff.
INSERT INTO employees (user_id, branch_id, designation, manager_employee_id) VALUES
    (301, 1, 'Branch Manager', NULL),
    (201, 1, 'Clerk',          301);

-- ---------------------------------------------------------------------
INSERT INTO kyc_records (kyc_id, customer_id, doc_type, doc_ref, status, reviewed_by_employee_id, remarks, submitted_at) VALUES
    (1, 101, 'Aadhaar', 'XXXX-XXXX-4521', 'Approved', 201, 'Verified',  '2026-07-20 10:00:00'),
    (2, 102, 'PAN',     'ABCPR1234K',     'Approved', 201, 'Verified',  '2026-07-22 11:30:00'),
    (3, 103, 'Aadhaar', 'XXXX-XXXX-7788', 'Pending',  NULL, NULL,       '2026-11-15 09:15:00');

-- ---------------------------------------------------------------------
INSERT INTO account_types (account_type_id, name, interest_rate, max_daily_limit, min_balance, description) VALUES
    (1, 'Savings', 3.50,  50000, 1000, 'For personal savings, earns interest'),
    (2, 'Current', 0.00, 100000,    0, 'For frequent business payments');

-- ---------------------------------------------------------------------
-- (the KYC trigger allows these because 101 and 102 are Approved)
INSERT INTO accounts (account_id, customer_id, branch_id, account_type_id, balance, daily_limit, spending_budget, status, opened_at) VALUES
    (5001, 101, 1, 1, 25000.00,  50000, 10000, 'Active', '2026-07-21 12:00:00'),
    (5002, 101, 1, 2,  8000.00, 100000,  NULL, 'Active', '2026-07-21 12:05:00'),
    (5003, 102, 2, 1, 12000.00,  50000,  8000, 'Active', '2026-07-23 15:00:00');

-- ---------------------------------------------------------------------
-- 8001 = loan 7001 paid out, 8002 = first EMI of loan 7001
-- 9001-9003 = the three rows from the report, 9004 = one more pending request
INSERT INTO transactions (transaction_id, source_account_id, destination_account_id, branch_id,
                          initiated_by_user_id, reviewed_by_employee_id, type, amount, status,
                          idempotency_key, created_at) VALUES
    (8001, NULL, 5001, 1,    201, 201,  'Deposit',    60000.00, 'Success', 'LOAN-7001',   '2026-08-05 10:00:00'),
    (8002, 5001, NULL, NULL, 101, NULL, 'Withdrawal', 10525.00, 'Success', 'EMI-7001-1',  '2026-09-05 09:00:00'),
    (9001, NULL, 5001, 1,    101, 201,  'Deposit',     5000.00, 'Success', 'seed-9001',   '2026-11-10 11:00:00'),
    (9002, 5001, 5003, NULL, 101, NULL, 'Transfer',    2000.00, 'Success', 'seed-9002',   '2026-11-12 18:30:00'),
    (9003, 5001, NULL, NULL, 101, NULL, 'Withdrawal', 40000.00, 'Pending', 'seed-9003',   '2026-11-16 10:00:00'),
    (9004, NULL, 5003, NULL, 102, NULL, 'Deposit',     3000.00, 'Pending', 'seed-9004',   '2026-11-16 12:00:00');

-- ---------------------------------------------------------------------
INSERT INTO loans (loan_id, customer_id, linked_account_id, reviewed_by_employee_id, disbursement_transaction_id,
                   principal, interest_rate, tenure_months, status, requested_at) VALUES
    (7001, 101, 5001, 201, 8001, 60000, 10.50, 6, 'Active', '2026-08-01 10:00:00');

-- principal_part = 60000 / 6 = 10000
-- interest_part  = remaining principal * 10.5 / 12 / 100  (60000 -> 525, 50000 -> 437.50, ...)
INSERT INTO loan_installments (loan_id, installment_no, due_date, principal_part, interest_part, status, payment_transaction_id) VALUES
    (7001, 1, '2026-09-05', 10000, 525.00, 'Paid',    8002),
    (7001, 2, '2026-10-05', 10000, 437.50, 'Overdue', NULL),
    (7001, 3, '2026-11-05', 10000, 350.00, 'Pending', NULL),
    (7001, 4, '2026-12-05', 10000, 262.50, 'Pending', NULL),
    (7001, 5, '2027-01-05', 10000, 175.00, 'Pending', NULL),
    (7001, 6, '2027-02-05', 10000,  87.50, 'Pending', NULL);

-- ---------------------------------------------------------------------
INSERT INTO audit_logs (actor_user_id, action, table_name, record_id, old_value, new_value, logged_at) VALUES
    (201, 'KYC_APPROVED',  'customers', '101',  'Pending',   'Approved', '2026-07-20 16:00:00'),
    (201, 'LOAN_APPROVED', 'loans',     '7001', 'Requested', 'Active',   '2026-08-05 10:00:00');

INSERT INTO notifications (user_id, category, message, transaction_id, is_read, created_at) VALUES
    (101, 'KYC',         'Your KYC is Approved: Verified',             NULL, TRUE,  '2026-07-20 16:00:00'),
    (101, 'Loan',        'Your loan 7001 is now Active',               NULL, TRUE,  '2026-08-05 10:00:00'),
    (101, 'Loan',        'Installment 2 of loan 7001 is now overdue',  NULL, FALSE, '2026-10-06 00:00:00'),
    (101, 'Transaction', 'Rs 2000.00 sent from account 5001 to 5003', 9002, FALSE, '2026-11-12 18:30:00'),
    (102, 'Transaction', 'Rs 2000.00 received in account 5003',        9002, FALSE, '2026-11-12 18:30:00');


-- =====================================================================
-- EXAMPLE QUERIES (section 8 of the report)
-- =====================================================================

-- 1. Accounts and balances of customers whose KYC is approved
SELECT u.name, a.account_id, t.name AS account_type, a.balance
FROM customers c
JOIN users u         ON u.user_id = c.user_id
JOIN accounts a      ON a.customer_id = c.user_id
JOIN account_types t ON t.account_type_id = a.account_type_id
WHERE c.kyc_status = 'Approved';

-- 2. Transactions waiting for employee approval
SELECT transaction_id, type, amount, source_account_id, initiated_by_user_id
FROM transactions
WHERE status = 'Pending'
ORDER BY created_at;

-- 3. Overdue installments with days overdue
SELECT loan_id, installment_no, due_date,
       DATEDIFF(CURDATE(), due_date) AS days_overdue
FROM loan_installments
WHERE status = 'Overdue';

-- 4. Outstanding balance of each active loan
SELECT l.loan_id, SUM(li.principal_part) AS outstanding_balance
FROM loans l
JOIN loan_installments li ON li.loan_id = l.loan_id
WHERE l.status = 'Active' AND li.status <> 'Paid'
GROUP BY l.loan_id;

-- 5. Audit trail for one record
SELECT logged_at, actor_user_id, action, old_value, new_value
FROM audit_logs
WHERE table_name = 'loans' AND record_id = '7001'
ORDER BY logged_at;
