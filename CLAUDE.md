# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## How to work with the user

This challenge tests the user's own abilities, so the user needs to **understand and be able to defend every change**:

- Explain the *why* behind each change: the Postgres behaviour or modelling trade-off involved, not just what changed.
- Keep changes scoped to what was asked. When a fix needs a design decision (such as how to model nesting or lineage), present the options with a recommendation and let the user choose. Don't redesign quietly.
- Prefer small, reviewable edits over large rewrites.

## What this is

A 24-hour take-home challenge from Adaptyv Bio: design a **lab inventory management data model and SQL schema** (PostgreSQL). The full brief is `Project_ Inventory Management.pdf`; `notes.md` holds the material-types table from it. The deliverable is reasoning plus artifacts (entities, relationships, key columns, SQL), presented live afterwards. Depth on a few pieces beats breadth, and **cuts and assumptions must be written down**, because the reviewers won't answer questions.

Experiment planning (deciding what to run, reserving material, choosing what to order) is **out of scope**. The inventory only has to give that system numbers it can trust.

## What the schema must handle (from the brief)

- Material is **bought** (supplier lot + certificate of analysis, QC'd before use, can fail QC) or **made** from other material (dilutions, samples expressed from DNA, buffers from components, aliquots split from a larger tube).
- Material lives in **containers** (tubes, plates where each well holds its own material, boxes, racks), and containers sit in **places** (freezers, fridges, shelves, bench, instruments). Containers have scannable barcodes and move several times a day.
- Lab tasks move material between containers (robot well-by-well transfers, one tube split into many), so consumption must be recorded as transfers.
- Shelf life depends on storage conditions and on the start date. Containers get discarded, sometimes with material still inside, and some material leaves the lab.
- Data-entry errors happen: wrong volume, wrong tube scanned, the same delivery registered twice.
- New material kinds will appear (for example small molecules), so adding one must be easy.

Questions the model must answer:

1. How much do we have, and how much of it is usable?
2. What has expired, and what expires soon?
3. Where is it?
4. Lineage: where did it come from and where did it go? (For example, find everything made from a bad target lot.)
5. Audit: who changed what and when, and what the record said before.

The design-focus bullets in the brief are: material-type differences, storage locations and movement, quantities and expiry, consumption and container-to-container transfer, and usable versus merely existing.

## Environment

```sh
docker compose up -d --build                   # postgres:16 (:5432) + FastAPI (:8000, docs at /docs)
docker compose down -v && docker compose up -d # full rebuild: wipes the DB volume so initdb/*.sql re-runs
docker compose exec postgres psql -U app -d app  # SQL shell (DBeaver: localhost:5432, app/app/app)
docker compose exec api pytest -v              # API tests
docker compose exec api pytest -v tests/test_plumbing.py::test_failed_request_keeps_none_of_its_writes   # one test
docker compose logs -f api                     # API logs (uvicorn --reload restarts on code edits)
```

`./initdb` is mounted into `/docker-entrypoint-initdb.d`, but Postgres only runs it when the `postgres_data` volume is **empty**. After any SQL change, do a full rebuild (`down -v`). This deletes all data in the DB.

To check that SQL changes load before you rebuild, run them in a rolled-back transaction:

```sh
{ echo 'BEGIN;'; cat initdb/*.sql; echo 'ROLLBACK;'; } | docker compose exec -T postgres psql -U app -d app -v ON_ERROR_STOP=1
```

That fails against an already-initialised DB, because the objects already exist. Use a throwaway database instead (`CREATE DATABASE inv_test`, load the files, test, `DROP DATABASE inv_test`). To test across committed transactions (audit, batches), always use a throwaway database.

## API (`api/`)

This is a thin FastAPI layer (see `API_PLAN.md`). Business rules stay in SQL. The API calls the functions and views, and maps Postgres errors to HTTP in `app/errors.py` (by SQLSTATE: `P0001`→422, `23505`→409, unknown→500 without the DB message).

- `app/db.py`: `AsyncConnectionPool` (psycopg 3, `dict_row`). Endpoints take `conn: Conn`, and `get_conn()` gives each request **one transaction**. It commits on return and rolls back on raise. `start_request()` sets `app.user_id`/`app.context` with `set_config(..., true)` for the audit log. Use `set_context(conn, "...")` for a readable audit context.
- The user currently comes from an `X-User-Id` header. That's **dev-only**, until login (build step 5).
- Tests (`tests/conftest.py`) run against the real `app` DB in a transaction that's always rolled back. Each request gets a savepoint. `make_client(app)` builds a client for any app, which `test_plumbing.py` uses for test-only routes.

`README.md` is the reviewer-facing write-up, with Mermaid diagrams. Keep it in sync when the schema changes, especially the questions-answered, assumptions and cuts sections at the end.

## Schema layout (`initdb/`)

Postgres runs these files in alphabetical order, so the number prefix sets the dependency order:

- `01-schema.sql`: tables and constraints only.
- `02-reference-data.sql`: lookup rows (`materials`, `units`, `storage_unit_kinds`). A new category, unit or kind is a new row here.
- `03-functions.sql`: views, functions and triggers.
- `04-audit.sql`: the `audit` schema, `audit.log`, the generic `log_change()` trigger on every data and reference table (not `users`), append-only protection, and `history()`/`as_of()`.

`notes.md` records known edge cases and accepted gaps.

These design decisions are settled:

- **Location:** `storage_unit` nests through its `stored_in` parent pointer (no arrays). `storage_unit_contents()` walks down the tree, with a `CYCLE` guard.
- **Kinds:** `storage_unit.kind` → `storage_unit_kinds`. Each kind says how its capacity works: `has_grid` means fixed slots, and `max_children` is a count limit. Neither is enforced yet.
- **Plates:** a plate is a `storage_unit` with `n_rows`/`n_cols`. Each well is a `vessel` with a `position`, and `UNIQUE (stored_in, position)` stops two vessels sharing a slot.
- **Quantities:** `items.quantity` + `unit` → `units` (each unit has a dimension and a factor to the base unit). A vessel's fill level is **calculated** in the `vessel_fill` view, never stored. `max_volume_ul` is a hard limit enforced by a trigger on `items`.
- **Consumption:** all material movement goes through `inventory.transfer()`, which in one atomic step decreases the parent, creates or increases the child and records `item_lineage`. Don't write `item_lineage` or change quantities by hand.
- **One liquid per vessel:** partial unique index `items_one_live_item_per_vessel`. `transfer()` into an occupied vessel empties the existing item into a new mixture item, with both as lineage parents.
- **Batches:** `transfer_batch(jsonb)` is all-or-nothing, with per-line savepoints. On failure it rolls back every line, files the raw request in `transfer_batches`/`transfer_batch_lines` (no foreign keys, on purpose) and sets `pending_review`. `apply_transfer_batch()` re-checks every line, and `reject_transfer_batch()` applies nothing.
- **Lineage:** mixtures and concoctions are ordinary `items` with several parents in `item_lineage`. There is no separate concoctions table. Lineage is a graph, so the trace functions (`item_descendants`, `item_ancestors`, `lot_trace`) return each item once, at its shortest depth.
- **Audit:** every change is logged with the old and new row as JSONB. The user and reason come from the transaction-local settings `app.user_id`/`app.context` (`set_config(..., true)`). `transaction_id` groups one action. A new data table needs its own `audit_log_change` trigger, with its primary key column(s) as the argument.
- **Barcodes:** storage units and tubes (`vessel.barcode`, optional) have barcodes. Wells are addressed as plate barcode + position.
- **Lots:** bought items set `lot_id` → `lots`, which has `UNIQUE (supplier, supplier_lot_number)`. Made items are traced back to lots through `item_lineage`.
- **Traffic light:** usability is a set of independent booleans. Recorded flags are stored (`items.in_use/reserved/in_transit/discarded/shipped`, `vessel.discarded`, `storage_unit.discarded`, `lots.qc_passed/qc_failed`). Flags that follow from other data (expired, expires_soon, empty, QC via lineage) are calculated in the `item_status` view, never stored. The colour is the most severe active flag. To add a state, add a boolean, then add one line to `red_reasons`/`yellow_reasons`. `transfer()` refuses red parents. See the table in `notes.md`.
- **Consumables:** countable consumables live in `stock`. Using one decreases its count, and any plate or tube made from it records `from_stock`.

These are still open:

- Expiry that depends on storage conditions, and an expires-soon window per material type.
- A material-definition layer, between category and lot.
- Enforcing storage-kind capacity.
