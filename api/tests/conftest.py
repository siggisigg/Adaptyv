"""Test setup: every test runs against the real database, inside a transaction that is
always rolled back. Tests can't leave data behind or see each other's data.

Run inside the api container:  docker compose exec api pytest -v
"""

from typing import Annotated

import pytest
from fastapi import FastAPI, Header, Request
from httpx import ASGITransport, AsyncClient
from psycopg import AsyncConnection
from psycopg.rows import dict_row

from app.db import DATABASE_URL, get_conn, start_request
from app.main import app as main_app


@pytest.fixture
async def conn():
    """One connection per test, in a transaction that is rolled back at the end, whatever happens."""
    async with await AsyncConnection.connect(DATABASE_URL, row_factory=dict_row) as c:
        async with c.transaction(force_rollback=True):
            yield c


@pytest.fixture
def override_get_conn(conn):
    """Replacement for get_conn(): uses the test's connection instead of the pool.

    Each request gets a SAVEPOINT (a nested transaction) instead of a real transaction, so a
    request that fails rolls back only its own work, just like in production, and the test
    can carry on and inspect the database afterwards.
    """

    async def _get_conn(request: Request, x_user_id: Annotated[int | None, Header()] = None):
        async with conn.transaction():   # nested inside the test transaction = a savepoint
            await start_request(conn, request, x_user_id)
            yield conn

    return _get_conn


@pytest.fixture
def make_client(override_get_conn):
    """Build an HTTP client for any FastAPI app, wired to the test connection."""

    def _make(app: FastAPI) -> AsyncClient:
        app.dependency_overrides[get_conn] = override_get_conn
        return AsyncClient(transport=ASGITransport(app=app), base_url="http://test")

    return _make


@pytest.fixture
async def client(make_client):
    """Client for the real application."""
    async with make_client(main_app) as c:
        yield c
    main_app.dependency_overrides.clear()
