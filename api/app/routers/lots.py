"""Supplier lots and QC (brief question 4: a bad batch, and everything it touched)."""

from fastapi import APIRouter

from app.db import Conn, fetch_all, fetch_one_or_404, set_context
from app.schemas import LotIn, QcIn

router = APIRouter(prefix="/lots", tags=["lots"])


@router.post("", status_code=201)
async def create_lot(body: LotIn, conn: Conn) -> dict:
    """Register a delivery's lot. Registering the same supplier lot twice -> 409."""
    cur = await conn.execute("""
        INSERT INTO inventory.lots (material, supplier, supplier_lot_number, certificate_of_analysis, received_at)
        VALUES (%s, %s, %s, %s, %s) RETURNING *""",
        (body.material, body.supplier, body.supplier_lot_number, body.certificate_of_analysis, body.received_at))
    return await cur.fetchone()


@router.post("/{lot_id}/qc")
async def record_qc(lot_id: int, body: QcIn, conn: Conn) -> dict:
    """Record the QC result. Failing a lot turns EVERYTHING made from it red, at any depth,
    without touching a single item: v_item_status inherits QC through lineage."""
    await set_context(conn, f"QC {body.result} for lot {lot_id}")
    return await fetch_one_or_404(conn, """
        UPDATE inventory.lots SET qc_passed = %s, qc_failed = %s WHERE id = %s RETURNING *""",
        (body.result == "passed", body.result == "failed", lot_id), f"Lot {lot_id} not found")


@router.get("/{lot_id}/trace")
async def trace_lot(lot_id: int, conn: Conn) -> dict:
    """Every item from this lot (depth 0) and everything made from them, with where each one
    is now and its colour. Uses `inventory.lot_trace()`."""
    lot = await fetch_one_or_404(conn, "SELECT * FROM inventory.lots WHERE id = %s", (lot_id,), f"Lot {lot_id} not found")
    items = await fetch_all(conn, """
        SELECT t.item_id, t.depth, s.quantity, s.unit, s.light, s.red_reasons, s.yellow_reasons,
               v.id AS vessel_id, v.barcode AS vessel_barcode, v.position,
               inventory.location_path(v.stored_in) AS location
        FROM inventory.lot_trace(%s) t
        JOIN inventory.v_item_status s ON s.item_id = t.item_id
        JOIN inventory.vessel v        ON v.id = s.in_vessel
        ORDER BY t.depth, t.item_id""", (lot_id,))
    return {"lot": lot, "items": items}
