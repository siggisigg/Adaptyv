"""Items: a physical amount of one material in one vessel (brief questions 1 and 2)."""

from fastapi import APIRouter, HTTPException
from psycopg import sql

from app.db import Conn, fetch_all, fetch_one_or_404
from app.schemas import FlagsIn, ItemIn

router = APIRouter(prefix="/items", tags=["items"])


async def item_detail(conn, item_id: int) -> dict:
    """The item's status row (all flags, colour and reasons) plus where it is."""
    return await fetch_one_or_404(conn, """
        SELECT s.*, i.description, i.lot_id,
               v.barcode AS vessel_barcode, v.position, v.stored_in,
               inventory.location_path(v.stored_in) AS location
        FROM inventory.v_item_status s
        JOIN inventory.items i  ON i.id = s.item_id
        JOIN inventory.vessel v ON v.id = s.in_vessel
        WHERE s.item_id = %s""", (item_id,), f"Item {item_id} not found")


@router.post("", status_code=201)
async def receive_item(body: ItemIn, conn: Conn) -> dict:
    """Put received material into a vessel (e.g. a delivery). Material made from other material
    is NOT created here: use POST /transfers, so the lineage is recorded."""
    cur = await conn.execute("""
        INSERT INTO inventory.items (material, in_vessel, quantity, unit, lot_id, description, expires_at)
        VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING id""",
        (body.material, body.vessel_id, body.quantity, body.unit, body.lot_id, body.description, body.expires_at))
    return await item_detail(conn, (await cur.fetchone())["id"])


@router.get("")
async def list_items(conn: Conn, material: int | None = None, light: str | None = None,
                     include_empty: bool = False) -> list[dict]:
    """Items with their colour. Filter by `material` and/or `light` (green / yellow / red)."""
    return await fetch_all(conn, """
        SELECT item_id, material, quantity, unit, expires_at, light, red_reasons, yellow_reasons, in_vessel
        FROM inventory.v_item_status
        WHERE (%s::int IS NULL OR material = %s)
          AND (%s::text IS NULL OR light = %s)
          AND (%s OR quantity > 0)
        ORDER BY item_id""", (material, material, light, light, include_empty))


@router.get("/{item_id}")
async def get_item(item_id: int, conn: Conn) -> dict:
    """One item: every traffic-light flag, its colour, why, and where it is."""
    return await item_detail(conn, item_id)


@router.patch("/{item_id}/flags")
async def set_flags(item_id: int, body: FlagsIn, conn: Conn) -> dict:
    """Set the recorded yellow flags (reserved, in_use, in_transit). Omitted ones are unchanged."""
    changes = body.model_dump(exclude_unset=True)
    if not changes:
        raise HTTPException(422, "Nothing to change")
    query = sql.SQL("UPDATE inventory.items SET {}, updated_at = now() WHERE id = %s RETURNING id").format(
        sql.SQL(", ").join(sql.SQL("{} = %s").format(sql.Identifier(c)) for c in changes))
    await fetch_one_or_404(conn, query, (*changes.values(), item_id), f"Item {item_id} not found")
    return await item_detail(conn, item_id)


@router.post("/{item_id}/discard")
async def discard_item(item_id: int, conn: Conn) -> dict:
    await fetch_one_or_404(conn, "UPDATE inventory.items SET discarded = TRUE, updated_at = now() WHERE id = %s RETURNING id",
                           (item_id,), f"Item {item_id} not found")
    return await item_detail(conn, item_id)


@router.post("/{item_id}/ship")
async def ship_item(item_id: int, conn: Conn) -> dict:
    """The item left the lab."""
    await fetch_one_or_404(conn, "UPDATE inventory.items SET shipped = TRUE, updated_at = now() WHERE id = %s RETURNING id",
                           (item_id,), f"Item {item_id} not found")
    return await item_detail(conn, item_id)


@router.get("/{item_id}/ancestors")
async def ancestors(item_id: int, conn: Conn) -> list[dict]:
    """Everything this item was made from, at any depth (`inventory.item_ancestors()`)."""
    await item_detail(conn, item_id)   # 404 if it doesn't exist
    return await fetch_all(conn, """
        SELECT a.item_id, a.depth, s.material, s.light, i.lot_id
        FROM inventory.item_ancestors(%s) a
        JOIN inventory.v_item_status s ON s.item_id = a.item_id
        JOIN inventory.items i ON i.id = a.item_id
        ORDER BY a.depth, a.item_id""", (item_id,))


@router.get("/{item_id}/descendants")
async def descendants(item_id: int, conn: Conn) -> list[dict]:
    """Everything made from this item, at any depth (`inventory.item_descendants()`)."""
    await item_detail(conn, item_id)
    return await fetch_all(conn, """
        SELECT d.item_id, d.depth, s.material, s.quantity, s.unit, s.light, s.in_vessel
        FROM inventory.item_descendants(%s) d
        JOIN inventory.v_item_status s ON s.item_id = d.item_id
        ORDER BY d.depth, d.item_id""", (item_id,))
