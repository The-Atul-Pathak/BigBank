"""
db.py - the only file that talks to the database (PostgreSQL, via psycopg).

It gives the rest of the app five small helpers:
    query(sql, params)      -> list of rows (each row is a dict)   for SELECT
    query_one(sql, params)  -> one row, or None                    for SELECT
    execute(sql, params)    -> id of the new row, if the SQL ends   for INSERT / UPDATE
                               with "RETURNING <id column>"
    call(name, args)        -> runs a stored procedure             for CALL
                               (returns a dict of its OUT parameters, or None)
    transaction()           -> "with transaction():" groups several statements
                               into one all-or-nothing database transaction

Always pass values through `params` (the %s placeholders). Never glue user
input into the SQL string, because that would allow SQL injection.

Connection settings come from environment variables:
    DATABASE_URL  e.g. postgres://user:pass@host:port/defaultdb?sslmode=require
or the separate DB_HOST / DB_PORT / DB_USER / DB_PASSWORD / DB_NAME.
DB_SSL_CA may hold the provider's CA certificate (PEM text); the server's
certificate is then verified (sslmode=verify-full).
"""
import os
import tempfile

import psycopg
from flask import g, session
from psycopg.rows import dict_row

DB_CONFIG = {
    "conninfo": os.environ.get("DATABASE_URL", ""),
    "host": os.environ.get("DB_HOST", "127.0.0.1"),
    "port": os.environ.get("DB_PORT", "5432"),
    "user": os.environ.get("DB_USER", "bigbank_app"),
    "password": os.environ.get("DB_PASSWORD", "bigbank123"),
    "dbname": os.environ.get("DB_NAME", "defaultdb"),
    # Work inside the banking_system schema, with Indian time for CURRENT_DATE etc.
    "options": "-c search_path=banking_system -c timezone=Asia/Kolkata",
    "connect_timeout": 10,
}
if DB_CONFIG["conninfo"]:
    # A full URL was given: it already holds host, port, user, password and dbname.
    for key in ("host", "port", "user", "password", "dbname"):
        del DB_CONFIG[key]

_ca_pem = os.environ.get("DB_SSL_CA")
if _ca_pem:
    _ca_file = os.path.join(tempfile.gettempdir(), "db-ca.pem")
    with open(_ca_file, "w") as f:
        f.write(_ca_pem.replace("\\n", "\n"))
    DB_CONFIG["sslrootcert"] = _ca_file
    DB_CONFIG["sslmode"] = "verify-full"


def get_db():
    """Open one connection per web request and keep it in Flask's `g`."""
    if "db" not in g:
        # autocommit=True: each plain INSERT/UPDATE is saved immediately,
        # and each CALL of a procedure is one all-or-nothing transaction.
        g.db = psycopg.connect(**DB_CONFIG, autocommit=True, row_factory=dict_row)

        # Tell the audit triggers who is logged in (see 02_logic.sql).
        user_id = session.get("user_id")
        g.db.execute("SELECT set_config('app.user_id', %s, false)",
                     ("" if user_id is None else str(user_id),))
    return g.db


def close_db(error=None):
    """Called by Flask at the end of every request."""
    db = g.pop("db", None)
    if db is not None:
        db.close()


def query(sql, params=()):
    with get_db().cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall()


def query_one(sql, params=()):
    rows = query(sql, params)
    return rows[0] if rows else None


def execute(sql, params=()):
    with get_db().cursor() as cur:
        cur.execute(sql, params)
        if cur.description:                       # the SQL had a RETURNING clause
            row = cur.fetchone()
            return next(iter(row.values())) if row else None
        return None


def call(proc_name, args=()):
    """Run a stored procedure. For OUT parameters pass None in their place;
    the result is a dict of the OUT values (e.g. {'p_new_user_id': 207})."""
    placeholders = ", ".join(["%s"] * len(args))
    with get_db().cursor() as cur:
        cur.execute(f"CALL {proc_name}({placeholders})", args)
        return cur.fetchone() if cur.description else None


def transaction():
    """Use as  `with transaction(): ...`  - commits at the end of the block,
    or rolls everything back if an error happens inside it."""
    return get_db().transaction()
