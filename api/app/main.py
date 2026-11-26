from contextlib import asynccontextmanager

from fastapi import FastAPI

from app import errors
from app.db import pool
from app.routers import batches, health, items, locations, lots, reports, transfers, vessels


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Runs once at startup / shutdown: open the pool when the server starts, close it cleanly.
    await pool.open()
    yield
    await pool.close()


app = FastAPI(
    title="Lab Inventory API",
    description=(
        "Thin API over the inventory database. Business rules live in SQL.\n\n"
        "**Material only moves through the `transfers` endpoints**, which call the database "
        "functions `inventory.transfer()` and `inventory.transfer_batch()`."
    ),
    lifespan=lifespan,
)

errors.register(app)
for module in (health, locations, vessels, lots, items, transfers, batches, reports):
    app.include_router(module.router)
