-- 05-demo-data.sql: a small, realistic lab, so every feature can be seen in a fresh database.
-- Delete this file (then `docker compose down -v && docker compose up -d`) for an empty database.
--
-- Everything that moves material goes through the real database functions (transfer(),
-- transfer_batch()), one action per transaction with a user and a context, exactly as the API
-- would do it. So the lineage, mixtures, audit log and the failed robot run are all genuine.
--
-- The story:
--   1. Alice sets up the lab: rooms, freezers, a rack with tube boxes, consumables on a shelf.
--   2. Bob receives deliveries: three target proteins (PD-L1, HER2, EGFR), DNA, PBS.
--      QC passes for PD-L1, HER2, DNA and PBS; EGFR (arrived yesterday) is still pending.
--   3. Alice makes loading buffer from PBS (1-week life). An old GFP stock tube has expired.
--   4. Alice expresses 12 samples into plate PL-0001 (taken from plate stock).
--   5. The robot copies all 12 samples into BLI plate PL-0002 on the reader, then adds PD-L1
--      to every well: each well becomes a sample + target MIXTURE with two lineage parents.
--   6. Bob aliquots HER2 and runs a 4-well HER2 plate (PL-0003). Then re-QC finds the HER2 lot
--      bad: everything made from it turns red, without a single item being updated.
--   7. Bob takes 100 uL from PL-0001 A5 for a re-run. The robot's next run (50 uL from every
--      well into PL-0004) fails on A5: nothing is applied, the run is FILED for review, and the
--      wells involved show pending_review.
--   8. Odds and ends: a GFP plate is thrown away with material inside, a DNA aliquot is shipped
--      to a customer, PD-L1 is reserved for an experiment, EGFR is in transit, a box is moved.

-- Session-only helpers (pg_temp disappears when this script ends) ---------------------------

CREATE FUNCTION pg_temp.act(p_user TEXT, p_context TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    -- What the API does at the start of every request: who is acting, and why.
    PERFORM set_config('app.user_id', (SELECT id::TEXT FROM users WHERE username = p_user), true);
    PERFORM set_config('app.context', p_context, true);
END $$;

CREATE FUNCTION pg_temp.vessel(p_barcode TEXT) RETURNS INTEGER LANGUAGE sql AS $$
    SELECT id FROM inventory.vessel WHERE barcode = p_barcode $$;

CREATE FUNCTION pg_temp.well(p_plate TEXT, p_position TEXT) RETURNS INTEGER LANGUAGE sql AS $$
    SELECT id FROM inventory.vessel WHERE stored_in = p_plate AND position = p_position $$;

CREATE FUNCTION pg_temp.live_item(p_vessel INTEGER) RETURNS INTEGER LANGUAGE sql AS $$
    SELECT id FROM inventory.items WHERE in_vessel = p_vessel AND quantity > 0 $$;

-- Take one 96-well plate from stock: decrement the count, create the plate and wells A1..A<n>.
CREATE FUNCTION pg_temp.plate_from_stock(p_barcode TEXT, p_in TEXT, p_wells INTEGER, p_description TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE stock_id INTEGER;
BEGIN
    UPDATE inventory.stock SET quantity = quantity - 1, updated_at = now()
    WHERE description = '96-well plate, 300 uL' RETURNING id INTO stock_id;
    INSERT INTO inventory.storage_unit (barcode, kind, stored_in, description, n_rows, n_cols, from_stock)
    VALUES (p_barcode, 'plate', p_in, p_description, 8, 12, stock_id);
    INSERT INTO inventory.vessel (name, stored_in, position, max_volume_ul)
    SELECT 'well', p_barcode, 'A' || n, 300 FROM generate_series(1, p_wells) n;
END $$;

-- Lines for transfer_batch(): <amount> uL from each well A1..A<n> of one plate (or one tube)
-- into the same position on another plate.
CREATE FUNCTION pg_temp.plate_lines(p_from TEXT, p_to TEXT, p_wells INTEGER, p_amount NUMERIC, p_from_tube TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE sql AS $$
    SELECT jsonb_agg(jsonb_build_object(
        'parent',    pg_temp.live_item(COALESCE(pg_temp.vessel(p_from_tube), pg_temp.well(p_from, 'A' || n))),
        'amount',    p_amount,
        'unit',      'uL',
        'to_vessel', pg_temp.well(p_to, 'A' || n)) ORDER BY n)
    FROM generate_series(1, p_wells) n $$;

-- People -------------------------------------------------------------------------------------
-- '!' = no usable password: login isn't built yet (the API takes X-User-Id in development).
INSERT INTO users (username, password_hash) VALUES ('alice', '!'), ('bob', '!'), ('robot-1', '!');

-- 1. Lab setup ---------------------------------------------------------------------------------
BEGIN;
SELECT pg_temp.act('alice', 'lab setup');
INSERT INTO inventory.storage_unit (barcode, kind, stored_in, description, n_rows, n_cols) VALUES
    ('LAB-1',    'room',       NULL,       'Main lab',                 NULL, NULL),
    ('FRZ-80-1', 'freezer',    'LAB-1',    '-80 C freezer',            NULL, NULL),
    ('FRZ-20-1', 'freezer',    'LAB-1',    '-20 C freezer',            NULL, NULL),
    ('FRIDGE-1', 'fridge',     'LAB-1',    '4 C fridge',               NULL, NULL),
    ('SHELF-1',  'shelf',      'LAB-1',    'Consumables shelf',        NULL, NULL),
    ('BENCH-1',  'bench',      'LAB-1',    'Bench 1',                  NULL, NULL),
    ('READER-1', 'instrument', 'LAB-1',    'BLI plate reader',         NULL, NULL),
    ('RACK-A',   'rack',       'FRZ-80-1', 'Rack A',                   NULL, NULL),
    ('BOX-A1',   'box',        'RACK-A',   'Targets and DNA',          9,    9),
    ('BOX-A2',   'box',        'RACK-A',   'Spare box',                9,    9);
INSERT INTO inventory.stock (material, description, quantity, stored_in) VALUES
    (5, '96-well plate, 300 uL',      20, 'SHELF-1'),
    (5, 'Pipette tips 200 uL, box',   40, 'SHELF-1'),
    (5, 'BLI biosensor chip',         12, 'SHELF-1');
COMMIT;

-- 2. Deliveries and QC -------------------------------------------------------------------------
BEGIN;
SELECT pg_temp.act('bob', 'receive deliveries');
INSERT INTO inventory.lots (material, supplier, supplier_lot_number, certificate_of_analysis, received_at) VALUES
    (3, 'AcroBio',     'PDL1-2409-A', 'coa/PDL1-2409-A.pdf', now() - INTERVAL '30 days'),
    (3, 'SinoProt',    'HER2-2410-B', 'coa/HER2-2410-B.pdf', now() - INTERVAL '20 days'),
    (3, 'AcroBio',     'EGFR-2411-C', 'coa/EGFR-2411-C.pdf', now() - INTERVAL '1 day'),
    (1, 'GeneTwist',   'TW-24-3321',  'coa/TW-24-3321.pdf',  now() - INTERVAL '40 days'),
    (6, 'ChemSupply',  'PBS-77',      'coa/PBS-77.pdf',      now() - INTERVAL '60 days');
INSERT INTO inventory.vessel (barcode, name, stored_in, position, max_volume_ul) VALUES
    ('TB-0001', 'PD-L1 stock',  'BOX-A1',  'A1', 1500),
    ('TB-0002', 'HER2 stock',   'BOX-A1',  'A2', 1500),
    ('TB-0003', 'EGFR stock',   'BOX-A1',  'A3', 1500),
    ('TB-0004', 'DNA construct','BOX-A1',  'A4', 1500),
    ('BT-0001', 'PBS bottle',   'SHELF-1', NULL, 1000000);
INSERT INTO inventory.items (description, material, lot_id, in_vessel, quantity, unit, expires_at) VALUES
    ('PD-L1 target',  3, 1, pg_temp.vessel('TB-0001'), 500, 'uL', now() + INTERVAL '5 years'),
    ('HER2 target',   3, 2, pg_temp.vessel('TB-0002'), 400, 'uL', now() + INTERVAL '5 years'),
    ('EGFR target',   3, 3, pg_temp.vessel('TB-0003'), 300, 'uL', now() + INTERVAL '5 years'),
    ('DNA construct', 1, 4, pg_temp.vessel('TB-0004'), 50,  'ug', now() + INTERVAL '10 years'),
    ('PBS',           6, 5, pg_temp.vessel('BT-0001'), 500, 'mL', now() + INTERVAL '2 years');
COMMIT;

BEGIN;
SELECT pg_temp.act('alice', 'QC on received lots');
UPDATE inventory.lots SET qc_passed = TRUE WHERE supplier_lot_number IN ('PDL1-2409-A', 'HER2-2410-B', 'TW-24-3321', 'PBS-77');
COMMIT;

-- 3. Buffers -----------------------------------------------------------------------------------
BEGIN;
SELECT pg_temp.act('alice', 'make loading buffer');
INSERT INTO inventory.vessel (barcode, name, stored_in, max_volume_ul) VALUES ('BT-0002', 'loading buffer', 'FRIDGE-1', 50000);
SELECT inventory.transfer(pg_temp.live_item(pg_temp.vessel('BT-0001')), 45, 'mL',
                          p_to_vessel => pg_temp.vessel('BT-0002'), p_material => 4);
-- Loading buffer lasts 1 week; this batch was made 2 days ago.
UPDATE inventory.items SET description = 'loading buffer', expires_at = now() + INTERVAL '5 days'
WHERE id = pg_temp.live_item(pg_temp.vessel('BT-0002'));
COMMIT;

BEGIN;
SELECT pg_temp.act('alice', 'migrated from spreadsheet: old GFP stock');
INSERT INTO inventory.vessel (barcode, name, stored_in, max_volume_ul) VALUES ('TB-0005', 'GFP stock buffer', 'FRZ-20-1', 2000);
INSERT INTO inventory.items (description, material, in_vessel, quantity, unit, expires_at)
VALUES ('GFP stock buffer', 4, pg_temp.vessel('TB-0005'), 1, 'mL', now() - INTERVAL '3 days');
COMMIT;

-- 4. Sample expression plate -------------------------------------------------------------------
BEGIN;
SELECT pg_temp.act('alice', 'express samples S-01..S-12 into PL-0001');
SELECT pg_temp.plate_from_stock('PL-0001', 'FRZ-80-1', 12, 'Expression plate, customer batch 7');
-- Expressed in-house (from DNA by mass, so not a volume transfer): received into the wells directly.
INSERT INTO inventory.items (description, material, in_vessel, quantity, unit, expires_at)
SELECT 'sample S-' || lpad(n::TEXT, 2, '0'), 2, pg_temp.well('PL-0001', 'A' || n), 150, 'uL', now() + INTERVAL '12 days'
FROM generate_series(1, 12) n;
COMMIT;

-- 5. BLI plate: copy samples, add PD-L1 (mixtures) ---------------------------------------------
BEGIN;
SELECT pg_temp.act('robot-1', 'plate transfer PL-0001 -> PL-0002, 20 uL x 12 wells');
SELECT pg_temp.plate_from_stock('PL-0002', 'READER-1', 12, 'BLI plate, PD-L1 binding');
SELECT count(*) AS lines, bool_and(ok) AS all_ok
FROM inventory.transfer_batch(pg_temp.plate_lines('PL-0001', 'PL-0002', 12, 20));
COMMIT;

BEGIN;
SELECT pg_temp.act('robot-1', 'add PD-L1 to PL-0002, 10 uL x 12 wells');
SELECT count(*) AS lines, bool_and(ok) AS all_ok
FROM inventory.transfer_batch(pg_temp.plate_lines(NULL, 'PL-0002', 12, 10, p_from_tube => 'TB-0001'));
UPDATE inventory.items SET in_use = TRUE
WHERE in_vessel IN (SELECT id FROM inventory.vessel WHERE stored_in = 'PL-0002') AND quantity > 0;
COMMIT;

-- 6. HER2: aliquots, a plate, then the lot turns out bad ---------------------------------------
BEGIN;
SELECT pg_temp.act('bob', 'aliquot HER2');
INSERT INTO inventory.vessel (barcode, name, stored_in, position, max_volume_ul) VALUES
    ('TB-0006', 'HER2 aliquot', 'BOX-A1', 'B1', 500),
    ('TB-0007', 'HER2 aliquot', 'BOX-A1', 'B2', 500);
SELECT inventory.transfer(pg_temp.live_item(pg_temp.vessel('TB-0002')), 100, 'uL', p_to_vessel => pg_temp.vessel('TB-0006'));
SELECT inventory.transfer(pg_temp.live_item(pg_temp.vessel('TB-0002')), 100, 'uL', p_to_vessel => pg_temp.vessel('TB-0007'));
COMMIT;

BEGIN;
SELECT pg_temp.act('bob', 'HER2 binding plate PL-0003');
SELECT pg_temp.plate_from_stock('PL-0003', 'FRZ-80-1', 4, 'BLI plate, HER2 binding');
SELECT count(*) AS lines, bool_and(ok) AS all_ok FROM inventory.transfer_batch(pg_temp.plate_lines('PL-0001', 'PL-0003', 4, 20));
SELECT count(*) AS lines, bool_and(ok) AS all_ok FROM inventory.transfer_batch(pg_temp.plate_lines(NULL, 'PL-0003', 4, 10, p_from_tube => 'TB-0006'));
COMMIT;

BEGIN;
SELECT pg_temp.act('alice', 'HER2 lot HER2-2410-B failed re-QC (aggregation)');
UPDATE inventory.lots SET qc_passed = FALSE, qc_failed = TRUE WHERE supplier_lot_number = 'HER2-2410-B';
COMMIT;

-- 7. A robot run that fails on one well ------------------------------------------------------
BEGIN;
SELECT pg_temp.act('bob', 'take S-05 for a re-run');
INSERT INTO inventory.vessel (barcode, name, stored_in, max_volume_ul) VALUES ('TB-0008', 'S-05 re-run', 'BENCH-1', 500);
SELECT inventory.transfer(pg_temp.live_item(pg_temp.well('PL-0001', 'A5')), 100, 'uL', p_to_vessel => pg_temp.vessel('TB-0008'));
COMMIT;

BEGIN;
SELECT pg_temp.act('robot-1', 'plate transfer PL-0001 -> PL-0004, 50 uL x 12 wells (robot run 2)');
SELECT pg_temp.plate_from_stock('PL-0004', 'BENCH-1', 12, 'BLI plate, run 2');
-- A5 only has 30 uL left: this run is NOT applied, it is filed for review.
SELECT line_no, ok, error, filed_batch
FROM inventory.transfer_batch(pg_temp.plate_lines('PL-0001', 'PL-0004', 12, 50))
WHERE NOT ok;
COMMIT;

-- 8. Odds and ends ---------------------------------------------------------------------------
BEGIN;
SELECT pg_temp.act('alice', 'GFP plate PL-0005, used and thrown away');
SELECT pg_temp.plate_from_stock('PL-0005', 'BENCH-1', 3, 'GFP plate');
SELECT count(*) AS lines, bool_and(ok) AS all_ok
FROM inventory.transfer_batch((
    SELECT jsonb_agg(jsonb_build_object('parent', pg_temp.live_item(pg_temp.well('PL-0001', 'A' || (n + 5))),
                                        'amount', 10, 'unit', 'uL', 'to_vessel', pg_temp.well('PL-0005', 'A' || n)))
    FROM generate_series(1, 3) n));
UPDATE inventory.storage_unit SET discarded = TRUE, updated_at = now() WHERE barcode = 'PL-0005';
COMMIT;

BEGIN;
SELECT pg_temp.act('bob', 'DNA aliquot shipped to customer');
INSERT INTO inventory.vessel (barcode, name, stored_in, position, max_volume_ul) VALUES ('TB-0009', 'DNA aliquot', 'BOX-A1', 'A5', 1500);
SELECT inventory.transfer(pg_temp.live_item(pg_temp.vessel('TB-0004')), 10, 'ug', p_to_vessel => pg_temp.vessel('TB-0009'));
UPDATE inventory.items SET shipped = TRUE WHERE id = pg_temp.live_item(pg_temp.vessel('TB-0009'));
COMMIT;

BEGIN;
SELECT pg_temp.act('alice', 'reserved for experiment EXP-42');
UPDATE inventory.items SET reserved = TRUE WHERE id = pg_temp.live_item(pg_temp.vessel('TB-0001'));
COMMIT;

BEGIN;
SELECT pg_temp.act('bob', 'EGFR to the bench for QC');
UPDATE inventory.items SET in_transit = TRUE WHERE id = pg_temp.live_item(pg_temp.vessel('TB-0003'));
COMMIT;

BEGIN;
SELECT pg_temp.act('alice', 'reorganise freezers');
UPDATE inventory.storage_unit SET stored_in = 'FRZ-20-1', updated_at = now() WHERE barcode = 'BOX-A2';
COMMIT;
