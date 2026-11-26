from fastapi import APIRouter

from app.db import Conn

router = APIRouter(tags=["health"])


@router.get("/health")
async def health(conn: Conn) -> dict:
    """Is the database reachable, and was the schema loaded by initdb?"""
    cur = await conn.execute(
        "SELECT array_agg(nspname ORDER BY nspname) AS schemas "
        "FROM pg_namespace WHERE nspname IN ('inventory', 'audit')"
    )
    row = await cur.fetchone()
    schemas = row["schemas"] or []
    return {
        "database": "ok",
        "schema_loaded": schemas == ["audit", "inventory"],
        "schemas": schemas,
    }
