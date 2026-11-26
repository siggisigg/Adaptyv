"""Vessels: tubes (with a barcode) and plate wells (plate barcode + position)."""

from fastapi import APIRouter

from app.db import Conn, fetch_all, fetch_one_or_404
from app.schemas import VesselIn

router = APIRouter(tags=["vessels"])

VESSEL = """v.id, v.barcode, v.name, v.stored_in, v.position, v.discarded,
            f.max_volume_ul, f.total_volume_ul, f.free_volume_ul,
            inventory.location_path(v.stored_in) AS location"""


async def vessel_with_item(conn, where: str, params: tuple, not_found: str) -> dict:
    vessel = await fetch_one_or_404(conn, f"""
        SELECT {VESSEL} FROM inventory.vessel v
        JOIN inventory.v_vessel_fill f ON f.vessel_id = v.id
        WHERE {where}""", params, not_found)
    items = await fetch_all(conn, """
        SELECT item_id, material, quantity, unit, expires_at, light, red_reasons, yellow_reasons
        FROM inventory.v_item_status WHERE in_vessel = %s AND quantity > 0""", (vessel["id"],))
    return {**vessel, "item": items[0] if items else None}


@router.post("/vessels", status_code=201)
async def create_vessel(body: VesselIn, conn: Conn) -> dict:
    cur = await conn.execute("""
        INSERT INTO inventory.vessel (name, stored_in, barcode, position, max_volume_ul)
        VALUES (%s, %s, %s, %s, %s) RETURNING id""",
        (body.name, body.stored_in, body.barcode, body.position, body.max_volume_ul))
    vessel_id = (await cur.fetchone())["id"]
    return await vessel_with_item(conn, "v.id = %s", (vessel_id,), "unreachable")


@router.get("/vessels/{barcode}")
async def get_tube(barcode: str, conn: Conn) -> dict:
    """A tube by its barcode: fill, location, and its item with colour."""
    return await vessel_with_item(conn, "v.barcode = %s", (barcode,), f"Tube {barcode} not found")


@router.get("/plates/{barcode}/wells/{position}")
async def get_well(barcode: str, position: str, conn: Conn) -> dict:
    """A well, addressed the way people find it: plate barcode + position."""
    return await vessel_with_item(conn, "v.stored_in = %s AND v.position = %s", (barcode, position),
                                  f"Plate {barcode} has no well {position}")


@router.post("/vessels/{vessel_id}/discard")
async def discard_vessel(vessel_id: int, conn: Conn) -> dict:
    """Throw a tube or well away, possibly with material inside: its item turns red."""
    await fetch_one_or_404(conn, "UPDATE inventory.vessel SET discarded = TRUE, updated_at = now() WHERE id = %s RETURNING id",
                           (vessel_id,), f"Vessel {vessel_id} not found")
    return await vessel_with_item(conn, "v.id = %s", (vessel_id,), "unreachable")
