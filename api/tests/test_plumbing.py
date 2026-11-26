"""Tests for the skeleton's plumbing, using a small throwaway app with test-only routes:
  * database rule failures become the right HTTP status, with the database's message
  * a request is one transaction: if it fails, none of its writes are kept
  * the acting user and context reach the audit log
"""

import pytest
from fastapi import FastAPI

from app import errors
from app.db import Conn
from app.errors import status_for


def make_test_app() -> FastAPI:
    app = FastAPI()
    errors.register(app)

    @app.post("/_test/storage-units/{barcode}")
    async def create_unit(barcode: str, conn: Conn):
        await conn.execute(
            "INSERT INTO inventory.storage_unit (barcode, kind) VALUES (%s, 'freezer')", (barcode,)
        )
        return {"barcode": barcode}

    @app.post("/_test/create-then-fail/{barcode}")
    async def create_then_fail(barcode: str, conn: Conn):
        await conn.execute(
            "INSERT INTO inventory.storage_unit (barcode, kind) VALUES (%s, 'freezer')", (barcode,)
        )
        # A rule failure AFTER a successful write: item 9999 doesn't exist.
        await conn.execute("SELECT inventory.transfer(9999, 1, 'uL', p_to_vessel => 1)")

    return app


@pytest.fixture
async def test_client(make_client):
    async with make_client(make_test_app()) as c:
        yield c


@pytest.mark.parametrize(
    ("sqlstate", "status"),
    [("P0001", 422), ("23505", 409), ("23514", 422), ("23503", 422), ("XX000", 500), (None, 500)],
)
def test_status_mapping(sqlstate, status):
    assert status_for(sqlstate) == status


async def test_duplicate_is_409_with_database_detail(test_client):
    assert (await test_client.post("/_test/storage-units/FRZ-1")).status_code == 200
    r = await test_client.post("/_test/storage-units/FRZ-1")
    assert r.status_code == 409
    assert r.json()["sqlstate"] == "23505"
    assert "FRZ-1" in r.json()["detail"]


async def test_failed_request_keeps_none_of_its_writes(test_client, conn):
    r = await test_client.post("/_test/create-then-fail/FRZ-2")
    assert r.status_code == 422
    assert r.json()["error"] == "Item 9999 does not exist"

    cur = await conn.execute("SELECT count(*) AS n FROM inventory.storage_unit WHERE barcode = 'FRZ-2'")
    assert (await cur.fetchone())["n"] == 0   # the INSERT before the failure was rolled back


async def test_user_and_context_reach_the_audit_log(test_client, conn):
    cur = await conn.execute(
        "INSERT INTO users (username, password_hash) VALUES ('tester', 'x') RETURNING id"
    )
    user_id = (await cur.fetchone())["id"]

    r = await test_client.post("/_test/storage-units/FRZ-3", headers={"X-User-Id": str(user_id)})
    assert r.status_code == 200

    cur = await conn.execute(
        "SELECT changed_by, context, action FROM audit.history('inventory.storage_unit', 'FRZ-3')"
    )
    assert await cur.fetchall() == [
        {"changed_by": user_id, "context": "POST /_test/storage-units/FRZ-3", "action": "INSERT"}
    ]
