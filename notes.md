## DONE: query for "what's inside a storage unit"

Implemented as `inventory.storage_unit_contents(parent_barcode TEXT)`, using a SQL function with a `CYCLE` guard. The notes below are the reasoning behind it.

`storage_unit.nested_units` was commented out. It duplicated `stored_in` (the parent pointer) and couldn't have foreign keys. The lookup it gave should come back as a stored query instead.

- **Direct children** are just `SELECT * FROM inventory.storage_unit WHERE stored_in = <barcode>`.
- **Everything nested underneath at any depth** (box in rack in freezer) needs a `WITH RECURSIVE` query that walks *down* the `stored_in` links.
- **Ways to "pre-compile" it in Postgres:**
  - **View.** A saved SELECT. Good for "full location path of every unit", but a view can't take a parameter such as a barcode.
  - **SQL function** like `storage_unit_contents(barcode INTEGER) RETURNS TABLE(...)`. It takes the barcode as a parameter and the API can call it. This is probably the best fit.
  - **`PREPARE`.** It only lasts for one database session, so it's useless as a stored query. Drivers like psycopg already do something similar for you.
- **The reverse direction**, "full location path of X", walks *up* `stored_in` (see the recursive query used in testing). It's a candidate for the same treatment.
- **Cycles** (A inside B inside A) are still possible and would make a recursive query run forever. Either add a cycle guard (a `CYCLE` clause, Postgres 14+, or a depth limit), or prevent cycles when data is written.

## Known edge cases and accepted gaps

- **Lowering a vessel's `max_volume_ul`** below its current fill isn't checked. The capacity trigger only fires on changes to `items`. Accepted as an edge case, since a vessel's capacity rarely changes after it's created.
- **Storage-kind capacity isn't enforced yet.** `storage_unit_kinds` records *how* each kind fills up (`has_grid` = fixed slots, `max_children` = a count limit), but no trigger checks it. Grid positions aren't checked against `n_rows`/`n_cols` either, so "Z99" would be accepted.
- **Mixing different dimensions** (for example adding µg of DNA powder to a µL buffer) is rejected by `transfer()`. Concentration (µg/µL) isn't modelled.
- **Aliquots inherit the parent's `expires_at`.** Expiry that depends on storage conditions comes with the status/expiry model.

## Traffic light (usable vs merely exists)

Every state is an independent boolean, and the colour is **calculated** from them in `inventory.item_status`. The most severe active flag wins. The view also lists *why* in `red_reasons` and `yellow_reasons`.

| Flag | Colour | Kind | Lives on | Meaning |
|---|---|---|---|---|
| `discarded` | red | recorded | item, vessel, storage_unit | Thrown away. A discarded tube or plate makes its contents red. |
| `shipped` | red | recorded | item | Left the lab |
| `expired` | red | calculated | `expires_at <= now()` | Past its shelf life |
| `empty` | red | calculated | `quantity = 0` | Used up |
| `qc_failed` | red | recorded on lot, inherited | lots + lineage | Its lot, or any ancestor's lot, failed QC |
| `qc_pending` | yellow | calculated | lots + lineage | QC hasn't reached a verdict (neither passed nor failed) |
| `reserved` | yellow | recorded | item | Spoken for by experiment planning |
| `in_use` | yellow | recorded | item | On the bench or in an instrument right now |
| `in_transit` | yellow | recorded | item | Being moved |
| `expires_soon` | yellow | calculated | `expires_at` within 7 days | Use it first, or plan a reorder |

- **Why some flags are calculated:** a stored "expired" flag would need a job to flip it at midnight, and a missed run means wrong data. In OOP terms, calculated flags are `@property`, not fields.
- **Why QC is on the lot:** failing a lot later turns *everything made from it* red automatically, at any depth, through `item_ancestors`. That's the bad-batch scenario from the brief, with no update to any item.
- **Contradictions blocked by `CHECK`:** `qc_passed AND qc_failed`, and `discarded AND shipped`.
- **`transfer()` refuses red parents.** Yellow is allowed, because QC itself consumes material from a pending lot.
- **Adding a state:** add the boolean column (or calculate it in `flags`), then add one line to `red_reasons` or `yellow_reasons`.
- **For planning:** green = usable and free now. Yellow = usable but needs attention or is spoken for. `material_quantities` gives totals per category and colour (brief Q1).

Open points:
- The 7-day "expires soon" window is one fixed value, but loading buffer only lasts 1 week. It should be set per material type.
- Discarding only looks one level up (vessel → its storage unit). A thrown-away box inside a discarded rack isn't caught.
- In-house made material has no QC (no lot), so it never shows `qc_pending`.
- `item_status` calls `item_ancestors()` for every item, which is fine at lab scale. At large scale you'd cache it (materialised view) or store a denormalised lot set.
- Recorded flags don't say *who* set them or *when*. That's for the audit log.
