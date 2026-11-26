# API Plan (draft)

A small **FastAPI** service in front of the inventory database. It's the interface that scanners, lab scientists, robots and the experiment-planning system would use.

## Principle: a thin API over a database that enforces its own rules

The schema already enforces the rules that matter: capacity, enough material left, red material can't be used, units must match, no duplicate lots, and all-or-nothing transfers. The API should **not** re-implement any of them. Its job is to:

1. Parse and validate the *shape* of each request (with Pydantic). Business rules stay in the database.
2. Call the database's functions and views.
3. Turn database errors into clear HTTP responses.
4. Know who the user is, and pass that to the database for lineage and audit.

The reason: if a rule exists in both Python and SQL, the two copies eventually disagree, and anything that writes to the database without going through the API bypasses the Python copy. Keeping each rule in one place means it holds no matter who writes.

## Stack

| Choice | Why |
|---|---|
| **FastAPI** + **uvicorn** | Request and response validation from type hints, and automatic interactive docs at `/docs`, which is useful for the demo. |
| **psycopg 3** (`psycopg[binary,pool]`) + plain SQL | The logic lives in SQL functions and views, so an ORM adds little. SQLAlchemy models would be a second copy of the schema to keep in sync. |
| **Pydantic** models | Request bodies and response shapes only. |
| **pytest** | Each test runs in a transaction that gets rolled back, the same pattern used to test the schema. |

## Layout

```text
api/
  requirements.txt        fastapi, uvicorn[standard], psycopg[binary,pool], pytest, httpx
  app/
    main.py               app, routers, startup/shutdown of the connection pool
    db.py                 connection pool; get_conn() dependency that wraps each request in one transaction
    errors.py             maps Postgres errors to HTTP status codes
    schemas.py            Pydantic request/response models
    routers/
      locations.py        storage units
      vessels.py
      lots.py
      items.py
      transfers.py
      stock.py
      reports.py
  tests/
```

Changes needed in `docker-compose.yml`:
- Mount `./api:/app`.
- Install the requirements.
- Run `uvicorn app.main:app --host 0.0.0.0 --reload`.
- Expose port `8000`.
- Mount `./initdb:/docker-entrypoint-initdb.d` on the postgres service, so a fresh volume gets the schema automatically.

## One request = one transaction

`get_conn()` takes a connection from the pool and opens a transaction. It commits if the endpoint returns normally and rolls back if it raises. Endpoints that do several steps, such as "make a plate from stock", are therefore atomic without any extra code.

## Error mapping

Postgres reports each error with a code (SQLSTATE), and the API maps that code to an HTTP status:

| SQLSTATE | Raised by | HTTP |
|---|---|---|
| `P0001` (`RAISE EXCEPTION`) | Rule failures in `transfer()` and the capacity trigger: not enough left, red item, vessel full, unit mismatch | **422** with the database's message |
| `23505` unique_violation | Duplicate lot, two vessels in one well | **409 Conflict** |
| `23514` check_violation | Negative quantity, `qc_passed` and `qc_failed` both set | **422** |
| `23503` foreign_key_violation | Unknown vessel, storage unit or unit | **404** or **422** |

The database's own messages ("Item 2 is red (discarded) and cannot be used") are already readable, so they can be passed straight through to the user.

## Endpoints

Grouped by the brief's questions. **Bold** endpoints are the core of the demo.

### Locations (Q3: where is it?)
| Method | Path | Does |
|---|---|---|
| POST | `/storage-units` | Create a unit (kind, barcode, parent) |
| **GET** | **`/storage-units/{barcode}`** | The unit, plus everything inside it at any depth (`storage_unit_contents`) |
| POST | `/storage-units/{barcode}/move` | Change `stored_in`. Everything inside moves with it. |
| POST | `/storage-units/{barcode}/discard` | Set `discarded`. Its wells' items turn red. |
| GET | `/scan/{barcode}` | Look up a scanned barcode: what it is and where it is. *Needs barcodes on vessels first.* |

### Vessels
| Method | Path | Does |
|---|---|---|
| POST | `/vessels` | Create a tube or well (parent, position, max volume) |
| GET | `/vessels/{id}` | The vessel plus its fill from `vessel_fill` and its items with their colours |
| POST | `/vessels/{id}/move`, `/discard` | |

### Lots and QC (Q4: bad batch)
| Method | Path | Does |
|---|---|---|
| POST | `/lots` | Register a delivery. A duplicate gets **409**. |
| **POST** | **`/lots/{id}/qc`** | `{ "result": "passed" \| "failed" }`. Failing instantly turns everything made from the lot red. |
| **GET** | **`/lots/{id}/trace`** | `lot_trace()`: every item from the lot, with location and colour |

### Items (Q1, Q2)
| Method | Path | Does |
|---|---|---|
| POST | `/items` | Receive a bought item into a vessel (lot, quantity, unit, expiry) |
| **GET** | **`/items/{id}`** | The item, its `item_status` (colour plus reasons) and its location path |
| GET | `/items?material=&light=&expiring_within_days=` | Filtered list for planners and scientists |
| PATCH | `/items/{id}/flags` | Set `reserved`, `in_use` or `in_transit` |
| POST | `/items/{id}/discard`, `/ship` | Red states that end an item's life |
| GET | `/items/{id}/ancestors`, `/descendants` | Lineage in either direction |

### Transfers (consumption)
| Method | Path | Does |
|---|---|---|
| **POST** | **`/transfers`** | `{ parent, amount, unit, to_vessel \| to_item }` calls `transfer()` and returns the child id |
| POST | `/transfers/batch` | A list of transfers in **one transaction**, for a robot's plate-to-plate run. If one well fails, none are applied. |

### Stock
| Method | Path | Does |
|---|---|---|
| POST | `/stock` | Add consumables |
| POST | `/stock/{id}/plate` | Take one plate from stock: decrement the count, create the plate storage unit and its wells. Best done as a SQL function, `create_plate_from_stock()`, to match `transfer()`. |

### Reports (for planning)
| Method | Path | Does |
|---|---|---|
| **GET** | **`/reports/material-quantities`** | `material_quantities`: totals per category and colour (Q1) |
| GET | `/reports/expiring?days=7` | Items that have expired or expire soon (Q2) |

## Users, permissions and audit (Q5)

- **Login:** the `users` table already exists. A simple token login (`POST /auth/login` returns a bearer token) is enough for the demo.
- **Passing the user to the database:** at the start of each transaction, run `SET LOCAL app.user_id = <id>`. `transfer()` can then record `created_by`, and a future audit trigger can read it with `current_setting('app.user_id')`. `SET LOCAL` only lasts for the current transaction, so one request's user can't leak into the next request that reuses the same pooled connection.
- **Database permissions:** the API connects as a role that can only `SELECT` the views and `EXECUTE` the functions. It can't write to `items.quantity` or `item_lineage` directly. That turns "all consumption goes through `transfer()`" from a convention into something the database enforces.

## Build order

1. **Skeleton:** compose changes, connection pool, `/health`, error mapping, test fixture.
2. **Read endpoints:** storage-unit contents, item status, lot trace and material quantities. These answer the brief's questions and make the best demo.
3. **Write endpoints:** receive item, transfer, QC result, flags, discard and move.
4. **Users and audit:** login, `SET LOCAL app.user_id`, the `audit_log` table and trigger, then `GET /audit?table=&id=` (Q5).
5. **Batch transfers and plate-from-stock.**

## Open questions

- **Rename the `_staging` schema** to something like `inventory` before the API depends on the name? A leading underscore usually means "internal" or "temporary".
- **IDs or barcodes in URLs?** Scientists scan barcodes, so barcodes are friendlier. That needs `vessel.barcode` first.
- **Sync or async psycopg?** Sync is simpler and fine at lab traffic levels. Async only helps with many concurrent slow requests.
