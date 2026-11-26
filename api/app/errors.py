"""Turn database errors into HTTP responses.

The business rules live in the database, so most "bad request" errors arrive as Postgres
errors. Each carries a SQLSTATE code saying what kind of error it is; we map that code to
an HTTP status and pass the database's own message through (they're written to be readable,
e.g. "Item 2 is red (discarded) and cannot be used").

Unknown errors become a plain 500 WITHOUT the database message, so internals don't leak.
"""

import logging

import psycopg
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

log = logging.getLogger(__name__)

# SQLSTATE -> HTTP status. https://www.postgresql.org/docs/current/errcodes-appendix.html
STATUS_BY_SQLSTATE = {
    "P0001": 422,  # raise_exception: our own rule failures (not enough left, red item, vessel full)
    "23505": 409,  # unique_violation: duplicate lot, two vessels in one well, duplicate barcode
    "23514": 422,  # check_violation: negative quantity, contradictory flags
    "23503": 422,  # foreign_key_violation: refers to a vessel/unit/storage unit that doesn't exist
    "23502": 422,  # not_null_violation: a required value is missing
    "22P02": 422,  # invalid_text_representation: e.g. 'abc' where a number was expected
}


def status_for(sqlstate: str | None) -> int:
    return STATUS_BY_SQLSTATE.get(sqlstate or "", 500)


async def handle_database_error(request: Request, exc: psycopg.Error) -> JSONResponse:
    status = status_for(exc.sqlstate)
    if status == 500:
        log.exception("Unexpected database error", exc_info=exc)
        return JSONResponse(status_code=500, content={"error": "internal database error"})

    return JSONResponse(
        status_code=status,
        content={
            "error": exc.diag.message_primary,   # the main message, e.g. "Item 4 has only 100 uL, ..."
            "detail": exc.diag.message_detail,   # extra detail Postgres adds, e.g. which key clashed
            "sqlstate": exc.sqlstate,
        },
    )


def register(app: FastAPI) -> None:
    app.add_exception_handler(psycopg.Error, handle_database_error)
