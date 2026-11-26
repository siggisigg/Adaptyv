"""Database access: one connection pool, and one transaction per request.

Every endpoint that touches the database takes `conn: Conn` as a parameter. FastAPI then
calls get_conn() for that request, which:
  1. borrows a connection from the pool,
  2. opens a transaction,
  3. tells the database who is acting and why (read by the audit trigger and transfer()),
  4. hands the connection to the endpoint,
  5. commits if the endpoint returns normally, rolls back if it raises.

So an endpoint that makes 96 transfer() calls is still one all-or-nothing action, and the
audit log groups all of it under one transaction_id.
"""

import os
from collections.abc import AsyncIterator
from typing import Annotated

from fastapi import Depends, Header, HTTPException, Request
from psycopg import AsyncConnection
from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool

DATABASE_URL = os.environ["DATABASE_URL"]

# open=False: the pool is opened in main.py's lifespan, once the event loop is running.
# dict_row: query results come back as dicts, which FastAPI turns into JSON directly.
pool = AsyncConnectionPool(
    conninfo=DATABASE_URL,
    open=False,
    min_size=1,
    max_size=10,
    kwargs={"row_factory": dict_row},
)


async def start_request(conn: AsyncConnection, request: Request, user_id: int | None) -> None:
    """Tell the database who is acting and why, for the rest of this transaction."""
    # set_config(name, value, true) == SET LOCAL: the setting ends with this transaction,
    # so a pooled connection can't carry one request's user into the next.
    # Unlike SET, set_config accepts bound parameters (%s), so no SQL injection.
    await conn.execute(
        "SELECT set_config('app.user_id', %s, true), set_config('app.context', %s, true)",
        ("" if user_id is None else str(user_id), f"{request.method} {request.url.path}"),
    )


async def get_conn(
    request: Request,
    # TEMPORARY until login exists (build step 5): the acting user comes from a header.
    # Anyone can send any id, so this is for development only.
    x_user_id: Annotated[int | None, Header()] = None,
) -> AsyncIterator[AsyncConnection]:
    async with pool.connection() as conn:
        async with conn.transaction():   # commit on normal return, rollback if the endpoint raises
            await start_request(conn, request, x_user_id)
            yield conn


async def set_context(conn: AsyncConnection, context: str) -> None:
    """Replace the default context ('POST /plates/...') with a readable one for the audit log,
    e.g. 'plate transfer SRC-1 -> DST-7'."""
    await conn.execute("SELECT set_config('app.context', %s, true)", (context,))


# Shorthand for endpoint signatures:  async def endpoint(conn: Conn): ...
Conn = Annotated[AsyncConnection, Depends(get_conn)]


async def fetch_all(conn: AsyncConnection, query, params=()) -> list[dict]:
    cur = await conn.execute(query, params)
    return await cur.fetchall()


async def fetch_one_or_404(conn: AsyncConnection, query, params, not_found: str) -> dict:
    """Run a query that should return one row; respond 404 with `not_found` if it returns none."""
    cur = await conn.execute(query, params)
    row = await cur.fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail=not_found)
    return row
