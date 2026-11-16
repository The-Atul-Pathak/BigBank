"""
app.py - BigBank website (Flask).

The website is deliberately thin. It shows pages and forwards the user's
actions to MySQL. Every banking rule (KYC before account, balance checks,
daily limit, audit log...) is enforced INSIDE the database by triggers and
stored procedures. If MySQL refuses something, the error handler below
shows MySQL's message to the user.

Run:  python app.py   then open http://127.0.0.1:5000
"""
import os
import uuid
from functools import wraps

import mysql.connector
from flask import Flask, flash, redirect, render_template, request, session, url_for
from werkzeug.security import check_password_hash, generate_password_hash

from db import call, close_db, execute, get_db, query, query_one

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY", "dev-only-change-me")  # signs the session cookie
app.teardown_appcontext(close_db)


# =====================================================================
# Helpers
# =====================================================================

def login_required(*roles):
    """Decorator: user must be logged in, and (if roles are given) have one of them."""
    def decorator(view):
        @wraps(view)
        def wrapped(*args, **kwargs):
            if "user_id" not in session:
                return redirect(url_for("login"))
            if roles and session["role"] not in roles:
                flash("You are not allowed to open that page.", "error")
                return redirect(url_for("home"))
            return view(*args, **kwargs)
        return wrapped
    return decorator


@app.errorhandler(mysql.connector.Error)
def handle_db_error(err):
    """MySQL refused something (e.g. a trigger or procedure ran SIGNAL).
    Show its message and send the user back to the page they came from."""
    if err.errno == 1062 and "idempotency_key" in err.msg:
        message = "This request was already submitted."
    elif err.errno == 1062 and "email" in err.msg:
        message = "This email is already registered."
    else:
        message = err.msg
    if request.method == "POST":
        flash(message, "error")
        return redirect(request.referrer or url_for("home"))
    return render_template("error.html", message=message), 500


@app.context_processor
def template_helpers():
    # new_key() puts a fresh idempotency key in every money form.
    # If the same form is submitted twice, the key repeats and the
    # UNIQUE constraint on transactions.idempotency_key rejects the copy.
    return {"new_key": lambda: uuid.uuid4().hex}


@app.template_filter("money")
def money(value):
    """Show 12345.5 as Rs 12,345.50 in templates:  {{ amount | money }}"""
    return "Rs {:,.2f}".format(value or 0)


# =====================================================================
# Login / register / logout
# =====================================================================

@app.route("/")
def home():
    """Send each user to the start page for their role."""
    role = session.get("role")
    if role is None:
        return redirect(url_for("login"))
    if role == "Customer":
        return redirect(url_for("customer_home"))
    if role in ("Employee", "BranchManager"):
        return redirect(url_for("staff_home"))
    return redirect(url_for("audit_log"))  # Auditor


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        # LEFT JOIN: staff have a row in employees (with their branch), others get NULL.
        user = query_one(
            "SELECT u.user_id, u.name, u.password_hash, u.role, e.branch_id "
            "FROM users u LEFT JOIN employees e ON e.user_id = u.user_id "
            "WHERE u.email = %s",
            (request.form["email"].strip().lower(),),
        )
        if user and check_password_hash(user["password_hash"], request.form["password"]):
            session.clear()
            session["user_id"] = user["user_id"]
            session["name"] = user["name"]
            session["role"] = user["role"]
            session["branch_id"] = user["branch_id"]   # None for customers and the auditor
            return redirect(url_for("home"))
        flash("Wrong email or password.", "error")
    return render_template("login.html")


@app.route("/register", methods=["GET", "POST"])
def register():
    """New customers sign up here (staff accounts are created by the bank)."""
    if request.method == "POST":
        f = request.form
        password_hash = generate_password_hash(f["password"], method="pbkdf2:sha256")

        # Two INSERTs that must succeed or fail together -> one DB transaction.
        db = get_db()
        db.start_transaction()
        try:
            user_id = execute(
                "INSERT INTO users (name, email, phone, password_hash, role) "
                "VALUES (%s, %s, %s, %s, 'Customer')",
                (f["name"], f["email"].strip().lower(), f["phone"], password_hash),
            )
            execute(
                "INSERT INTO customers (user_id, dob, address) VALUES (%s, %s, %s)",
                (user_id, f["dob"], f["address"]),
            )
            db.commit()
        except mysql.connector.Error:
            db.rollback()
            raise

        flash("Account created. Please log in.", "success")
        return redirect(url_for("login"))
    return render_template("register.html")


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


# =====================================================================
# CUSTOMER pages
# Every query here has "customer_id = session user" in its WHERE clause,
# so a customer can only ever see their own data.
# =====================================================================

def my_account(account_id):
    """Return the account only if it belongs to the logged-in customer."""
    return query_one(
        "SELECT * FROM v_account_overview WHERE account_id = %s AND customer_id = %s",
        (account_id, session["user_id"]),
    )


@app.route("/customer")
@login_required("Customer")
def customer_home():
    uid = session["user_id"]
    customer = query_one("SELECT kyc_status FROM customers WHERE user_id = %s", (uid,))
    latest_kyc = query_one(
        "SELECT * FROM kyc_records WHERE customer_id = %s ORDER BY kyc_id DESC LIMIT 1", (uid,)
    )
    accounts = query(
        "SELECT * FROM v_account_overview WHERE customer_id = %s ORDER BY account_id", (uid,)
    )
    notifications = query(
        "SELECT * FROM notifications WHERE user_id = %s "
        "ORDER BY created_at DESC, notification_id DESC LIMIT 10",
        (uid,),
    )
    loans = query(
        "SELECT * FROM v_loan_summary WHERE customer_id = %s AND status IN ('Requested', 'Active') "
        "ORDER BY loan_id",
        (uid,),
    )
    return render_template(
        "customer_home.html",
        customer=customer, latest_kyc=latest_kyc,
        accounts=accounts, notifications=notifications, loans=loans,
    )


@app.route("/kyc", methods=["POST"])
@login_required("Customer")
def submit_kyc():
    uid = session["user_id"]
    waiting = query_one(
        "SELECT kyc_id FROM kyc_records WHERE customer_id = %s AND status IN ('Pending', 'Approved')",
        (uid,),
    )
    if waiting:
        flash("Your KYC is already submitted or approved.", "error")
        return redirect(url_for("customer_home"))

    execute(
        "INSERT INTO kyc_records (customer_id, doc_type, doc_ref) VALUES (%s, %s, %s)",
        (uid, request.form["doc_type"], request.form["doc_ref"]),
    )
    execute("UPDATE customers SET kyc_status = 'Pending' WHERE user_id = %s", (uid,))
    flash("KYC submitted. An employee will review it.", "success")
    return redirect(url_for("customer_home"))


@app.route("/notifications/read", methods=["POST"])
@login_required()
def mark_notifications_read():
    execute("UPDATE notifications SET is_read = TRUE WHERE user_id = %s", (session["user_id"],))
    return redirect(request.referrer or url_for("home"))


@app.route("/accounts/open", methods=["GET", "POST"])
@login_required("Customer")
def open_account():
    if request.method == "POST":
        f = request.form
        # The trigger trg_accounts_before_insert refuses this INSERT if KYC
        # is not approved or the daily limit is too high.
        new_id = execute(
            "INSERT INTO accounts (customer_id, branch_id, account_type_id, daily_limit, spending_budget) "
            "VALUES (%s, %s, %s, %s, %s)",
            (session["user_id"], f["branch_id"], f["account_type_id"],
             f["daily_limit"], f["spending_budget"] or None),
        )
        flash(f"Account {new_id} opened.", "success")
        return redirect(url_for("account_detail", account_id=new_id))

    account_types = query("SELECT * FROM account_types ORDER BY account_type_id")
    branches = query("SELECT * FROM branches ORDER BY branch_id")
    return render_template("open_account.html", account_types=account_types, branches=branches)


@app.route("/accounts/<int:account_id>")
@login_required("Customer")
def account_detail(account_id):
    account = my_account(account_id)
    if account is None:
        flash("Account not found.", "error")
        return redirect(url_for("customer_home"))

    # Statement: every transaction where this account is the source or the destination
    statement = query(
        "SELECT *, IF(destination_account_id = %s, 'Credit', 'Debit') AS direction "
        "FROM transactions "
        "WHERE source_account_id = %s OR destination_account_id = %s "
        "ORDER BY created_at DESC, transaction_id DESC",
        (account_id, account_id, account_id),
    )
    return render_template("account.html", account=account, statement=statement)


@app.route("/accounts/<int:account_id>/settings", methods=["POST"])
@login_required("Customer")
def account_settings(account_id):
    if my_account(account_id) is None:
        flash("Account not found.", "error")
        return redirect(url_for("customer_home"))

    execute(
        "UPDATE accounts SET daily_limit = %s, spending_budget = %s "
        "WHERE account_id = %s AND customer_id = %s",
        (request.form["daily_limit"], request.form["spending_budget"] or None,
         account_id, session["user_id"]),
    )
    flash("Limits saved.", "success")
    return redirect(url_for("account_detail", account_id=account_id))


@app.route("/money")
@login_required("Customer")
def money_page():
    uid = session["user_id"]
    accounts = query(
        "SELECT * FROM v_account_overview WHERE customer_id = %s AND status = 'Active' "
        "ORDER BY account_id",
        (uid,),
    )
    my_requests = query(
        "SELECT * FROM transactions "
        "WHERE initiated_by_user_id = %s AND type IN ('Deposit', 'Withdrawal') "
        "ORDER BY created_at DESC, transaction_id DESC LIMIT 10",
        (uid,),
    )
    return render_template("money.html", accounts=accounts, my_requests=my_requests)


@app.route("/transfer", methods=["POST"])
@login_required("Customer")
def transfer():
    f = request.form
    # All checks (owner, Active, balance, daily limit, duplicate key) happen
    # inside the procedure, in one all-or-nothing database transaction.
    call("sp_transfer", (session["user_id"], int(f["from_account"]), int(f["to_account"]),
                         f["amount"], f["key"]))
    flash("Transfer successful.", "success")
    return redirect(url_for("money_page"))


@app.route("/cash-request", methods=["POST"])
@login_required("Customer")
def cash_request():
    """A deposit or withdrawal is only a REQUEST. It stays 'Pending' and does
    not touch the balance until an employee approves it."""
    f = request.form
    account_id = int(f["account_id"])
    if my_account(account_id) is None:
        flash("Account not found.", "error")
        return redirect(url_for("money_page"))

    if f["type"] == "Deposit":
        source, destination = None, account_id
    else:
        source, destination = account_id, None

    execute(
        "INSERT INTO transactions (source_account_id, destination_account_id, "
        "initiated_by_user_id, type, amount, idempotency_key) "
        "VALUES (%s, %s, %s, %s, %s, %s)",
        (source, destination, session["user_id"], f["type"], f["amount"], f["key"]),
    )
    flash(f"{f['type']} request sent. An employee will approve it.", "success")
    return redirect(url_for("money_page"))


@app.route("/loans")
@login_required("Customer")
def my_loans():
    uid = session["user_id"]
    loans = query("SELECT * FROM v_loan_summary WHERE customer_id = %s ORDER BY loan_id DESC", (uid,))
    accounts = query(
        "SELECT * FROM v_account_overview WHERE customer_id = %s AND status = 'Active'", (uid,)
    )
    return render_template("loans.html", loans=loans, accounts=accounts)


@app.route("/loans/apply", methods=["POST"])
@login_required("Customer")
def apply_loan():
    # interest_rate is not sent: the column DEFAULT (10.50) is used.
    # trg_loans_before_insert makes sure the linked account is the customer's own.
    loan_id = execute(
        "INSERT INTO loans (customer_id, linked_account_id, principal, tenure_months) "
        "VALUES (%s, %s, %s, %s)",
        (session["user_id"], request.form["linked_account_id"],
         request.form["principal"], request.form["tenure_months"]),
    )
    flash(f"Loan {loan_id} requested. An employee will review it.", "success")
    return redirect(url_for("my_loans"))


@app.route("/loans/<int:loan_id>")
@login_required("Customer")
def loan_detail(loan_id):
    loan = query_one(
        "SELECT * FROM v_loan_summary WHERE loan_id = %s AND customer_id = %s",
        (loan_id, session["user_id"]),
    )
    if loan is None:
        flash("Loan not found.", "error")
        return redirect(url_for("my_loans"))
    installments = query(
        "SELECT *, principal_part + interest_part AS emi FROM loan_installments "
        "WHERE loan_id = %s ORDER BY installment_no",
        (loan_id,),
    )
    return render_template("loan.html", loan=loan, installments=installments)


@app.route("/loans/<int:loan_id>/pay/<int:installment_no>", methods=["POST"])
@login_required("Customer")
def pay_installment(loan_id, installment_no):
    call("sp_pay_installment", (session["user_id"], loan_id, installment_no))
    flash(f"Installment {installment_no} paid.", "success")
    return redirect(request.referrer or url_for("loan_detail", loan_id=loan_id))


@app.route("/loans/<int:loan_id>/repay", methods=["POST"])
@login_required("Customer")
def repay_loan(loan_id):
    """Pay every remaining installment now and close the loan."""
    call("sp_repay_loan", (session["user_id"], loan_id))
    flash(f"Loan {loan_id} fully repaid and closed.", "success")
    return redirect(request.referrer or url_for("loan_detail", loan_id=loan_id))


# =====================================================================
# EMPLOYEE pages (branch managers can use them too)
#
# Staff only see and act on THEIR OWN BRANCH: every query below has
# "branch_id = my branch" in it. The stored procedures check the branch
# again, so typing another account's id into the URL does not help.
#
# KYC is the one exception: a new customer has no account yet, so they do
# not belong to any branch. Any employee can review KYC.
# =====================================================================
STAFF = ("Employee", "BranchManager")


def my_branch():
    """The branch of the logged-in employee or manager (saved at login)."""
    return session["branch_id"]


@app.route("/staff")
@login_required(*STAFF)
def staff_home():
    """The employee's work queue: everything waiting for a decision."""
    pending_kyc = query(
        "SELECT k.*, u.name FROM kyc_records k "
        "JOIN users u ON u.user_id = k.customer_id "
        "WHERE k.status = 'Pending' ORDER BY k.submitted_at"
    )
    # A deposit/withdrawal touches one account: the source OR the destination.
    pending_txns = query(
        "SELECT t.*, u.name FROM transactions t "
        "JOIN users u    ON u.user_id = t.initiated_by_user_id "
        "JOIN accounts a ON a.account_id = COALESCE(t.source_account_id, t.destination_account_id) "
        "WHERE t.status = 'Pending' AND a.branch_id = %s "
        "ORDER BY t.created_at",
        (my_branch(),),
    )
    pending_loans = query(
        "SELECT * FROM v_loan_summary WHERE status = 'Requested' AND branch_id = %s "
        "ORDER BY requested_at",
        (my_branch(),),
    )
    return render_template(
        "staff_home.html",
        pending_kyc=pending_kyc, pending_txns=pending_txns, pending_loans=pending_loans,
    )


@app.route("/staff/kyc/<int:kyc_id>", methods=["POST"])
@login_required(*STAFF)
def review_kyc(kyc_id):
    # The trigger trg_kyc_after_update then copies the decision to
    # customers.kyc_status, writes the audit log and notifies the customer.
    execute(
        "UPDATE kyc_records SET status = %s, reviewed_by_employee_id = %s, remarks = %s "
        "WHERE kyc_id = %s AND status = 'Pending'",
        (request.form["decision"], session["user_id"], request.form["remarks"] or None, kyc_id),
    )
    flash(f"KYC {kyc_id} marked {request.form['decision']}.", "success")
    return redirect(url_for("staff_home"))


@app.route("/staff/transactions/<int:txn_id>/review", methods=["POST"])
@login_required(*STAFF)
def review_transaction(txn_id):
    decision = request.form["decision"]  # 'Approve' or 'Reject'
    call("sp_review_transaction", (session["user_id"], txn_id, decision))
    result = "approved" if decision == "Approve" else "rejected"
    flash(f"Transaction {txn_id} {result}.", "success")
    return redirect(url_for("staff_home"))


@app.route("/staff/accounts")
@login_required(*STAFF)
def staff_accounts():
    accounts = query(
        "SELECT * FROM v_account_overview WHERE branch_id = %s ORDER BY account_id",
        (my_branch(),),
    )
    return render_template("staff_accounts.html", accounts=accounts)


@app.route("/staff/accounts/<int:account_id>/status", methods=["POST"])
@login_required(*STAFF)
def set_account_status(account_id):
    in_my_branch = query_one(
        "SELECT account_id FROM accounts WHERE account_id = %s AND branch_id = %s",
        (account_id, my_branch()),
    )
    if in_my_branch is None:
        flash("Account not found in your branch.", "error")
        return redirect(url_for("staff_accounts"))

    # trg_accounts_after_update writes the audit log and tells the customer.
    status = request.form["status"]  # 'Active' or 'Frozen'
    execute("UPDATE accounts SET status = %s WHERE account_id = %s", (status, account_id))
    flash(f"Account {account_id} is now {status}.", "success")
    return redirect(url_for("staff_accounts"))


@app.route("/staff/transactions")
@login_required(*STAFF)
def staff_transactions():
    # Self-join: for each transaction, find the row that reversed it (if any).
    # EXISTS: keep transactions where the source OR destination is in my branch.
    transactions = query(
        "SELECT t.*, r.transaction_id AS reversed_by "
        "FROM transactions t "
        "LEFT JOIN transactions r ON r.reversal_of_transaction_id = t.transaction_id "
        "WHERE EXISTS (SELECT 1 FROM accounts a WHERE a.branch_id = %s "
        "              AND a.account_id IN (t.source_account_id, t.destination_account_id)) "
        "ORDER BY t.transaction_id DESC LIMIT 50",
        (my_branch(),),
    )
    return render_template("staff_transactions.html", transactions=transactions)


@app.route("/staff/transactions/<int:txn_id>/reverse", methods=["POST"])
@login_required(*STAFF)
def reverse_transaction(txn_id):
    call("sp_reverse_transaction", (session["user_id"], txn_id))
    flash(f"Transaction {txn_id} reversed.", "success")
    return redirect(url_for("staff_transactions"))


@app.route("/staff/loans/<int:loan_id>", methods=["POST"])
@login_required(*STAFF)
def review_loan(loan_id):
    if request.form["decision"] == "Approve":
        # Pays out the money and creates the installments, all in one transaction.
        call("sp_approve_loan", (session["user_id"], loan_id))
        flash(f"Loan {loan_id} approved and paid out.", "success")
    else:
        in_my_branch = query_one(
            "SELECT loan_id FROM v_loan_summary WHERE loan_id = %s AND branch_id = %s",
            (loan_id, my_branch()),
        )
        if in_my_branch is None:
            flash("Loan not found in your branch.", "error")
            return redirect(url_for("staff_home"))
        execute(
            "UPDATE loans SET status = 'Rejected', reviewed_by_employee_id = %s "
            "WHERE loan_id = %s AND status = 'Requested'",
            (session["user_id"], loan_id),
        )
        flash(f"Loan {loan_id} rejected.", "success")
    return redirect(url_for("staff_home"))


@app.route("/staff/loans")
@login_required(*STAFF)
def staff_loans():
    loans = query(
        "SELECT * FROM v_loan_summary WHERE branch_id = %s ORDER BY loan_id DESC",
        (my_branch(),),
    )
    overdue = query(
        "SELECT * FROM v_overdue_installments WHERE branch_id = %s ORDER BY days_overdue DESC",
        (my_branch(),),
    )
    return render_template("staff_loans.html", loans=loans, overdue=overdue)


@app.route("/staff/loans/mark-overdue", methods=["POST"])
@login_required(*STAFF)
def mark_overdue():
    # The same procedure also runs automatically every day (MySQL EVENT).
    call("sp_mark_overdue")
    flash("Overdue check done.", "success")
    return redirect(url_for("staff_loans"))


# =====================================================================
# BRANCH MANAGER page
# =====================================================================

@app.route("/manager")
@login_required("BranchManager")
def branch_summary():
    branch = query_one("SELECT * FROM v_branch_summary WHERE branch_id = %s", (my_branch(),))
    # Self-join on users: the manager_employee_id column points back to employees
    # (recursive relationship), so we join users twice to get both names.
    staff = query(
        "SELECT e.user_id, u.name, u.email, e.designation, m.name AS manager_name "
        "FROM employees e "
        "JOIN users u ON u.user_id = e.user_id "
        "LEFT JOIN users m ON m.user_id = e.manager_employee_id "
        "WHERE e.branch_id = %s "
        "ORDER BY e.manager_employee_id IS NOT NULL, u.name",
        (my_branch(),),
    )
    return render_template("manager.html", branch=branch, staff=staff)


# =====================================================================
# AUDITOR page (read-only)
# =====================================================================

@app.route("/audit")
@login_required("Auditor")
def audit_log():
    table = request.args.get("table", "")
    logs = query(
        "SELECT a.*, u.name AS actor_name, u.role AS actor_role "
        "FROM audit_logs a JOIN users u ON u.user_id = a.actor_user_id "
        "WHERE %s = '' OR a.table_name = %s "
        "ORDER BY a.logged_at DESC, a.log_id DESC LIMIT 200",
        (table, table),
    )
    return render_template("audit.html", logs=logs, table=table)


if __name__ == "__main__":
    app.run(debug=True)
