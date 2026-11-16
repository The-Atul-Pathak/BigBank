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


# =====================================================================
# Login / register / logout
# =====================================================================

@app.route("/")
def home():
    if "user_id" not in session:
        return redirect(url_for("login"))
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


if __name__ == "__main__":
    app.run(debug=True)
