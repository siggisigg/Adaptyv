from contextlib import asynccontextmanager

from fastapi import FastAPI

from app import errors
from app.db import pool
from app.routers import health


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Runs once at startup / shutdown: open the pool when the server starts, close it cleanly.
    await pool.open()
    yield
    await pool.close()


app = FastAPI(
    title="Lab Inventory API",
    description="Thin API over the inventory database. Business rules live in SQL.",
    lifespan=lifespan,
)

errors.register(app)
app.include_router(health.router)
