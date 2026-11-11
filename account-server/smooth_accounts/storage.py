import sqlite3
from contextlib import contextmanager


SCHEMA = """
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY,email TEXT UNIQUE NOT NULL,created INTEGER NOT NULL,deleted INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS challenges(id TEXT PRIMARY KEY,email TEXT NOT NULL,digest TEXT NOT NULL,expires INTEGER NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,used INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS rate_limits(bucket TEXT PRIMARY KEY,count INTEGER NOT NULL,expires INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS sessions(digest TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),expires INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS purchases(provider TEXT NOT NULL,reference TEXT NOT NULL,user_id TEXT NOT NULL REFERENCES users(id),product TEXT NOT NULL,active INTEGER NOT NULL,expires INTEGER,proof TEXT NOT NULL,checked INTEGER NOT NULL,PRIMARY KEY(provider,reference));
CREATE TABLE IF NOT EXISTS orders(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),product TEXT NOT NULL,amount INTEGER NOT NULL,status TEXT NOT NULL,created INTEGER NOT NULL,payment_key TEXT UNIQUE,subscription_id TEXT,cycle INTEGER);
CREATE TABLE IF NOT EXISTS subscriptions(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),billing_key TEXT NOT NULL,amount INTEGER NOT NULL,next_due INTEGER NOT NULL,cancelled INTEGER NOT NULL DEFAULT 0,created INTEGER NOT NULL);
CREATE UNIQUE INDEX IF NOT EXISTS subscription_cycle ON orders(subscription_id,cycle) WHERE subscription_id IS NOT NULL;
CREATE TABLE IF NOT EXISTS billing_auth(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),created INTEGER NOT NULL,used INTEGER NOT NULL DEFAULT 0,amount INTEGER NOT NULL,auth_digest TEXT);
CREATE TABLE IF NOT EXISTS billing_products(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),product TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS complimentary_grants(user_id TEXT PRIMARY KEY REFERENCES users(id),code_digest TEXT NOT NULL,created INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS checkout_consents(order_id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),terms_version TEXT NOT NULL,amount INTEGER NOT NULL,accepted_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS account_deletions(user_id TEXT PRIMARY KEY REFERENCES users(id),deleted_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS pending_payment_checks(order_id TEXT PRIMARY KEY,checked INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS nas_sync(user_id TEXT PRIMARY KEY REFERENCES users(id),state TEXT NOT NULL,updated INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS social_identities(provider TEXT NOT NULL,subject TEXT NOT NULL,user_id TEXT NOT NULL REFERENCES users(id),revoke_token TEXT NOT NULL,created INTEGER NOT NULL,PRIMARY KEY(provider,subject),UNIQUE(user_id,provider));
CREATE TABLE IF NOT EXISTS social_attempts(id TEXT PRIMARY KEY,state_digest TEXT UNIQUE NOT NULL,provider TEXT NOT NULL,challenge TEXT NOT NULL,owner_id TEXT REFERENCES users(id),created INTEGER NOT NULL,expires INTEGER NOT NULL,status TEXT NOT NULL,browser_digest TEXT NOT NULL,payload TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS social_revocations(id TEXT PRIMARY KEY,provider TEXT NOT NULL,token TEXT NOT NULL,created INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS social_deleted_identities(digest TEXT PRIMARY KEY,deleted INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS paypal_orders(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),product TEXT NOT NULL,amount INTEGER NOT NULL,currency TEXT NOT NULL,created INTEGER NOT NULL,status TEXT NOT NULL,provider_order TEXT UNIQUE,capture_id TEXT UNIQUE,expires INTEGER,checked INTEGER NOT NULL DEFAULT 0,terms_version TEXT NOT NULL);
"""


class Database:
    def __init__(self, path):
        self.path = path
        self.postgres = path.startswith(("postgres://", "postgresql://"))
        if self.postgres:
            with self.transaction() as db:
                for statement in SCHEMA.replace("PRAGMA journal_mode=WAL;", "").replace("INTEGER", "BIGINT").split(";"):
                    if statement.strip():
                        db.execute(statement)
            return
        db = self.connect()
        try:
            db.executescript(SCHEMA)
        finally:
            db.close()

    def connect(self):
        if self.postgres:
            return PostgresConnection(self.path)
        db = sqlite3.connect(self.path, timeout=20)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        return db

    @contextmanager
    def transaction(self):
        db = self.connect()
        try:
            if self.postgres:
                # Match the short, serial SQLite write transactions across all
                # function instances. Never hold this lock during provider I/O.
                db.execute("SELECT pg_advisory_xact_lock(1936744812, 1)")
            else:
                db.execute("BEGIN IMMEDIATE")
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    def one(self, sql, args=()):
        db = self.connect()
        try:
            return db.execute(sql, args).fetchone()
        finally:
            db.close()

    def all(self, sql, args=()):
        db = self.connect()
        try:
            return db.execute(sql, args).fetchall()
        finally:
            db.close()


class DatabaseRow(dict):
    """Keep sqlite3.Row's named and positional access for the shared service."""
    def __getitem__(self, key):
        return tuple(self.values())[key] if isinstance(key, int) else super().__getitem__(key)


def row_factory(cursor):
    names = [column.name for column in cursor.description] if cursor.description else []
    return lambda values: DatabaseRow(zip(names, values))


class PostgresConnection:
    def __init__(self, dsn):
        import psycopg
        self.connection = psycopg.connect(dsn, connect_timeout=10, row_factory=row_factory, prepare_threshold=None)
        self.connection.execute("SET statement_timeout = '25s'")
        self.connection.execute("SET lock_timeout = '20s'")
        self.connection.commit()

    def execute(self, sql, args=()):
        # Only application-owned SQL reaches this adapter. Values always remain
        # bound parameters, including strings containing '?' or SQL punctuation.
        if sql.lstrip().upper().startswith("INSERT OR IGNORE INTO"):
            sql = sql.replace("INSERT OR IGNORE INTO", "INSERT INTO", 1) + " ON CONFLICT DO NOTHING"
        # Translate our two scalar expressions, not SQL aggregate MIN/MAX.
        sql = sql.replace("MAX(next_due,?)", "GREATEST(next_due,?)")
        sql = sql.replace("MIN(checked,?)", "LEAST(checked,?)")
        return self.connection.execute(sql.replace("?", "%s"), args)

    def commit(self): self.connection.commit()
    def rollback(self): self.connection.rollback()
    def close(self): self.connection.close()
