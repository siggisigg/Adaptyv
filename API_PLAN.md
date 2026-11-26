# API Plan (draft)

A small **FastAPI** service in front of the inventory database. It's the interface that scanners, lab scientists, robots and the experiment-planning system would use.

## Principle: a thin API over a database that enforces its own rules

The schema already enforces the rules that matter: capacity, enough material left, red material can't be used, units must match, no duplicate lots, all-or-nothing transfers, and the audit trail. The API should **not** re-implement any of them. Its job is to:

1. Parse and validate the *shape* of each request (with Pydantic). Business rules stay in the database.
2. Call the database's functions and views.
3. **Combine per-well operations into lab-sized actions** (see below).
4. Turn database errors into clear HTTP responses.
5. Tell the database who the user is and why the change is being made, so the audit log can record it.

The reason: if a rule exists in both Python and SQL, the two copies eventually disagree, and anything that writes to the database without going through the API bypasses the Python copy. Keeping each rule in one place means it holds no matter who writes.

## Stack

| Choice | Why |
|---|---|
| **FastAPI** + **uvicorn** | Request and response validation from type hints, and automatic interactive docs at `/docs`, which is useful for the demo. |
| **psycopg 3, async** (`psycopg[binary,pool]`, `AsyncConnectionPool`) + plain SQL | The logic lives in SQL functions and views, so an ORM adds little. SQLAlchemy models would be a second copy of the schema to keep in sync. Async is preferred; see the trade-offs below. |
| **Pydantic** models | Request bodies and response shapes only. |
| **pytest** + `pytest-asyncio` + `httpx.AsyncClient` | Each test runs in a transaction that gets rolled back, the same pattern used to test the schema. |

### Async: trade-offs to discuss

- **For:**
  - While one request waits on the database, the server can handle others without a thread per request. That suits many scanners and a robot making short requests at the same time.
  - It's consistent with FastAPI's `async def` endpoints.
- **Against:**
  - Everything in the call chain has to be async. One blocking call (a sync library, or heavy CPU work) stalls *every* request.
  - Tests and debugging are slightly more involved.
- **At lab traffic levels, either choice is fine.** FastAPI runs plain `def` endpoints in a thread pool, so sync wouldn't be a bottleneck. Async is the forward-looking choice, and psycopg 3 supports it natively, so it costs little.

## Layout

```text
api/
  requirements.txt        fastapi, uvicorn[standard], psycopg[binary,pool], pytest, pytest-asyncio, httpx
  app/
    main.py               app, routers, startup/shutdown of the connection pool
    db.py                 AsyncConnectionPool; get_conn() dependency: one transaction per request, sets app.user_id / app.context
    errors.py             maps Postgres errors to HTTP status codes
    schemas.py            Pydantic request/response models
    routers/
      locations.py        storage units, /scan
      plates.py           plate-level actions (whole-plate transfers, flags, discard)
      vessels.py
      lots.py
      items.py
      transfers.py
      stock.py
      reports.py
      audit.py
  tests/
```

Changes needed in `docker-compose.yml`:

- Mount `./api:/app`.
- Install the requirements.
- Run `uvicorn app.main:app --host 0.0.0.0 --reload`.
- Expose port `8000`.
- Mount `./initdb:/docker-entrypoint-initdb.d` on the postgres service, so a fresh volume gets the schema automatically.

## Transactions: one request = one transaction, which may contain many database operations

`get_conn()` takes a connection from the pool and opens a transaction. It then:

```sql
SELECT set_config('app.user_id', $1, true), set_config('app.context', $2, true);
```

`set_config(..., true)` is the same as `SET LOCAL`, but it accepts bound parameters, which `SET` doesn't. Because the setting only lasts for the current transaction, one request's user can't leak into the next request that reuses the same pooled connection.

The dependency commits if the endpoint returns normally and rolls back if it raises.

**The database's unit of work is one well, or one item. The API's unit of work is one lab action.** One request can make many `transfer()` calls inside its single transaction. The lab sees one action, the audit log groups every change under one `transaction_id` with a readable `context`, and if any well fails, the whole action is undone.

## Plate-level actions

A robot copying a 96-well plate is **one action in reality**, so it should be one API request, not 96. Expecting 96 requests would mean 96 round trips, 96 transactions, and a plate that could be left half-transferred if the client dies partway through.

**Example:** `POST /plates/{source_barcode}/transfer`

```json
{
  "to_plate": "PLATE-0042",
  "amount": 20,
  "unit": "uL",
  "wells": "all",                 // or ["A1", "A2", "B7"]
  "mapping": "same_position",     // A1 -> A1; later: explicit {"A1": "H12"} maps
  "dry_run": false
}
```

- **Resolve wells:** source and target wells are found by plate barcode + position. Target wells that don't exist yet are created on the target plate.
- **One statement, not 96 round trips:** the API sends the whole plate's worth of arguments as arrays in a single query:

  ```sql
  SELECT t.position, inventory.transfer(t.item_id, $amount, $unit, p_to_vessel => t.to_vessel)
  FROM unnest($positions::text[], $item_ids::int[], $to_vessels::int[]) AS t(position, item_id, to_vessel);
  ```

  That's one round trip, and still 96 individual, fully checked `transfer()` calls, all in one transaction.
- **Response:** per-well results, such as `[{ "well": "A1", "child_item": 812 }, ...]`. On failure: **422**, naming the well that failed and the database's reason, for example `B7: Item 455 has only 10 uL, cannot take 20 uL`.
- **Dry run:** with `dry_run: true`, the API runs everything and then **rolls back** instead of committing. A robot or scientist can check that a whole run is possible before starting. This needs no extra logic, because the transaction design already provides it.

Other plate-level actions follow the same pattern: one request, a loop or array inside, one transaction.

| Method | Path | Does |
|---|---|---|
| **POST** | **`/plates/{barcode}/transfer`** | Whole-plate or selected-well transfer, as above |
| PATCH | `/plates/{barcode}/flags` | Set `reserved`, `in_use` or `in_transit` on every item in the plate |
| POST | `/plates/{barcode}/discard` | Discard the plate. All its wells' items turn red. |
| POST | `/stock/{id}/plate` | Take one plate from stock: decrement the count, create the plate storage unit and its wells |
| GET | `/plates/{barcode}` | A grid view: every well's items, fill and colour |

**Two open design questions:**
1. **All-or-nothing, or partial success?** If well B7 fails, should the other 95 be recorded? The plan says **all-or-nothing**: the inventory must not record a plate the robot never fully made. With dry runs, failures are caught before the robot starts. But if the robot *has already* physically run, refusing to record it makes the inventory wrong in a different way. A possible middle ground is to record what succeeded and flag the failed wells for review.
2. **A well holding more than one item:** `transfer()` moves one item. If a source well holds several separate items, the plan is to **reject that well** for now. The alternative is to transfer each item proportionally.

## Barcodes in URLs

Anything with a physical label is addressed by its **barcode**. Records with no label use their id.

| Thing | URL | Why |
|---|---|---|
| Storage unit (freezer, rack, box, plate) | `/storage-units/{barcode}`, `/plates/{barcode}` | Labelled and scanned |
| Tube | `/vessels/{barcode}` | `vessel.barcode` (new, unique, optional) |
| Well | `/plates/{barcode}/wells/{position}` | Wells don't carry their own barcode, so they're found through the plate's |
| Item, lot | `/items/{id}`, `/lots/{id}` | No physical label. Lots can also be found with `?supplier=&lot_number=`. |
| Anything scanned | `GET /scan/{barcode}` | Works out whether the barcode belongs to a storage unit or a tube, and returns it with its location |

**Known gap:** tube and storage-unit barcodes live in different tables, so the same barcode could exist in both. `/scan` would return 409 in that case, and the proper fix is a shared barcode registry (see README section 10).

## Error mapping

Postgres reports each error with a code (SQLSTATE), and the API maps that code to an HTTP status:

| SQLSTATE | Raised by | HTTP |
|---|---|---|
| `P0001` (`RAISE EXCEPTION`) | Rule failures in `transfer()` and the capacity trigger: not enough left, red item, vessel full, unit mismatch | **422** with the database's message |
| `23505` unique_violation | Duplicate lot, two vessels in one well, duplicate barcode | **409 Conflict** |
| `23514` check_violation | Negative quantity, `qc_passed` and `qc_failed` both set | **422** |
| `23503` foreign_key_violation | Unknown vessel, storage unit or unit | **404** or **422** |

The database's own messages ("Item 2 is red (discarded) and cannot be used") are already readable, so they can be passed straight through to the user.

## Other endpoints

**Bold** endpoints are the core of the demo.

### Locations (Q3: where is it?)

| Method | Path | Does |
|---|---|---|
| POST | `/storage-units` | Create a unit (kind, barcode, parent) |
| **GET** | **`/storage-units/{barcode}`** | The unit, plus everything inside it at any depth (`storage_unit_contents`) |
| POST | `/storage-units/{barcode}/move` | Change `stored_in`. Everything inside moves with it. |
| **GET** | **`/scan/{barcode}`** | Look up whatever was scanned: what it is and where it is |

### Vessels

| Method | Path | Does |
|---|---|---|
| POST | `/vessels` | Create a tube (barcode, parent, max volume) |
| GET | `/vessels/{barcode}` | The tube plus its fill from `vessel_fill` and its items with their colours |
| POST | `/vessels/{barcode}/move`, `/discard` | |

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
| **GET** | **`/items/{id}`** | The item, its `item_status` (colour plus reasons) and its location |
| GET | `/items?material=&light=&expiring_within_days=` | Filtered list for planners and scientists |
| PATCH | `/items/{id}/flags` | Set `reserved`, `in_use` or `in_transit` |
| POST | `/items/{id}/discard`, `/ship` | Red states that end an item's life |
| GET | `/items/{id}/ancestors`, `/descendants` | Lineage in either direction |

### Transfers (single)

| Method | Path | Does |
|---|---|---|
| POST | `/transfers` | `{ parent, amount, unit, to_vessel \| to_item }` calls `transfer()` and returns the child id. Used for manual, one-off transfers. Plates go through `/plates/...`. |

### Reports (for planning)

| Method | Path | Does |
|---|---|---|
| **GET** | **`/reports/material-quantities`** | `material_quantities`: totals per category and colour (Q1) |
| GET | `/reports/expiring?days=7` | Items that have expired or expire soon (Q2) |

### Audit (Q5)

The database side is built (`initdb/04-audit.sql`). These endpoints only read it.

| Method | Path | Does |
|---|---|---|
| **GET** | **`/audit/{table}/{key}`** | `audit.history()`: every change to one record, with who, why and the old and new values |
| GET | `/audit/{table}/{key}?as_of=2026-11-25T14:00Z` | `audit.as_of()`: what the record said at that time |
| GET | `/audit/actions/{transaction_id}` | Everything one action changed. For example, all 96 wells of a plate transfer. |
| GET | `/audit?user=&since=` | Everything a person did |

## Users and permissions

- **Login:** a simple token login against the existing `users` table (`POST /auth/login` returns a bearer token) is enough for the demo.
- **User and context:** `get_conn()` sets `app.user_id` from the token. Each endpoint sets `app.context`, for example "plate transfer PLATE-0001 → PLATE-0042". The audit trigger and `transfer()` read both automatically.
- **Database permissions:** the API connects as a role that can:
  - `EXECUTE` the functions
  - `SELECT` the views and `audit.*`
  - `INSERT`/`UPDATE` only the flag and location columns it legitimately sets

  It can't write `items.quantity`, `item_lineage` or `audit.log` directly. That turns "all consumption goes through `transfer()`" and "the log is append-only" from conventions into something the database enforces.

## Build order

1. **Skeleton:** compose changes, async connection pool, `get_conn()` with user and context, `/health`, error mapping, test fixture.
2. **Read endpoints:** scan, storage-unit contents, item status, lot trace, material quantities and audit history. These answer the brief's questions and make the best demo.
3. **Write endpoints:** receive item, single transfer, QC result, flags, discard and move.
4. **Plate-level actions:** whole-plate transfer with dry run, plate from stock.
5. **Login and the restricted database role.**

## Decided

- The schema is renamed from `_staging` to `inventory`.
- Barcodes in URLs for anything with a physical label. `vessel.barcode` has been added.
- Async is preferred (trade-offs above, open for discussion).
- Lab-sized actions, such as whole plates, are single requests. The database stays per-well atomic, and the API combines the calls into one transaction.
