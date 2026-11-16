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
    return render_template("home.html")


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        user = query_one(
            "SELECT user_id, name, password_hash, role FROM users WHERE email = %s",
            (request.form["email"].strip().lower(),),
        )
        if user and check_password_hash(user["password_hash"], request.form["password"]):
            session.clear()
            session["user_id"] = user["user_id"]
            session["name"] = user["name"]
            session["role"] = user["role"]
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
    return render_template(
        "customer_home.html",
        customer=customer, latest_kyc=latest_kyc,
        accounts=accounts, notifications=notifications,
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


if __name__ == "__main__":
    app.run(debug=True)
