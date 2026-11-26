"""Where things are (brief question 3): storage units, plates' wells, and barcode scanning."""

from fastapi import APIRouter, HTTPException

from app.db import Conn, fetch_all, fetch_one_or_404
from app.schemas import MoveIn, StorageUnitIn

router = APIRouter(tags=["locations"])

UNIT = "barcode, kind, description, stored_in, n_rows, n_cols, discarded, inventory.location_path(barcode) AS location"


async def vessels_in(conn, barcode: str) -> list[dict]:
    """Vessels directly in a unit (for a plate: its wells), with fill and their live item's colour."""
    return await fetch_all(conn, """
        SELECT v.id, v.barcode, v.name, v.position, v.discarded,
               f.max_volume_ul, f.total_volume_ul,
               s.item_id, s.material, s.quantity, s.unit, s.light
        FROM inventory.vessel v
        JOIN inventory.v_vessel_fill f ON f.vessel_id = v.id
        LEFT JOIN inventory.v_item_status s ON s.in_vessel = v.id AND s.quantity > 0
        WHERE v.stored_in = %s
        ORDER BY v.position NULLS LAST, v.id""", (barcode,))


@router.post("/storage-units", status_code=201)
async def create_storage_unit(body: StorageUnitIn, conn: Conn) -> dict:
    cur = await conn.execute(f"""
        INSERT INTO inventory.storage_unit (barcode, kind, stored_in, description, n_rows, n_cols)
        VALUES (%s, %s, %s, %s, %s, %s) RETURNING {UNIT}""",
        (body.barcode, body.kind, body.stored_in, body.description, body.n_rows, body.n_cols))
    return await cur.fetchone()


@router.get("/storage-units/{barcode}")
async def get_storage_unit(barcode: str, conn: Conn) -> dict:
    """A unit, its full location path, every unit nested inside it (`storage_unit_contents()`),
    and the vessels directly in it with their fill and colour."""
    unit = await fetch_one_or_404(conn, f"SELECT {UNIT} FROM inventory.storage_unit WHERE barcode = %s",
                                  (barcode,), f"Storage unit {barcode} not found")
    nested = await fetch_all(conn, "SELECT * FROM inventory.storage_unit_contents(%s)", (barcode,))
    return {**unit, "nested_units": nested, "vessels": await vessels_in(conn, barcode)}


@router.post("/storage-units/{barcode}/move")
async def move_storage_unit(barcode: str, body: MoveIn, conn: Conn) -> dict:
    """Move a unit. Everything inside it moves with it: only this unit's `stored_in` changes."""
    return await fetch_one_or_404(conn, f"""
        UPDATE inventory.storage_unit SET stored_in = %s, updated_at = now()
        WHERE barcode = %s RETURNING {UNIT}""", (body.to, barcode), f"Storage unit {barcode} not found")


@router.post("/storage-units/{barcode}/discard")
async def discard_storage_unit(barcode: str, conn: Conn) -> dict:
    """Throw a unit away (e.g. a used plate). Items in its vessels turn red."""
    return await fetch_one_or_404(conn, f"""
        UPDATE inventory.storage_unit SET discarded = TRUE, updated_at = now()
        WHERE barcode = %s RETURNING {UNIT}""", (barcode,), f"Storage unit {barcode} not found")


@router.get("/plates/{barcode}")
async def get_plate(barcode: str, conn: Conn) -> dict:
    """A plate as a grid: every well with its fill and colour."""
    plate = await fetch_one_or_404(conn, f"SELECT {UNIT} FROM inventory.storage_unit WHERE barcode = %s AND kind = 'plate'",
                                   (barcode,), f"Plate {barcode} not found")
    return {**plate, "wells": await vessels_in(conn, barcode)}


@router.get("/scan/{barcode}")
async def scan(barcode: str, conn: Conn) -> dict:
    """Whatever was scanned: a storage unit or a tube, with where it is.

    Barcodes live in two tables, so the same code could exist in both (known gap) -> 409."""
    units = await fetch_all(conn, f"SELECT {UNIT} FROM inventory.storage_unit WHERE barcode = %s", (barcode,))
    tubes = await fetch_all(conn, """
        SELECT v.id, v.barcode, v.name, v.stored_in, v.position, v.discarded,
               inventory.location_path(v.stored_in) AS location
        FROM inventory.vessel v WHERE v.barcode = %s""", (barcode,))
    if units and tubes:
        raise HTTPException(409, f"Barcode {barcode} is both a storage unit and a tube")
    if units:
        return {"type": "storage_unit", **units[0]}
    if tubes:
        tube = tubes[0]
        contents = await fetch_all(conn, """
            SELECT item_id, material, quantity, unit, expires_at, light, red_reasons, yellow_reasons
            FROM inventory.v_item_status WHERE in_vessel = %s AND quantity > 0""", (tube["id"],))
        return {"type": "vessel", **tube, "item": contents[0] if contents else None}
    raise HTTPException(404, f"Barcode {barcode} not found")
