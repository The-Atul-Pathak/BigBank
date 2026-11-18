# BigBank: Banking Management System

DBMS Lab project (COCSC302). This is a banking database in MySQL, with a small Flask
website on top of it.

The main idea is that **the bank's rules live inside the database**, as triggers, stored
procedures, CHECK constraints and views. The website only shows pages and passes the
user's actions to MySQL. If a rule fails, MySQL raises an error and the website shows
that error message.

## Project structure

```
database/
  01_schema.sql        12 tables with PK, FK, UNIQUE, CHECK constraints
  02_logic.sql         4 views, 1 function, 10 triggers, 9 procedures, 1 daily event
  03_sample_data.sql   sample data from the report + the 5 example queries
  04_access.sql        DCL: roles, GRANT / REVOKE, the website's MySQL user
app/
  app.py               every web page (Flask routes), grouped by role
  db.py                the only file that talks to MySQL (query / execute / call)
  icons.py             the small set of inline SVG icons used by the pages
  templates/           HTML pages (Jinja): base.html is the sidebar layout,
                       _auth.html the login/register layout, _ui.html the shared
                       pieces (stat tile, card header, status badge)
  static/style.css     the one stylesheet
```

## How to run

You need MySQL 8.0.16 or newer (for CHECK constraints) and Python 3.9 or newer.

**1. Load the database** (enter your MySQL root password when asked):

```bash
mysql -u root -p < database/01_schema.sql
mysql -u root -p < database/02_logic.sql
mysql -u root -p < database/03_sample_data.sql
mysql -u root -p < database/04_access.sql
```

Running the four files again resets everything to the sample data.

**2. Install and start the website:**

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cd app
python app.py
```

Then open http://127.0.0.1:5000.

The website connects as the MySQL user `bigbank_app` (password `bigbank123`), which
`04_access.sql` creates. To connect as a different user, set environment variables first,
for example `DB_USER=root DB_PASSWORD=yourpass python app.py`. `DB_HOST` and `DB_PORT`
can be set the same way.

## Demo logins

Every sample user's password is `password123`.

| Email | Role | Good for showing |
|---|---|---|
| rahul@bigbank.in | Customer, Dwarka | 2 accounts, an active loan with an overdue installment |
| sneha@bigbank.in | Customer, Rohini | 1 account, a pending deposit |
| aman@bigbank.in | Customer | KYC still pending, so he cannot open an account |
| priya@bigbank.in | Customer, Dwarka | over her monthly budget, one frozen account (5008), loan with 2 of 4 EMIs paid |
| karan@bigbank.in | Customer, Rohini | a fully repaid (Closed) loan and a Rejected loan |
| divya@bigbank.in | Customer, Janakpuri | a loan request still waiting for approval, a reversed deposit |
| mohit@bigbank.in | Customer | KYC Rejected |
| ishita@bigbank.in | Customer | KYC NeedsCorrection |
| meera@bigbank.in | Employee, Dwarka | work queue: KYC, deposits/withdrawals, loans |
| pooja@bigbank.in | Senior Clerk, Dwarka | reports to Arjun; Rohit reports to her |
| rohit@bigbank.in | Employee, Dwarka | reports to Pooja (Rohit → Pooja → Arjun) |
| arjun@bigbank.in | Branch Manager, Dwarka | everything staff can do + branch page + add employees |
| vikram@bigbank.in, deepak@bigbank.in | Employee, Rohini | approve Sneha's and Karan's requests |
| neha@bigbank.in | Branch Manager, Rohini | same as Arjun, for Rohini |
| anjali@bigbank.in | Employee, Janakpuri | can approve Divya's pending loan 7004 |
| suresh@bigbank.in | Branch Manager, Janakpuri | same as Arjun, for Janakpuri |
| kiran@bigbank.in | Auditor | read-only audit log |

## A 5-minute demo

1. **KYC gate.** Log in as Aman and click *Open account*. You get *"KYC must be approved
   before opening an account"* (trigger `trg_accounts_before_insert`).
2. **KYC review.** Log in as Meera and approve Aman's KYC in the work queue. Log in as
   Aman again: the KYC shows Approved, there is a notification, and opening an account
   now works.
3. **Atomic transfer.** As Rahul, transfer Rs 500 from 5001 to 5003. Then try Rs 99,999:
   *"Insufficient balance"*, and nothing changes (`sp_transfer` rolls back).
4. **Approval workflow.** As Meera, approve withdrawal 9003 (Rs 40,000). It is refused
   because Rahul only has Rs 25,000. Reject it instead. Sneha's deposit 9004 is in Rohini,
   so Meera can't see it: log in as Vikram, approve it, and her balance goes up.
5. **Reversal.** As Meera, open *Transactions* and reverse a transfer. A new transaction
   moves the money back, and the original row is untouched.
6. **Loans.** As Anjali (Janakpuri), approve Divya's pending loan 7004: the money is paid
   out and the installments are created. Meera can't see or approve it, because it belongs
   to another branch. As Divya, use *Pay next EMI* or *Repay full loan* (on the dashboard
   or the *Loans* page). Karan's loan 7003 shows a fully repaid (Closed) loan.
7. **Overdue.** As Meera, open *Loans* and click *Run overdue check*. Rahul's installment
   3 (due 2026-11-05) becomes Overdue, next to installment 2 which is already overdue.
8. **Onboarding.** As Arjun, open *My branch* and add an employee. A temporary password is
   shown once. Log in as the new employee: they see only Dwarka's data and can change
   their name, phone and password on the *Profile* page.
9. **Audit.** Log in as Kiran. Every action above is in the audit log, with who did it
   and the old and new values. Priya's frozen account 5008 and the reversal of Divya's
   wrong deposit (9011 by 9012) are already in the sample data.

## Where each rule lives

| Rule | How it is enforced | File |
|---|---|---|
| No account without approved KYC | trigger `trg_accounts_before_insert` | 02_logic.sql |
| Daily limit ≤ account type's max | triggers `trg_accounts_before_insert/update` | 02_logic.sql |
| Balance never negative, amount > 0 | `CHECK` constraints | 01_schema.sql |
| Deposit has no source, withdrawal has no destination | `CHECK chk_txn_accounts` | 01_schema.sql |
| Transfer is all-or-nothing | `START TRANSACTION` … `COMMIT`, `ROLLBACK` in the error handler | `sp_transfer` |
| No deadlock when two transfers cross | lock the lower account_id first (`FOR UPDATE`) | `sp_transfer` |
| Same request can't be processed twice | `UNIQUE (idempotency_key)` | 01_schema.sql |
| Deposits/withdrawals need employee approval | inserted as `Pending`, balance changes only in `sp_review_transaction` | 02_logic.sql |
| Mistakes fixed by reversal, never deletion | `sp_reverse_transaction`, trigger `trg_txn_no_delete` | 02_logic.sql |
| Loan linked to the customer's own account | trigger `trg_loans_before_insert` | 02_logic.sql |
| Loan approval = payout + schedule | `sp_approve_loan` (WHILE loop creates installments) | 02_logic.sql |
| Repay whole loan, all-or-nothing | `sp_repay_loan` (pays each unpaid installment, then closes the loan) | 02_logic.sql |
| Staff only touch their own branch | branch check in `sp_review_transaction`, `sp_reverse_transaction`, `sp_approve_loan` + `WHERE branch_id = my branch` in app.py | 02_logic.sql, app.py |
| Manager adds staff only to own branch | `sp_add_employee` has no branch parameter: it uses the manager's branch | 02_logic.sql |
| Late installments flagged | `sp_mark_overdue` + daily `EVENT` | 02_logic.sql |
| Over-budget warning | `sp_check_budget` → notification | 02_logic.sql |
| Audit log written automatically | `AFTER UPDATE` triggers on kyc_records, accounts, loans, transactions | 02_logic.sql |
| Audit log can't be changed | triggers `trg_audit_no_update/delete` + no UPDATE/DELETE grant | 02_logic.sql, 04_access.sql |
| Each role gets only what it needs | roles + `GRANT` (incl. column-level) / `REVOKE` | 04_access.sql |
| A customer sees only their own data | website adds `WHERE customer_id = <logged-in user>` | app.py |

**Derived attributes** (calculated by views, never stored): `spent_this_month` and
`budget_remaining` (in `v_account_overview`), `outstanding_balance` (in
`v_loan_summary`), and `days_overdue` (in `v_overdue_installments`).

**How a trigger knows who did something:** every time the website opens a connection
it runs `SET @app_user_id = <logged-in user id>` (see `db.py`), and the audit triggers
read `@app_user_id`. When testing in the MySQL terminal, run `SET @app_user_id = 201;` first.

## Loan installment formula

Each month the same share of the principal is repaid, and interest is charged on what is
still owed:

```
principal_part = principal / tenure_months
interest_part  = remaining principal × yearly rate / 12 / 100
```

For example, Rs 60,000 at 10.5% for 6 months gives a principal_part of 10,000 every month,
and interest of 525.00, then 437.50, then 350.00, and so on.

## Simplifications (on purpose)

- All loans use one interest rate (10.50%, the column default).
- There is no beneficiary (saved payee) feature: a transfer takes the destination
  account number directly.
- Sample balances are opening balances, so they are not the sum of the sample transactions.
- Statuses `Approved` and `Failed` are allowed in `transactions.status` (to match the
  report) but are not used. A failed transfer is rolled back and never saved.
- KYC review is not tied to a branch (a new customer has no account, so no branch yet).
  Any employee can review KYC; everything else is limited to the employee's own branch.
- A new employee's temporary password is shown once to the manager, who hands it over.
  Changing it after the first login is recommended but not forced.
