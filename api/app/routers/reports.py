"""Numbers for planning (brief questions 1 and 2) and the audit trail (question 5)."""

from datetime import datetime

from fastapi import APIRouter

from app.db import Conn, fetch_all

router = APIRouter()   # tags set per route: reports and audit show as separate groups in /docs


@router.get("/reports/material-quantities", tags=["reports"])
async def material_quantities(conn: Conn) -> list[dict]:
    """How much we have, and how much is usable: totals per material and colour, in base units
    (uL / ug / pcs). From the `v_material_quantities` view."""
    return await fetch_all(conn, "SELECT * FROM inventory.v_material_quantities ORDER BY material, dimension, light")


@router.get("/reports/expiring", tags=["reports"])
async def expiring(conn: Conn, days: int = 7) -> list[dict]:
    """Items that have expired or expire within `days`, and haven't been used up, discarded or shipped."""
    return await fetch_all(conn, """
        SELECT item_id, material, quantity, unit, expires_at, expired, light, in_vessel
        FROM inventory.v_item_status
        WHERE expires_at <= now() + make_interval(days => %s)
          AND NOT empty AND NOT discarded AND NOT shipped
        ORDER BY expires_at""", (days,))


@router.get("/audit/{table}/{key}", tags=["audit"])
async def history(table: str, key: str, conn: Conn, as_of: datetime | None = None) -> dict:
    """Every change to one record: who, why, old and new values (`audit.history()`).
    With `?as_of=...`, what the record said at that moment (`audit.as_of()`).
    Example: /audit/inventory.items/3"""
    if as_of:
        rows = await fetch_all(conn, "SELECT audit.as_of(%s, %s, %s) AS record", (table, key, as_of))
        return {"table": table, "key": key, "as_of": as_of, "record": rows[0]["record"]}
    return {"table": table, "key": key, "changes": await fetch_all(conn, "SELECT * FROM audit.history(%s, %s)", (table, key))}


@router.get("/audit/actions/{transaction_id}", tags=["audit"])
async def action(transaction_id: int, conn: Conn) -> list[dict]:
    """Everything one action changed, e.g. all wells of one plate transfer."""
    return await fetch_all(conn, "SELECT * FROM audit.log WHERE transaction_id = %s ORDER BY id", (transaction_id,))
