"""Transfers: the ONLY part of the API that moves material.

Every endpoint here does its work by calling one of these database functions, which hold all
the rules (enough left, units, red items, capacity, mixing, lineage, all-or-nothing):

    inventory.transfer()        one transfer             POST /transfers
    inventory.transfer_batch()  many, all or nothing     POST /transfers/batch
                                                         POST /plates/{barcode}/transfer

No endpoint changes items.quantity or item_lineage itself. Each call is logged
("calling inventory.transfer(...)"), visible with:  docker compose logs -f api
"""

import json
import logging
from decimal import Decimal

from fastapi import APIRouter, HTTPException
from fastapi.encoders import jsonable_encoder
from fastapi.responses import JSONResponse
from psycopg import AsyncConnection
from psycopg.types.json import Jsonb

from app.db import Conn, fetch_all, set_context
from app.schemas import BatchIn, PlateTransferIn, TransferIn

router = APIRouter(tags=["transfers"])
log = logging.getLogger("uvicorn.error")   # uvicorn's logger, so messages show in the API log


# --- the database calls ------------------------------------------------------

async def call_transfer(conn: AsyncConnection, t: TransferIn) -> int:
    log.info("calling inventory.transfer(parent=%s, %s %s, to_vessel=%s, to_item=%s)",
             t.parent_item, t.amount, t.unit, t.to_vessel_id, t.to_item_id)
    cur = await conn.execute(
        "SELECT inventory.transfer(%s, %s, %s, p_to_vessel => %s, p_to_item => %s, p_material => %s) AS child_item",
        (t.parent_item, t.amount, t.unit, t.to_vessel_id, t.to_item_id, t.material),
    )
    return (await cur.fetchone())["child_item"]


async def call_transfer_batch(conn: AsyncConnection, lines: list[dict]) -> list[dict]:
    """lines: [{"parent": id, "amount": n, "unit": "uL", "to_vessel": id | "to_item": id}, ...]"""
    log.info("calling inventory.transfer_batch(%d lines)", len(lines))
    # Decimal isn't JSON by default; send it as a string, the SQL casts it back to NUMERIC.
    payload = Jsonb(lines, dumps=lambda obj: json.dumps(obj, default=str))
    return await fetch_all(conn, "SELECT * FROM inventory.transfer_batch(%s)", (payload,))


def batch_response(rows: list[dict], dry_run: bool, extra: dict | None = None) -> JSONResponse:
    """Turn transfer_batch() rows into the HTTP answer.
    200 applied (or dry run) | 202 failed and filed for review: the filing WAS committed."""
    filed = rows[0]["filed_batch"]
    body = {
        "dry_run": dry_run,
        "applied": filed is None and not dry_run,
        "would_succeed": all(r["ok"] for r in rows),
        "filed_batch": None if dry_run else filed,
        "lines": rows,
        **(extra or {}),
    }
    if dry_run:
        for r in rows:   # ids from a rolled-back run point at rows that no longer exist
            r["child_item"] = r["filed_batch"] = None
    status = 202 if (filed is not None and not dry_run) else 200
    return JSONResponse(status_code=status, content=jsonable_encoder(body))


# --- endpoints ---------------------------------------------------------------

@router.post("/transfers", status_code=201)
async def transfer(body: TransferIn, conn: Conn) -> dict:
    """Move an amount from one item into a vessel or into another item.

    **Triggers `inventory.transfer()`**: checks the parent isn't red, has enough, units match,
    the target vessel has room; mixes if the vessel already holds a liquid; records lineage.
    All in one step: if anything fails, nothing changes (422 with the database's reason).
    """
    child = await call_transfer(conn, body)
    return {"child_item": child}


@router.post("/transfers/batch", responses={202: {"description": "A line failed: nothing applied, batch filed for review"}})
async def transfer_batch(body: BatchIn, conn: Conn) -> JSONResponse:
    """Many transfers as ONE all-or-nothing action.

    **Triggers `inventory.transfer_batch()`**, which runs `inventory.transfer()` per line.
    - every line succeeds -> **200**, all applied
    - any line fails -> **202**, NOTHING applied; the request is filed (`filed_batch`) with each
      line's reason, items involved turn yellow (`pending_review`). Resolve via `/batches/{id}`.
    - `dry_run: true` -> every line is checked, then everything is rolled back; nothing is filed.
    """
    if body.context:
        await set_context(conn, body.context)
    lines = [
        {"parent": l.parent_item, "amount": l.amount, "unit": l.unit,
         "to_vessel": l.to_vessel_id, "to_item": l.to_item_id}
        for l in body.lines
    ]
    # force_rollback=dry_run: a savepoint that is always undone in a dry run.
    async with conn.transaction(force_rollback=body.dry_run):
        rows = await call_transfer_batch(conn, lines)
    return batch_response(rows, body.dry_run)


@router.post("/plates/{barcode}/transfer", responses={202: {"description": "A well failed: nothing applied, batch filed for review"}})
async def plate_transfer(barcode: str, body: PlateTransferIn, conn: Conn) -> JSONResponse:
    """Copy `amount` from every chosen well of this plate to the SAME position on `to_plate`.

    One request for what the robot does in one action. The API only works out which wells map
    to which; the transfers themselves are done by
    **`inventory.transfer_batch()`** (one `inventory.transfer()` per well), all or nothing.
    Target wells that don't exist yet are created (same max volume as the source well).
    Source wells with nothing in them are skipped and listed in `skipped_wells`.
    Responses as for `/transfers/batch` (200 applied / 202 filed / dry run).
    """
    plates = await fetch_all(
        conn, "SELECT barcode, kind FROM inventory.storage_unit WHERE barcode IN (%s, %s)",
        (barcode, body.to_plate))
    kinds = {p["barcode"]: p["kind"] for p in plates}
    for b in (barcode, body.to_plate):
        if b not in kinds:
            raise HTTPException(404, f"Storage unit {b} not found")
        if kinds[b] != "plate":
            raise HTTPException(422, f"{b} is a {kinds[b]}, not a plate")

    wanted = None if body.wells == "all" else body.wells
    source = await fetch_all(conn, """
        SELECT s.position, s.max_volume_ul, it.id AS parent_item
        FROM inventory.vessel s
        LEFT JOIN inventory.items it ON it.in_vessel = s.id AND it.quantity > 0   -- the well's one live item
        WHERE s.stored_in = %s AND (%s::text[] IS NULL OR s.position = ANY(%s))
        ORDER BY s.position""", (barcode, wanted, wanted))

    if wanted:
        missing = sorted(set(wanted) - {s["position"] for s in source})
        if missing:
            raise HTTPException(422, f"Plate {barcode} has no wells {missing}")
    skipped = [s["position"] for s in source if s["parent_item"] is None]
    to_move = [s for s in source if s["parent_item"] is not None]
    if not to_move:
        raise HTTPException(422, f"No wells with content to transfer on plate {barcode}")

    await set_context(conn, f"plate transfer {barcode} -> {body.to_plate}, {body.amount} {body.unit} x {len(to_move)} wells")

    positions = [s["position"] for s in to_move]
    async with conn.transaction(force_rollback=body.dry_run):
        # Create missing target wells, then look up every target well's id by position.
        await conn.execute("""
            INSERT INTO inventory.vessel (name, stored_in, position, max_volume_ul)
            SELECT 'well', %s, s.position, s.max_volume_ul
            FROM inventory.vessel s
            WHERE s.stored_in = %s AND s.position = ANY(%s)
              AND NOT EXISTS (SELECT 1 FROM inventory.vessel t WHERE t.stored_in = %s AND t.position = s.position)""",
            (body.to_plate, barcode, positions, body.to_plate))
        targets = {r["position"]: r["id"] for r in await fetch_all(
            conn, "SELECT position, id FROM inventory.vessel WHERE stored_in = %s AND position = ANY(%s)",
            (body.to_plate, positions))}

        lines = [{"parent": s["parent_item"], "amount": body.amount, "unit": body.unit,
                  "to_vessel": targets[s["position"]]} for s in to_move]
        rows = await call_transfer_batch(conn, lines)

    for row, s in zip(rows, to_move):   # line_no follows the order of `lines`
        row["well"] = s["position"]
    return batch_response(rows, body.dry_run, {"skipped_wells": skipped})
