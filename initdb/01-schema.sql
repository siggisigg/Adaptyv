-- 01-schema.sql: tables and constraints only.
-- Lookup data lives in 02-reference-data.sql; functions, views and triggers in 03-functions.sql.
-- Postgres runs files in initdb/ in alphabetical order, so the numbering encodes dependencies.

CREATE SCHEMA IF NOT EXISTS _staging;

CREATE TABLE users
(
    id SERIAL PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE materials
(
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL
);

-- Units of measure. Each unit belongs to a dimension and converts to that dimension's
-- base unit (uL for volume, ug for mass, pcs for count), so quantities can be summed.
-- A new unit is a new row, with no schema change.
CREATE TABLE units (
    code             TEXT PRIMARY KEY,
    dimension        TEXT NOT NULL CHECK (dimension IN ('volume', 'mass', 'count')),
    to_base          NUMERIC NOT NULL CHECK (to_base > 0)
);

-- Kinds of storage unit, and how each one's capacity works:
--   has_grid      -> capacity is a fixed set of slots (plate wells, box positions)
--   max_children  -> capacity is a count of things inside (NULL = no limit tracked, e.g. a room)
-- A new kind is a new row, with no schema change.
CREATE TABLE storage_unit_kinds (
    code             TEXT PRIMARY KEY,
    description      TEXT,
    has_grid         BOOLEAN NOT NULL DEFAULT FALSE,
    max_children     INTEGER CHECK (max_children > 0)
);

-- A supplier lot: what a delivery came from. Bad-batch tracing starts here.
CREATE TABLE _staging.lots (
    id                       SERIAL PRIMARY KEY,
    material                 INTEGER NOT NULL REFERENCES materials(id),
    supplier                 TEXT NOT NULL,
    supplier_lot_number      TEXT NOT NULL,
    certificate_of_analysis  TEXT,         -- link/path to the CoA document
    received_at              TIMESTAMPTZ,
    comment                  TEXT,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Traffic-light flags (see item_status in 03-functions.sql). QC pending = neither flag set.
    -- Items made from this lot inherit these through item_lineage.
    qc_passed                BOOLEAN NOT NULL DEFAULT FALSE,
    qc_failed                BOOLEAN NOT NULL DEFAULT FALSE,
    UNIQUE (supplier, supplier_lot_number),  -- registering the same lot twice fails
    CHECK (NOT (qc_passed AND qc_failed))    -- mutually exclusive outcomes
);

CREATE TABLE _staging.storage_unit (
    barcode          TEXT UNIQUE PRIMARY KEY,
    kind             TEXT NOT NULL REFERENCES storage_unit_kinds(code),
    description      TEXT,
    -- nested_units     INTEGER[],  -- storage_unit.barcode values; Postgres cannot enforce FKs on array elements
    stored_in        TEXT REFERENCES _staging.storage_unit(barcode),
    n_rows           INTEGER CHECK (n_rows > 0),   -- grid layout for plates/boxes (8 x 12 for a 96-well plate)
    n_cols           INTEGER CHECK (n_cols > 0),
    from_stock       INTEGER,                -- FK added after the stock table exists (see below)
    updated_at       TIMESTAMPTZ,
    comment          TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    discarded        BOOLEAN NOT NULL DEFAULT FALSE,  -- e.g. plate thrown away; makes items in its vessels red
    CHECK ((n_rows IS NULL) = (n_cols IS NULL))  -- a grid has both dimensions or neither
);

-- Countable consumables that sit on a shelf: boxes of tips, empty plates, chips.
-- Using one decreases `quantity`; if it becomes a plate or tube, the new
-- storage_unit / vessel row records where it came from in `from_stock`.
CREATE TABLE _staging.stock (
    id               SERIAL PRIMARY KEY,
    material         INTEGER NOT NULL REFERENCES materials(id),
    lot_id           INTEGER REFERENCES _staging.lots(id),
    description      TEXT NOT NULL,          -- e.g. '96-well plate, Greiner 655101'
    quantity         INTEGER NOT NULL CHECK (quantity >= 0),
    stored_in        TEXT NOT NULL REFERENCES _staging.storage_unit(barcode),
    updated_at       TIMESTAMPTZ,
    comment          TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- storage_unit and stock reference each other, so one of the FKs has to be added afterwards.
ALTER TABLE _staging.storage_unit
    ADD FOREIGN KEY (from_stock) REFERENCES _staging.stock(id);

-- A single container of liquid: a tube, or one well of a plate.
CREATE TABLE _staging.vessel (
    id               SERIAL PRIMARY KEY,
    name             TEXT NOT NULL,
    stored_in        TEXT NOT NULL REFERENCES _staging.storage_unit(barcode),
    position         TEXT,                   -- slot in the parent's grid, e.g. 'A1'; NULL if not in a grid
    max_volume_ul    NUMERIC CHECK (max_volume_ul > 0),  -- hard capacity limit, in uL
    from_stock       INTEGER REFERENCES _staging.stock(id),
    updated_at       TIMESTAMPTZ,
    comment          TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    discarded        BOOLEAN NOT NULL DEFAULT FALSE,  -- tube thrown away, possibly with material still inside
    UNIQUE (stored_in, position)             -- two vessels can't share a slot (NULL positions are exempt)
);

-- A physical amount of material in a vessel. Bought items point to their lot;
-- made items (dilutions, aliquots, mixtures/concoctions) are traced through item_lineage.
CREATE TABLE _staging.items (
    id               SERIAL PRIMARY KEY,
    description      TEXT,
    material         INTEGER NOT NULL REFERENCES materials(id),
    manufacturer     TEXT,
    lot_id           INTEGER REFERENCES _staging.lots(id),  -- set for bought items, NULL for made ones
    in_vessel        INTEGER NOT NULL REFERENCES _staging.vessel(id),
    quantity         NUMERIC NOT NULL CHECK (quantity >= 0),
    unit             TEXT NOT NULL REFERENCES units(code),
    updated_at       TIMESTAMPTZ,
    comment          TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at       TIMESTAMPTZ,
    -- Traffic-light flags: recorded facts only. Facts that follow from other data
    -- (expired, empty, QC) are calculated in item_status, so they can't go stale.
    -- New state = new BOOLEAN NOT NULL DEFAULT FALSE column + one line in item_status.
    in_use           BOOLEAN NOT NULL DEFAULT FALSE,   -- yellow: on the bench / in an instrument right now
    reserved         BOOLEAN NOT NULL DEFAULT FALSE,   -- yellow: set by experiment planning
    in_transit       BOOLEAN NOT NULL DEFAULT FALSE,   -- yellow: on the move between locations
    discarded        BOOLEAN NOT NULL DEFAULT FALSE,   -- red: thrown away
    shipped          BOOLEAN NOT NULL DEFAULT FALSE,   -- red: left the lab
    CHECK (NOT (discarded AND shipped))                -- an item leaves the inventory one way
);

-- Which items were made from which. One row per parent -> child edge:
--   aliquot split: 1 parent, many children
--   mixture/buffer: many parents, 1 child
-- quantity_used is how much of the parent went into the child, in the PARENT's unit.
-- Rows are written by _staging.transfer() (03-functions.sql), not by hand.
CREATE TABLE _staging.item_lineage (
    parent_item      INTEGER NOT NULL REFERENCES _staging.items(id),
    child_item       INTEGER NOT NULL REFERENCES _staging.items(id),
    quantity_used    NUMERIC NOT NULL CHECK (quantity_used > 0),
    unit             TEXT NOT NULL REFERENCES units(code),
    created_by       INTEGER REFERENCES users(id),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (parent_item, child_item),
    CHECK (parent_item <> child_item)
);
