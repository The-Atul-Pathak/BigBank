"""
db.py - the only file that talks to MySQL.

It gives the rest of the app four small helpers:
    query(sql, params)      -> list of rows (each row is a dict)   for SELECT
    query_one(sql, params)  -> one row, or None                    for SELECT
    execute(sql, params)    -> id of the new row                   for INSERT / UPDATE
    call(name, args)        -> runs a stored procedure             for CALL
                               (returns the args, with OUT parameters filled in)

Always pass values through `params` (the %s placeholders). Never glue user
input into the SQL string, because that would allow SQL injection.
"""
import os

import mysql.connector
from flask import g, session

DB_CONFIG = {
    "host": os.environ.get("DB_HOST", "127.0.0.1"),
    "port": int(os.environ.get("DB_PORT", "3306")),
    "user": os.environ.get("DB_USER", "bigbank_app"),
    "password": os.environ.get("DB_PASSWORD", "bigbank123"),
    "database": "banking_system",
}


def get_db():
    """Open one connection per web request and keep it in Flask's `g`."""
    if "db" not in g:
        # autocommit=True: each plain INSERT/UPDATE is saved immediately.
        # The stored procedures run their own START TRANSACTION ... COMMIT.
        g.db = mysql.connector.connect(**DB_CONFIG, autocommit=True)

        # Tell the audit triggers who is logged in (see 02_logic.sql).
        cur = g.db.cursor()
        cur.execute("SET @app_user_id = %s", (session.get("user_id"),))
        cur.close()
    return g.db


def close_db(error=None):
    """Called by Flask at the end of every request."""
    db = g.pop("db", None)
    if db is not None:
        db.close()


def query(sql, params=()):
    cur = get_db().cursor(dictionary=True)
    cur.execute(sql, params)
    rows = cur.fetchall()
    cur.close()
    return rows


def query_one(sql, params=()):
    rows = query(sql, params)
    return rows[0] if rows else None


def execute(sql, params=()):
    cur = get_db().cursor()
    cur.execute(sql, params)
    new_id = cur.lastrowid
    cur.close()
    return new_id


def call(proc_name, args=()):
    """Run a stored procedure. Returns the arguments back, with any OUT
    parameters filled in by MySQL (e.g. the new id from sp_add_employee)."""
    cur = get_db().cursor()
    result = cur.callproc(proc_name, args)
    cur.close()
    return result
