"""Filed batches: transfer runs that failed and are waiting for a person to decide.

Resolving one triggers a database function:
    inventory.apply_transfer_batch()    re-checks EVERY line via inventory.transfer(), all or nothing
    inventory.reject_transfer_batch()   applies nothing
Both clear the pending_review flags.
"""

import logging

from fastapi import APIRouter, HTTPException
from psycopg import sql

from app.db import Conn, fetch_all, fetch_one_or_404
from app.schemas import BatchLineFixIn, ResolveIn

router = APIRouter(prefix="/batches", tags=["batches"])
log = logging.getLogger("uvicorn.error")


@router.get("")
async def list_batches(conn: Conn, pending: bool | None = None) -> list[dict]:
    """All filed batches, newest first. `?pending=true` for the ones still waiting on a decision."""
    return await fetch_all(conn, """
        SELECT * FROM inventory.transfer_batches
        WHERE %s::boolean IS NULL OR (NOT applied AND NOT rejected) = %s
        ORDER BY id DESC""", (pending, pending))


@router.get("/{batch_id}")
async def get_batch(batch_id: int, conn: Conn) -> dict:
    """A filed batch and its lines, with each line's first-attempt result and reason."""
    batch = await fetch_one_or_404(conn, "SELECT * FROM inventory.transfer_batches WHERE id = %s",
                                   (batch_id,), f"Batch {batch_id} not found")
    lines = await fetch_all(conn, "SELECT * FROM inventory.transfer_batch_lines WHERE batch_id = %s ORDER BY line_no",
                            (batch_id,))
    return {**batch, "lines": lines}


@router.patch("/{batch_id}/lines/{line_no}")
async def fix_line(batch_id: int, line_no: int, body: BatchLineFixIn, conn: Conn) -> dict:
    """Correct a line before applying (e.g. the real volume, or the right item after a wrong scan).
    Plain UPDATE, recorded by the audit log. Nothing is applied until `/apply`."""
    batch = await fetch_one_or_404(conn, "SELECT applied, rejected FROM inventory.transfer_batches WHERE id = %s",
                                   (batch_id,), f"Batch {batch_id} not found")
    if batch["applied"] or batch["rejected"]:
        raise HTTPException(409, f"Batch {batch_id} is already resolved")

    changes = body.model_dump(exclude_unset=True)
    columns = {"parent_item": "parent_item", "amount": "amount", "unit": "unit",
               "to_vessel_id": "to_vessel", "to_item_id": "to_item"}
    updates = {columns[k]: v for k, v in changes.items()}
    # A line has one target: setting one clears the other.
    if "to_vessel" in updates:
        updates.setdefault("to_item", None)
    if "to_item" in updates:
        updates.setdefault("to_vessel", None)
    if not updates:
        raise HTTPException(422, "Nothing to change")

    # sql.Identifier quotes column names safely; values still go in as %s parameters.
    query = sql.SQL("UPDATE inventory.transfer_batch_lines SET {} WHERE batch_id = %s AND line_no = %s RETURNING *").format(
        sql.SQL(", ").join(sql.SQL("{} = %s").format(sql.Identifier(c)) for c in updates))
    return await fetch_one_or_404(conn, query, (*updates.values(), batch_id, line_no),
                                  f"Batch {batch_id} has no line {line_no}")


@router.post("/{batch_id}/apply")
async def apply_batch(batch_id: int, conn: Conn, only_ok: bool = False, body: ResolveIn | None = None) -> dict:
    """Apply a filed batch.

    **Triggers `inventory.apply_transfer_batch()`**: every line goes through `inventory.transfer()`
    AGAIN, against the inventory as it is now. Still all or nothing: if a line fails -> 422
    ("Batch 3, line 2: ...") and the batch stays pending.
    `?only_ok=true` applies only the lines that succeeded the first time; failed lines stay on record.
    """
    log.info("calling inventory.apply_transfer_batch(%s, only_ok=%s)", batch_id, only_ok)
    rows = await fetch_all(conn, "SELECT * FROM inventory.apply_transfer_batch(%s, p_only_ok => %s, p_note => %s)",
                           (batch_id, only_ok, body.note if body else None))
    return {"batch": batch_id, "applied": True, "lines": rows}


@router.post("/{batch_id}/reject")
async def reject_batch(batch_id: int, conn: Conn, body: ResolveIn | None = None) -> dict:
    """Reject a filed batch: nothing is applied, flags are cleared.

    **Triggers `inventory.reject_transfer_batch()`.**
    """
    log.info("calling inventory.reject_transfer_batch(%s)", batch_id)
    await conn.execute("SELECT inventory.reject_transfer_batch(%s, %s)", (batch_id, body.note if body else None))
    return {"batch": batch_id, "rejected": True}
