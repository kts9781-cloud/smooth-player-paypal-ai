"""Serialize payment transitions on a durable SQLite host or PostgreSQL workers."""
import fcntl
import threading
from contextlib import contextmanager
from functools import wraps


class FinancialLock:
    def __init__(self, path):
        self.path = path + ".payments.lock"
        self.dsn = path if path.startswith(("postgres://", "postgresql://")) else None
        self.mutex = threading.RLock()
        self.local = threading.local()

    @contextmanager
    def acquire(self):
        with self.mutex:
            if getattr(self.local, "held", False):
                yield
                return
            if self.dsn:
                from .storage import PostgresConnection
                connection = PostgresConnection(self.dsn)
                try:
                    # Transaction-scoped advisory locks also work with transaction
                    # poolers. A lost process/connection releases the lock. Stable
                    # provider idempotency keys still protect the external charge.
                    connection.execute("SELECT pg_advisory_xact_lock(1936744812, 2)")
                    self.local.held = True
                    yield
                    connection.commit()
                finally:
                    self.local.held = False
                    connection.close()
                return
            with open(self.path, "a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                self.local.held = True
                try:
                    yield
                finally:
                    self.local.held = False
                    fcntl.flock(lock, fcntl.LOCK_UN)


def serialized(function):
    @wraps(function)
    def wrapper(self, *args, **kwargs):
        with self.financial_lock.acquire():
            return function(self, *args, **kwargs)
    return wrapper
