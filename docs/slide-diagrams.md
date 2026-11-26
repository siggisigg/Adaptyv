# Slide diagrams

These are extra diagrams for the presentation only. `docs/render-diagrams.sh` renders them after the README's diagrams.

The full ER diagram in the README is too tall for one slide, so it's split here into two halves. The core tables (`storage_unit`, `vessel`, `items`) appear in both halves so each slide stands on its own.

## Location and quantity: where things are, and how much

```mermaid
%% file: er-location-quantity
erDiagram
    storage_unit_kinds ||--o{ storage_unit : "kind of"
    storage_unit |o--o{ storage_unit : "stored_in (nesting)"
    storage_unit ||--o{ vessel : "holds"
    storage_unit ||--o{ stock : "holds"
    stock |o--o{ storage_unit : "from_stock (plate made from stock)"
    stock |o--o{ vessel : "from_stock"
    vessel ||--o{ items : "contains (one live item)"
    units ||--o{ items : "unit"
    materials ||--o{ items : "category"

    storage_unit_kinds {
        TEXT code PK
        BOOL has_grid "fixed slots"
        INT max_children "count limit"
    }
    storage_unit {
        TEXT barcode PK
        TEXT kind FK
        TEXT stored_in FK "parent, NULL = top level"
        INT n_rows
        INT n_cols
        BOOL discarded
    }
    stock {
        INT id PK
        TEXT description
        INT quantity "count"
        TEXT stored_in FK
    }
    vessel {
        INT id PK
        TEXT barcode "tubes only"
        TEXT stored_in FK
        TEXT position "e.g. A1"
        NUMERIC max_volume_ul "hard limit"
        BOOL discarded
    }
    items {
        INT id PK
        INT in_vessel FK
        INT material FK
        NUMERIC quantity
        TEXT unit FK
        TIMESTAMPTZ expires_at
    }
    units {
        TEXT code PK
        TEXT dimension "volume, mass, count"
        NUMERIC to_base "to uL, ug, pcs"
    }
    materials {
        INT id PK
        TEXT name
    }
```

## Tracing and control: where it came from, who changed it, what's usable

```mermaid
%% file: er-tracing-control
erDiagram
    materials ||--o{ lots : "category"
    lots |o--o{ items : "lot_id (bought items)"
    items ||--o{ item_lineage : "parent_item"
    items ||--o{ item_lineage : "child_item"
    users |o--o{ item_lineage : "created_by"
    users |o--o{ transfer_batches : "requested_by"
    transfer_batches ||--o{ transfer_batch_lines : "lines (raw request, no FKs)"
    users |o--o{ audit_log : "changed_by"

    materials {
        INT id PK
        TEXT name
    }
    lots {
        INT id PK
        TEXT supplier "UNIQUE with lot number"
        TEXT supplier_lot_number
        TEXT certificate_of_analysis
        BOOL qc_passed
        BOOL qc_failed
    }
    items {
        INT id PK
        INT lot_id FK "bought items only"
        INT in_vessel FK
        NUMERIC quantity
        BOOL in_use
        BOOL reserved
        BOOL in_transit
        BOOL discarded
        BOOL shipped
        BOOL pending_review
    }
    item_lineage {
        INT parent_item PK
        INT child_item PK
        NUMERIC quantity_used "in parent's unit"
        TEXT unit FK
    }
    users {
        INT id PK
        TEXT username
    }
    transfer_batches {
        INT id PK
        TEXT context
        BOOL applied
        BOOL rejected
    }
    transfer_batch_lines {
        INT batch_id PK
        INT line_no PK
        INT parent_item "raw, no FK"
        NUMERIC amount
        BOOL would_succeed
        TEXT error
    }
    audit_log {
        BIGINT id PK
        BIGINT transaction_id "groups one action"
        TEXT table_name
        TEXT row_key
        JSONB old_row
        JSONB new_row
    }
```
