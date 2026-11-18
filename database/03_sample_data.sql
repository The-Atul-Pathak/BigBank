-- =====================================================================
-- BigBank - Banking Management System
-- File 3 of 4: SAMPLE DATA + EXAMPLE QUERIES
--
-- The first rows of every table are the original data from section 6
-- of the project report. The rows after the line
--     "---- more sample data ----"
-- were added to give extra stories to explain.
--
-- Every sample user's password is:  password123
-- (stored as a hash, never as plain text)
--
-- Balances below are OPENING balances: the bank already had this money
-- before our system started, so they are not the sum of the sample
-- transactions.
--
-- STORIES YOU CAN EXPLAIN (all dates are before 18 Nov 2026):
--
--  A. Rahul Verma (101)   - loan 7001 (Rs 60,000), approved by Meera Kapoor (201),
--                           Meera reports to Arjun Malhotra (301). One EMI overdue.
--  B. Priya Sharma (104)  - good loan customer, but over her monthly budget
--       Loan 7002: Rs 48,000, 4 months. Approved by Pooja Mehta (203).
--       Pooja reports to Arjun Malhotra (301). Pooja also approved Priya's KYC.
--       2 of 4 EMIs paid. Her second account 5008 is FROZEN by Arjun.
--  C. Karan Mehta (105)   - loan fully repaid (CLOSED) + one loan REJECTED
--       Loan 7003: Rs 20,000, 2 months, approved by Deepak Yadav (205), Closed.
--       Loan 7005: Rs 5,00,000, rejected by Deepak.
--       Deepak reports to Neha Gupta (302).
--  D. Divya Nair (106)    - new branch (Janakpuri), loan request still PENDING
--       Loan 7004: Rs 50,000 waiting. Anjali Desai (206, manager Suresh Iyer 303)
--       can approve it live:  CALL sp_approve_loan(206, 7004);
--       Also: Aman Singh's pending KYC (id 3) can be reviewed by Anjali.
--  E. Mohit Jain (107)    - KYC REJECTED by Rohit Sharma (204)
--     Ishita Bansal (108) - KYC NEEDS CORRECTION (reviewed by Pooja)
--  F. Hierarchy (recursive FK):  Rohit (204) -> Pooja (203) -> Arjun (301)
--  G. Reversal example: Divya's wrong deposit 9011 reversed by 9012 (Anjali).
-- =====================================================================

SET search_path = banking_system;

-- ---------------------------------------------------------------------
INSERT INTO branches (branch_id, name, ifsc) VALUES
    (1, 'Dwarka Main',     'BNKS0000101'),
    (2, 'Rohini Sector 7', 'BNKS0000102'),
    -- ---- more sample data ----
    (3, 'Janakpuri',       'BNKS0000103');

-- ---------------------------------------------------------------------
-- Every user gets the same password hash (password123), set once in the SELECT.
INSERT INTO users (user_id, name, email, phone, role, password_hash)
SELECT v.*, 'pbkdf2:sha256:1000000$eLlGBlXFfRDAkeUB$f923f8f8065ca87423d63b39afffa31d145fe229f6e56a1e11c1db719cf594c1'
FROM (VALUES
    (101, 'Rahul Verma',    'rahul@bigbank.in', '9810000101', 'Customer'),
    (102, 'Sneha Rao',      'sneha@bigbank.in', '9810000102', 'Customer'),
    (103, 'Aman Singh',     'aman@bigbank.in',  '9810000103', 'Customer'),
    (201, 'Meera Kapoor',   'meera@bigbank.in', '9810000201', 'Employee'),
    (202, 'Vikram Shah',    'vikram@bigbank.in','9810000202', 'Employee'),
    (301, 'Arjun Malhotra', 'arjun@bigbank.in', '9810000301', 'BranchManager'),
    (302, 'Neha Gupta',     'neha@bigbank.in',  '9810000302', 'BranchManager'),
    (401, 'Kiran Nair',     'kiran@bigbank.in', '9810000401', 'Auditor'),
    -- ---- more sample data ----
    (104, 'Priya Sharma',   'priya@bigbank.in',  '9810000104', 'Customer'),
    (105, 'Karan Mehta',    'karan@bigbank.in',  '9810000105', 'Customer'),
    (106, 'Divya Nair',     'divya@bigbank.in',  '9810000106', 'Customer'),
    (107, 'Mohit Jain',     'mohit@bigbank.in',  '9810000107', 'Customer'),
    (108, 'Ishita Bansal',  'ishita@bigbank.in', '9810000108', 'Customer'),
    (203, 'Pooja Mehta',    'pooja@bigbank.in',  '9810000203', 'Employee'),
    (204, 'Rohit Sharma',   'rohit@bigbank.in',  '9810000204', 'Employee'),
    (205, 'Deepak Yadav',   'deepak@bigbank.in', '9810000205', 'Employee'),
    (206, 'Anjali Desai',   'anjali@bigbank.in', '9810000206', 'Employee'),
    (303, 'Suresh Iyer',    'suresh@bigbank.in', '9810000303', 'BranchManager')
) AS v(user_id, name, email, phone, role);

-- ---------------------------------------------------------------------
INSERT INTO customers (user_id, dob, address, kyc_status) VALUES
    (101, '1998-04-12', 'Sector 10, Dwarka, New Delhi', 'Approved'),
    (102, '2000-09-23', 'Sector 7, Rohini, New Delhi',  'Approved'),
    (103, '2002-01-30', 'Janakpuri, New Delhi',         'Pending'),   -- no accounts yet
    -- ---- more sample data ----
    (104, '1995-06-18', 'Sector 12, Dwarka, New Delhi', 'Approved'),
    (105, '1990-02-05', 'Sector 11, Rohini, New Delhi', 'Approved'),
    (106, '1997-12-01', 'Janakpuri, New Delhi',         'Approved'),
    (107, '2001-03-14', 'Pitampura, New Delhi',         'Rejected'),
    (108, '1999-08-27', 'Sector 3, Rohini, New Delhi',  'Pending');   -- needs correction

-- Managers first, because each clerk's row points to their manager (recursive FK).
-- A manager (or a senior clerk) must be inserted before the people who report to him/her.
-- Each branch has one manager and at least one clerk. Staff only see their own branch.
-- The auditor (401) has no row here: an auditor is a user but not branch staff.
INSERT INTO employees (user_id, branch_id, designation, manager_employee_id) VALUES
    (301, 1, 'Branch Manager', NULL),   -- Arjun, Dwarka
    (302, 2, 'Branch Manager', NULL),   -- Neha, Rohini
    (201, 1, 'Clerk',          301),    -- Meera reports to Arjun
    (202, 2, 'Clerk',          302),    -- Vikram reports to Neha
    -- ---- more sample data ----
    (303, 3, 'Branch Manager', NULL),   -- Suresh, Janakpuri
    (203, 1, 'Senior Clerk',   301),    -- Pooja reports to Arjun
    (204, 1, 'Clerk',          203),    -- Rohit reports to Pooja  (Rohit -> Pooja -> Arjun)
    (205, 2, 'Clerk',          302),    -- Deepak reports to Neha
    (206, 3, 'Clerk',          303);    -- Anjali reports to Suresh

-- ---------------------------------------------------------------------
INSERT INTO kyc_records (kyc_id, customer_id, doc_type, doc_ref, status, reviewed_by_employee_id, remarks, submitted_at) VALUES
    (1, 101, 'Aadhaar', 'XXXX-XXXX-4521', 'Approved', 201, 'Verified',  '2026-07-20 10:00:00'),
    (2, 102, 'PAN',     'ABCPR1234K',     'Approved', 201, 'Verified',  '2026-07-22 11:30:00'),
    (3, 103, 'Aadhaar', 'XXXX-XXXX-7788', 'Pending',  NULL, NULL,       '2026-11-15 09:15:00'),
    -- ---- more sample data ----
    (4, 104, 'Aadhaar', 'XXXX-XXXX-3344', 'Approved',        203, 'Verified',                     '2026-08-10 10:30:00'),
    (5, 105, 'PAN',     'BKMPM5521L',     'Approved',        205, 'Verified',                     '2026-08-12 11:00:00'),
    (6, 106, 'Aadhaar', 'XXXX-XXXX-9012', 'Approved',        206, 'Verified',                     '2026-08-14 12:15:00'),
    (7, 107, 'PAN',     'JNMPJ7788Q',     'Rejected',        204, 'Name does not match document','2026-10-02 14:00:00'),
    (8, 108, 'Aadhaar', 'XXXX-XXXX-6655', 'NeedsCorrection', 203, 'Address proof is missing',     '2026-10-20 09:45:00');

-- ---------------------------------------------------------------------
INSERT INTO account_types (account_type_id, name, interest_rate, max_daily_limit, min_balance, description) VALUES
    (1, 'Savings', 3.50,  50000, 1000, 'For personal savings, earns interest'),
    (2, 'Current', 0.00, 100000,    0, 'For frequent business payments');

-- ---------------------------------------------------------------------
-- (the KYC trigger allows these because the owners are Approved)
INSERT INTO accounts (account_id, customer_id, branch_id, account_type_id, balance, daily_limit, spending_budget, status, opened_at) VALUES
    (5001, 101, 1, 1, 25000.00,  50000, 10000, 'Active', '2026-07-21 12:00:00'),
    (5002, 101, 1, 2,  8000.00, 100000,  NULL, 'Active', '2026-07-21 12:05:00'),
    (5003, 102, 2, 1, 12000.00,  50000,  8000, 'Active', '2026-07-23 15:00:00'),
    -- ---- more sample data ----
    (5004, 104, 1, 1,  45000.00,  50000, 15000, 'Active', '2026-08-11 12:00:00'),  -- Priya, Savings
    (5005, 105, 2, 2, 150000.00, 100000,  NULL, 'Active', '2026-08-13 11:30:00'),  -- Karan, Current
    (5006, 105, 2, 1,  30000.00,  40000, 12000, 'Active', '2026-08-13 11:40:00'),  -- Karan, Savings
    (5007, 106, 3, 1,  18000.00,  25000,  6000, 'Active', '2026-08-15 10:00:00'),  -- Divya, Savings
    (5008, 104, 1, 2,   5000.00, 100000,  NULL, 'Frozen', '2026-08-11 12:10:00');  -- Priya, Current (frozen)

-- ---------------------------------------------------------------------
-- 8001 = loan 7001 paid out, 8002 = first EMI of loan 7001
-- 9001-9003 = the three rows from the report, 9004 = one more pending request
-- ---- more sample data ----
-- 8003-8005 = loan 7002 payout + its 2 EMIs (Priya)
-- 8006-8008 = loan 7003 payout + its 2 EMIs (Karan)
-- 9005-9010 = normal activity, pending and rejected requests
-- 9011      = a wrong deposit (typed 15000 instead of 1500)
INSERT INTO transactions (transaction_id, source_account_id, destination_account_id, branch_id,
                          initiated_by_user_id, reviewed_by_employee_id, type, amount, status,
                          idempotency_key, created_at) VALUES
    (8001, NULL, 5001, 1,    201, 201,  'Deposit',    60000.00, 'Success', 'LOAN-7001',   '2026-08-05 10:00:00'),
    (8002, 5001, NULL, NULL, 101, NULL, 'Withdrawal', 10525.00, 'Success', 'EMI-7001-1',  '2026-09-05 09:00:00'),
    (9001, NULL, 5001, 1,    101, 201,  'Deposit',     5000.00, 'Success', 'seed-9001',   '2026-11-10 11:00:00'),
    (9002, 5001, 5003, NULL, 101, NULL, 'Transfer',    2000.00, 'Success', 'seed-9002',   '2026-11-12 18:30:00'),
    (9003, 5001, NULL, NULL, 101, NULL, 'Withdrawal', 40000.00, 'Pending', 'seed-9003',   '2026-11-16 10:00:00'),
    (9004, NULL, 5003, NULL, 102, NULL, 'Deposit',     3000.00, 'Pending', 'seed-9004',   '2026-11-16 12:00:00'),
    -- ---- more sample data ----
    (8003, NULL, 5004, 1,    203, 203,  'Deposit',    48000.00, 'Success',  'LOAN-7002',  '2026-09-03 10:00:00'),
    (8004, 5004, NULL, NULL, 104, NULL, 'Withdrawal', 12420.00, 'Success',  'EMI-7002-1', '2026-10-03 09:00:00'),
    (8005, 5004, NULL, NULL, 104, NULL, 'Withdrawal', 12315.00, 'Success',  'EMI-7002-2', '2026-11-03 09:00:00'),
    (8006, NULL, 5006, 2,    205, 205,  'Deposit',    20000.00, 'Success',  'LOAN-7003',  '2026-09-06 11:00:00'),
    (8007, 5006, NULL, NULL, 105, NULL, 'Withdrawal', 10175.00, 'Success',  'EMI-7003-1', '2026-10-06 09:00:00'),
    (8008, 5006, NULL, NULL, 105, NULL, 'Withdrawal', 10087.50, 'Success',  'EMI-7003-2', '2026-11-06 09:00:00'),
    (9005, NULL, 5005, 2,    105, 205,  'Deposit',    25000.00, 'Success',  'seed-9005',  '2026-11-11 12:00:00'),
    (9006, 5005, 5006, NULL, 105, NULL, 'Transfer',   10000.00, 'Success',  'seed-9006',  '2026-11-13 15:00:00'),
    (9007, 5004, 5003, NULL, 104, NULL, 'Transfer',    3000.00, 'Success',  'seed-9007',  '2026-11-14 17:45:00'),
    (9008, 5007, NULL, NULL, 106, NULL, 'Withdrawal',  2000.00, 'Pending',  'seed-9008',  '2026-11-17 11:00:00'),
    (9009, 5006, NULL, 2,    105, 205,  'Withdrawal',  5000.00, 'Rejected', 'seed-9009',  '2026-11-15 10:30:00'),
    (9010, NULL, 5004, 1,    104, 204,  'Deposit',     8000.00, 'Success',  'seed-9010',  '2026-11-16 13:00:00'),
    (9011, NULL, 5007, 3,    106, 206,  'Deposit',    15000.00, 'Success',  'seed-9011',  '2026-11-12 14:00:00');

-- ---- more sample data ----
-- Reversal of 9011: the same amount goes back the other way, nothing is deleted.
INSERT INTO transactions (transaction_id, source_account_id, destination_account_id, branch_id,
                          initiated_by_user_id, reviewed_by_employee_id, reversal_of_transaction_id,
                          type, amount, status, idempotency_key, created_at) VALUES
    (9012, 5007, NULL, 3, 206, 206, 9011, 'Withdrawal', 15000.00, 'Success', 'REV-9011', '2026-11-12 16:30:00');

-- The correct deposit, posted afterwards
INSERT INTO transactions (transaction_id, source_account_id, destination_account_id, branch_id,
                          initiated_by_user_id, reviewed_by_employee_id, type, amount, status,
                          idempotency_key, created_at) VALUES
    (9013, NULL, 5007, 3, 106, 206, 'Deposit', 1500.00, 'Success', 'seed-9013', '2026-11-12 16:45:00');

-- ---------------------------------------------------------------------
-- 7001 Rahul  Active
-- ---- more sample data ----
-- 7002 Priya  Active     approved by Pooja
-- 7003 Karan  Closed     approved by Deepak
-- 7004 Divya  Requested  waiting (no reviewer, no payout yet)
-- 7005 Karan  Rejected   by Deepak
INSERT INTO loans (loan_id, customer_id, linked_account_id, reviewed_by_employee_id, disbursement_transaction_id,
                   principal, interest_rate, tenure_months, status, requested_at) VALUES
    (7001, 101, 5001, 201, 8001, 60000, 10.50, 6, 'Active', '2026-08-01 10:00:00'),
    -- ---- more sample data ----
    (7002, 104, 5004, 203,  8003, 48000.00,  10.50, 4,  'Active',    '2026-09-01 10:00:00'),
    (7003, 105, 5006, 205,  8006, 20000.00,  10.50, 2,  'Closed',    '2026-09-05 10:00:00'),
    (7004, 106, 5007, NULL, NULL, 50000.00,  10.50, 6,  'Requested', '2026-11-17 10:00:00'),
    (7005, 105, 5005, 205,  NULL, 500000.00, 10.50, 24, 'Rejected',  '2026-10-20 10:00:00');

-- principal_part = 60000 / 6 = 10000
-- interest_part  = remaining principal * 10.5 / 12 / 100  (60000 -> 525, 50000 -> 437.50, ...)
-- Loan 7002: 48000 / 4 = 12000 per month.   Loan 7003: 20000 / 2 = 10000 per month.
INSERT INTO loan_installments (loan_id, installment_no, due_date, principal_part, interest_part, status, payment_transaction_id) VALUES
    (7001, 1, '2026-09-05', 10000, 525.00, 'Paid',    8002),
    (7001, 2, '2026-10-05', 10000, 437.50, 'Overdue', NULL),
    (7001, 3, '2026-11-05', 10000, 350.00, 'Pending', NULL),
    (7001, 4, '2026-12-05', 10000, 262.50, 'Pending', NULL),
    (7001, 5, '2027-01-05', 10000, 175.00, 'Pending', NULL),
    (7001, 6, '2027-02-05', 10000,  87.50, 'Pending', NULL),
    -- ---- more sample data ----
    (7002, 1, '2026-10-03', 12000, 420.00, 'Paid',    8004),
    (7002, 2, '2026-11-03', 12000, 315.00, 'Paid',    8005),
    (7002, 3, '2026-12-03', 12000, 210.00, 'Pending', NULL),
    (7002, 4, '2027-01-03', 12000, 105.00, 'Pending', NULL),
    (7003, 1, '2026-10-06', 10000, 175.00, 'Paid',    8007),
    (7003, 2, '2026-11-06', 10000,  87.50, 'Paid',    8008);

-- ---------------------------------------------------------------------
INSERT INTO audit_logs (actor_user_id, action, table_name, record_id, old_value, new_value, logged_at) VALUES
    (201, 'KYC_APPROVED',  'customers', '101',  'Pending',   'Approved', '2026-07-20 16:00:00'),
    (201, 'LOAN_APPROVED', 'loans',     '7001', 'Requested', 'Active',   '2026-08-05 10:00:00'),
    -- ---- more sample data ----
    (301, 'EMPLOYEE_ADDED', 'employees', '203', NULL, 'Senior Clerk at branch 1', '2026-08-01 09:00:00'),
    (302, 'EMPLOYEE_ADDED', 'employees', '205', NULL, 'Clerk at branch 2',        '2026-08-01 09:30:00'),
    (303, 'EMPLOYEE_ADDED', 'employees', '206', NULL, 'Clerk at branch 3',        '2026-08-02 09:00:00'),
    (203, 'KYC_APPROVED',   'customers', '104', 'Pending', 'Approved',            '2026-08-10 15:00:00'),
    (205, 'KYC_APPROVED',   'customers', '105', 'Pending', 'Approved',            '2026-08-12 16:00:00'),
    (206, 'KYC_APPROVED',   'customers', '106', 'Pending', 'Approved',            '2026-08-14 17:00:00'),
    (204, 'KYC_REJECTED',   'customers', '107', 'Pending', 'Rejected',            '2026-10-03 11:00:00'),
    (203, 'KYC_NEEDSCORRECTION', 'customers', '108', 'Pending', 'NeedsCorrection','2026-10-21 10:00:00'),
    (203, 'LOAN_APPROVED',  'loans',     '7002', 'Requested', 'Active',           '2026-09-03 10:00:00'),
    (205, 'LOAN_APPROVED',  'loans',     '7003', 'Requested', 'Active',           '2026-09-06 11:00:00'),
    (105, 'LOAN_CLOSED',    'loans',     '7003', 'Active',    'Closed',           '2026-11-06 09:00:00'),
    (205, 'LOAN_REJECTED',  'loans',     '7005', 'Requested', 'Rejected',         '2026-10-22 12:00:00'),
    (205, 'TXN_REJECTED',   'transactions', '9009', 'Pending', 'Rejected',        '2026-11-15 11:00:00'),
    (206, 'TXN_REVERSED',   'transactions', '9011', 'Success', 'reversed by 9012','2026-11-12 16:30:00'),
    (301, 'ACCOUNT_FROZEN', 'accounts',  '5008', 'Active',    'Frozen',           '2026-11-14 12:00:00');

-- Priya went over her monthly budget: Nov spending on 5004 = 12315 + 3000 = 15315,
-- her budget is 15000, so she is over by 315.
INSERT INTO notifications (user_id, category, message, transaction_id, is_read, created_at) VALUES
    (101, 'KYC',         'Your KYC is Approved: Verified',             NULL, TRUE,  '2026-07-20 16:00:00'),
    (101, 'Loan',        'Your loan 7001 is now Active',               NULL, TRUE,  '2026-08-05 10:00:00'),
    (101, 'Loan',        'Installment 2 of loan 7001 is now overdue',  NULL, FALSE, '2026-10-06 00:00:00'),
    (101, 'Transaction', 'Rs 2000.00 sent from account 5001 to 5003', 9002, FALSE, '2026-11-12 18:30:00'),
    (102, 'Transaction', 'Rs 2000.00 received in account 5003',        9002, FALSE, '2026-11-12 18:30:00'),
    -- ---- more sample data ----
    (104, 'KYC',         'Your KYC is Approved: Verified',                         NULL, TRUE,  '2026-08-10 15:00:00'),
    (105, 'KYC',         'Your KYC is Approved: Verified',                         NULL, TRUE,  '2026-08-12 16:00:00'),
    (106, 'KYC',         'Your KYC is Approved: Verified',                         NULL, TRUE,  '2026-08-14 17:00:00'),
    (107, 'KYC',         'Your KYC is Rejected: Name does not match document',     NULL, FALSE, '2026-10-03 11:00:00'),
    (108, 'KYC',         'Your KYC is NeedsCorrection: Address proof is missing',  NULL, FALSE, '2026-10-21 10:00:00'),
    (104, 'Loan',        'Your loan 7002 is now Active',                           NULL, TRUE,  '2026-09-03 10:00:00'),
    (104, 'Loan',        'Installment 2 of loan 7002 paid: Rs 12315.00',           8005, TRUE,  '2026-11-03 09:00:00'),
    (105, 'Loan',        'Your loan 7003 is now Active',                           NULL, TRUE,  '2026-09-06 11:00:00'),
    (105, 'Loan',        'Your loan 7003 is now Closed',                           NULL, TRUE,  '2026-11-06 09:00:00'),
    (105, 'Loan',        'Your loan 7005 is now Rejected',                         NULL, FALSE, '2026-10-22 12:00:00'),
    (104, 'Transaction', 'Rs 3000.00 sent from account 5004 to 5003',              9007, FALSE, '2026-11-14 17:45:00'),
    (102, 'Transaction', 'Rs 3000.00 received in account 5003',                    9007, FALSE, '2026-11-14 17:45:00'),
    (104, 'Budget',      'Account 5004 is over its monthly budget by Rs 315.00',   NULL, FALSE, '2026-11-14 17:45:00'),
    (104, 'Security',    'Your account 5008 is now Frozen',                        NULL, FALSE, '2026-11-14 12:00:00'),
    (105, 'Transaction', 'Your withdrawal of Rs 5000.00 was rejected',             9009, FALSE, '2026-11-15 11:00:00');


-- ---------------------------------------------------------------------
-- The rows above were inserted with fixed ids. Move each id counter past
-- the highest id, so new rows (e.g. a new account) continue from there.
-- (MySQL's AUTO_INCREMENT does this by itself.)
SELECT setval(pg_get_serial_sequence('branches', 'branch_id'),             (SELECT MAX(branch_id) FROM branches));
SELECT setval(pg_get_serial_sequence('users', 'user_id'),                  (SELECT MAX(user_id) FROM users));
SELECT setval(pg_get_serial_sequence('kyc_records', 'kyc_id'),             (SELECT MAX(kyc_id) FROM kyc_records));
SELECT setval(pg_get_serial_sequence('account_types', 'account_type_id'), (SELECT MAX(account_type_id) FROM account_types));
SELECT setval(pg_get_serial_sequence('accounts', 'account_id'),            (SELECT MAX(account_id) FROM accounts));
SELECT setval(pg_get_serial_sequence('transactions', 'transaction_id'),    (SELECT MAX(transaction_id) FROM transactions));
SELECT setval(pg_get_serial_sequence('loans', 'loan_id'),                  (SELECT MAX(loan_id) FROM loans));

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
       CURRENT_DATE - due_date AS days_overdue
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

-- ---- more example queries (for the extra sample data) ----

-- 6. Who reports to whom (self join on the recursive FK)
SELECT e.user_id, u.name AS employee, e.designation,
       m.user_id AS manager_id, mu.name AS manager
FROM employees e
JOIN users u          ON u.user_id = e.user_id
LEFT JOIN employees m ON m.user_id = e.manager_employee_id
LEFT JOIN users mu    ON mu.user_id = m.user_id
ORDER BY e.branch_id, e.manager_employee_id;

-- 7. Each loan: customer, amount, status and the employee who reviewed it
SELECT l.loan_id, cu.name AS customer, l.principal, l.status, ru.name AS reviewed_by
FROM loans l
JOIN users cu      ON cu.user_id = l.customer_id
LEFT JOIN users ru ON ru.user_id = l.reviewed_by_employee_id
ORDER BY l.loan_id;

-- 8. Each KYC record with the employee who reviewed it
SELECT k.kyc_id, cu.name AS customer, k.doc_type, k.status, ru.name AS reviewed_by, k.remarks
FROM kyc_records k
JOIN users cu      ON cu.user_id = k.customer_id
LEFT JOIN users ru ON ru.user_id = k.reviewed_by_employee_id
ORDER BY k.kyc_id;
