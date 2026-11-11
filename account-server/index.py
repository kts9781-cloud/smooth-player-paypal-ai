"""Vercel's FastAPI entrypoint. Configuration contains no embedded credentials."""
from smooth_accounts.app import create_app

app = create_app()
