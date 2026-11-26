# Lab Inventory: Data Model

This is a PostgreSQL data model for tracking lab material. It records what the lab has, how much of it is usable, where it is, what it was made from, and what was made from it.

The main design rule is that **the database enforces correctness itself**. Quantities, capacity and usability are either enforced by constraints and triggers, or calculated from facts when they're read. They're never kept up to date by hand, so they can't drift. Other systems, such as experiment planning or a future API, can rely on the numbers.

```text
initdb/
  01-schema.sql           tables and constraints
  02-reference-data.sql   lookup rows: material categories, units, storage kinds
  03-functions.sql        views, functions and triggers (the behaviour)
notes.md                  design notes, traffic-light reference, known gaps
API_PLAN.md               draft plan for the FastAPI layer
```

## Running it

```sh
docker compose up -d
# apply the schema (initdb/ is not mounted into the container, so this is a manual step)
cat initdb/*.sql | docker compose exec -T postgres psql -U app -d app -v ON_ERROR_STOP=1
docker compose exec postgres psql -U app -d app     # SQL shell
```

To try it without keeping anything, wrap it in a transaction that gets rolled back:
`{ echo 'BEGIN;'; cat initdb/*.sql; echo 'ROLLBACK;'; } | docker compose exec -T postgres psql -U app -d app`

---

## 1. The model at a glance

```mermaid
erDiagram
    storage_unit_kinds ||--o{ storage_unit : "kind of"
    storage_unit |o--o{ storage_unit : "stored_in (nesting)"
    storage_unit ||--o{ vessel : "holds"
    storage_unit ||--o{ stock : "holds"
    stock |o--o{ storage_unit : "from_stock (plate made from stock)"
    stock |o--o{ vessel : "from_stock"
    vessel ||--o{ items : "contains"
    materials ||--o{ items : "category"
    materials ||--o{ lots : "category"
    lots |o--o{ items : "lot_id (bought items)"
    lots |o--o{ stock : "lot_id"
    units ||--o{ items : "unit"
    items ||--o{ item_lineage : "parent_item"
    items ||--o{ item_lineage : "child_item"
    users |o--o{ item_lineage : "created_by"

    storage_unit {
        TEXT barcode PK
        TEXT kind FK
        TEXT stored_in FK "parent unit, NULL = top level"
        INT n_rows "grid, e.g. 8"
        INT n_cols "grid, e.g. 12"
        BOOL discarded
    }
    vessel {
        INT id PK
        TEXT stored_in FK
        TEXT position "well/slot, e.g. A1"
        NUMERIC max_volume_ul "hard limit"
        BOOL discarded
    }
    items {
        INT id PK
        INT material FK
        INT lot_id FK "bought items only"
        INT in_vessel FK
        NUMERIC quantity
        TEXT unit FK
        TIMESTAMPTZ expires_at
        BOOL in_use
        BOOL reserved
        BOOL in_transit
        BOOL discarded
        BOOL shipped
    }
    item_lineage {
        INT parent_item PK
        INT child_item PK
        NUMERIC quantity_used "in parent's unit"
        TEXT unit FK
    }
    lots {
        INT id PK
        TEXT supplier "UNIQUE with lot number"
        TEXT supplier_lot_number
        TEXT certificate_of_analysis
        BOOL qc_passed
        BOOL qc_failed
    }
    stock {
        INT id PK
        TEXT description
        INT quantity "count"
        TEXT stored_in FK
    }
    units {
        TEXT code PK
        TEXT dimension "volume, mass, count"
        NUMERIC to_base "to uL, ug, pcs"
    }
    storage_unit_kinds {
        TEXT code PK
        BOOL has_grid
        INT max_children
    }
    materials {
        INT id PK
        TEXT name
    }
```

The model is built from four ideas:

| Concept | Table | In one sentence |
|---|---|---|
| **Where** | `storage_unit` | Rooms, freezers, racks, boxes and plates, nested to any depth through one parent pointer. |
| **In what** | `vessel` | One container of liquid: a tube, or one well of a plate. |
| **What and how much** | `items` | A physical amount of one material in one vessel, with a quantity and a unit. |
| **From what** | `item_lineage`, `lots` | Every item made from other items records its parents. Bought items record their supplier lot. |

`stock` holds countable consumables (tips, empty plates, chips). `units`, `storage_unit_kinds` and `materials` are lookup tables, so a new unit, storage kind or material category is a **new row, not a schema change**.

---

## 2. Storage locations, and things that move between them

```mermaid
flowchart TD
    R[Room: storage_unit kind=room] --> F[Freezer -80: kind=freezer]
    R --> B[Bench: kind=bench]
    F --> K[Rack A: kind=rack]
    K --> X[Box 1: kind=box, 9x9 grid]
    F --> P[Plate 1: kind=plate, 8x12 grid]
    X --> T1([Tube: vessel, position C4])
    P --> W1([Well A1: vessel])
    P --> W2([Well A2: vessel])
    T1 --> I1[[item: 800 uL target]]
    W1 --> I2[[item: 100 uL target]]
    W2 --> I3[[item: 50 uL sample]]
    W2 --> I4[[item: 50 uL buffer]]

    classDef su fill:#e8eef7,stroke:#4a6fa5
    classDef v fill:#eef7e8,stroke:#5a9a4a
    classDef it fill:#fff6e0,stroke:#c79a2a
    class R,F,B,K,X,P su
    class T1,W1,W2 v
    class I1,I2,I3,I4 it
```

- **Nesting uses a parent pointer.** `storage_unit.stored_in` references another storage unit, and NULL means a top-level place. An earlier draft also kept a list of children in an array column. That was removed, because Postgres can't enforce foreign keys on array elements, and two copies of the same relationship eventually disagree.
- **Moving something is one update.** Moving a rack to another freezer changes only the rack's `stored_in`. Everything inside it moves with it, because their own links don't change.
- **A plate is a storage unit, and each well is a vessel.** The brief says each well holds its own material. The plate's `n_rows`/`n_cols` describe its grid, and each well's `position` says where it sits. `UNIQUE (stored_in, position)` stops two vessels claiming the same well.
- **`storage_unit_kinds` says how each kind fills up.** A plate has fixed slots (`has_grid`), a rack has a count limit (`max_children`), and a room has no limit. Benches and instruments are just storage kinds, so "inside the plate reader" works like any other location.
- **`storage_unit_contents(barcode)`** returns everything inside a unit at any depth. It uses a recursive query with a `CYCLE` guard, so a mis-scan that creates a loop (A inside B inside A) can't make it run forever.

## 3. Quantities and capacity

- **Every item has `quantity` + `unit`.** `units` maps each unit to a dimension and a conversion factor (1 mL → 1000 µL), so different units can be added together and converted safely.
- **A vessel's fill level is calculated, never stored.** The `vessel_fill` view adds up the vessel's items, so it can't get out of step with them.
- **`max_volume_ul` is a hard limit**, enforced by a trigger on `items`. Overfilling a well raises an error and the whole operation is undone.
- **Duplicate deliveries are rejected:** `UNIQUE (supplier, supplier_lot_number)` stops the same lot being registered twice.

## 4. Consumption: `transfer()`

All material movement goes through one function. It takes an amount out of a parent item and puts it either into a **new item in a vessel** (aliquots, dilution copies, robot well-to-well transfers) or into an **existing item** (adding a component to a buffer or mixture). A mixture is just an item with several parents. There is no separate table for it.

```mermaid
flowchart TD
    A["transfer(parent, amount, unit, to_vessel | to_item)"] --> B{"Valid request?<br/>one target, amount &gt; 0"}
    B -- no --> X[ERROR: whole call undone]
    B -- yes --> C[Lock parent row<br/>SELECT ... FOR UPDATE]
    C --> D{Parent red?<br/>discarded, expired, QC failed...}
    D -- yes --> X
    D -- no --> E{Same dimension<br/>and enough left?}
    E -- no --> X
    E -- yes --> F[Decrease parent quantity]
    F --> G{to_vessel or to_item?}
    G -- to_vessel --> H[Create new child item]
    G -- to_item --> I[Increase existing item]
    H --> J{Vessel over capacity?<br/>trigger}
    I --> J
    J -- yes --> X
    J -- no --> K[Record item_lineage edge<br/>parent → child, quantity_used]
    K --> L[Return child id: COMMIT]

    style X fill:#fbe3e3,stroke:#c0392b
    style L fill:#e3f6e3,stroke:#2e8b57
```

- **All or nothing.** A function call is a single statement, so if any step fails, every earlier step is undone. A failed transfer can't leave the parent decreased with no child created.
- **The lock stops double-spending.** A second transfer from the same tube waits until the first one finishes, so two people can't both take the last 100 µL.
- **Yellow material can still be transferred.** QC itself uses material from a lot whose QC is pending.

```sql
SELECT _staging.transfer(1, 100, 'uL', p_to_vessel => 7);  -- aliquot 100 µL of item 1 into vessel 7
SELECT _staging.transfer(4, 2,   'mL', p_to_item   => 12); -- add 2 mL of item 4 into mixture 12
```

## 5. Lineage: where did it come from, and where did it go?

```mermaid
flowchart LR
    L1[(Lot T-778<br/>qc_failed)]:::bad --> T[Target tube<br/>item 1]:::bad
    T -- 100 uL --> A1[Well A1<br/>item 4]:::bad
    T -- 100 uL --> A2[Well A2<br/>item 5]:::bad
    A1 -- 50 uL --> M[Binding mix<br/>item 6]:::bad
    A2 -- 20 uL --> M
    L2[(Lot PBS-01<br/>qc_passed)]:::ok --> P[PBS bottle<br/>item 2]:::ok
    P -- 11 mL --> BUF[Assay buffer<br/>item 3]:::ok
    BUF -- 50 uL --> M

    classDef bad fill:#fbe3e3,stroke:#c0392b
    classDef ok fill:#e3f6e3,stroke:#2e8b57
```

Lineage is a **graph, not a tree**. A mixture has several parents, so the same item can be reached by more than one route: above, the binding mix is reached from the target through both A1 and A2. Each tracing function returns every item **once**, at its shortest distance.

| Function | Answers |
|---|---|
| `lot_trace(lot_id)` | "This target batch is bad. What did it touch?" Returns the lot's items and everything made from them. |
| `item_descendants(item_id)` | Everything made from this item, at any depth |
| `item_ancestors(item_id)` | Everything this item was made from, at any depth |

**Bought items** record their supplier lot in `lot_id`. **Made items** leave it empty and are traced back to lots through `item_lineage`, because a made item can have parents from several different lots.

## 6. Usable vs merely exists: the traffic light

Every state is an **independent boolean**. The colour is **calculated** in the `item_status` view: the most severe active flag wins, and the view also lists *why* in `red_reasons` and `yellow_reasons`.

```mermaid
flowchart LR
    subgraph Recorded["Recorded: set by people or systems"]
        direction TB
        d[discarded<br/>item / vessel / plate]
        s[shipped]
        qf[lots.qc_failed]
        qp[lots.qc_passed]
        r[reserved]
        u[in_use]
        t[in_transit]
    end
    subgraph Calculated["Calculated: worked out when read, can't go stale"]
        direction TB
        e["expired<br/>expires_at ≤ now"]
        z[empty<br/>quantity = 0]
        es[expires_soon<br/>within 7 days]
        qpe[qc_pending<br/>neither QC flag set]
        qfi[qc_failed inherited<br/>via lineage]
    end
    d & s & e & z & qf & qfi --> RED((RED<br/>not usable))
    qpe & r & u & t & es --> YEL((YELLOW<br/>usable, needs attention<br/>or spoken for))
    qp -.-> qpe
    RED ~~~ GRN((GREEN<br/>usable and free))
    YEL ~~~ GRN

    style RED fill:#e74c3c,color:#fff
    style YEL fill:#f1c40f
    style GRN fill:#2ecc71,color:#fff
```

- **Recorded or calculated?** Facts that people *record* are stored. Facts that *follow from other data* (expired, empty, QC inherited through lineage) are calculated each time they're read. A stored "expired" flag would need a job to flip it at midnight, and one missed run would make the data wrong.
- **Each flag lives on the object it describes.** QC belongs to the **lot**, so failing a lot later turns **everything made from it red, at any depth**, without updating a single item. Discarding belongs to the **container**, so throwing a plate away turns all its wells red.
- **Contradictory combinations are blocked** by `CHECK` constraints: a lot can't be both `qc_passed` and `qc_failed`, and an item can't be both `discarded` and `shipped`.
- **Adding a state** means adding a boolean, then adding one line to `red_reasons` or `yellow_reasons`. The colour updates automatically.
- **`material_quantities`** gives totals per material category and colour. That answers the brief's question "how much do we have, and how much of it is usable?"

---

## 7. How the brief's questions are answered

| # | Question | Answered by |
|---|---|---|
| 1 | How much do we have, and how much is usable? | `material_quantities` view; `item_status.light` per item |
| 2 | Is it still viable? What expires soon? | `item_status` flags `expired` and `expires_soon` |
| 3 | Where is it? | `items.in_vessel` → `vessel.stored_in` → `storage_unit.stored_in` chain; `storage_unit_contents()` |
| 4 | Where did it come from and where did it go? | `lot_trace()`, `item_ancestors()`, `item_descendants()` |
| 5 | Who changed what, and when? | **Not built yet** (see below) |

## 8. Assumptions

- **Experiment planning is a separate system.** It *sets* `reserved`, and the inventory only stores it.
- **QC applies per supplier lot.** A lot is pending until one of `qc_passed`/`qc_failed` is set. Material made in-house has no lot, so it has no QC state.
- **Aliquots inherit the parent's `expires_at`.**
- **Capacity is only enforced for volume.** Mass and count items in a vessel don't count towards its fill.
- **Moving material between different dimensions is rejected.** `transfer()` won't add µg of DNA into a µL buffer, because concentration isn't modelled.
- **Lab scale:** the tracing and status views recurse through lineage for each item. That's fine for thousands of items. At much larger scale you'd cache the results.

## 9. What was cut, and why

Depth on consumption, lineage and usability was prioritised over breadth.

| Cut | Why, and what it would take |
|---|---|
| **Audit log (Q5)** | The most important remaining piece. Plan: an `audit_log` table filled by a generic trigger that stores the old and new row as JSONB, plus the user from a session variable set by the API. The `users` table is already in place for this. |
| **Barcodes on vessels** | Storage units have barcodes, but tubes don't yet. It needs `vessel.barcode TEXT UNIQUE`. |
| **Expiry that depends on storage conditions** | The brief says lifetime depends on storage and timing. It needs a storage temperature per kind, plus shelf-life rules per material and condition. Today `expires_at` is set directly. |
| **Expires-soon window per material** | It's a fixed 7 days. Loading buffer only lasts 1 week in total, so it would show yellow from the day it's made. |
| **Material-definition layer** | `materials` holds categories (DNA, Target proteins…). A real system needs "target protein PD-L1" between the category and the lot. |
| **Enforcing storage-kind capacity** | `has_grid`/`max_children` describe the rules, but no trigger enforces them yet. Grid positions aren't checked against the grid size either. |
| **Full location path function** | Walking *up* the tree ("Room > Freezer > Rack > Box"). It's the mirror of `storage_unit_contents`. |
| **Edge cases accepted** | Lowering a vessel's `max_volume_ul` isn't checked. Discarding only looks one level up (vessel → its plate). Locking is per item, so two concurrent inserts into the same well could each pass the capacity check. |
