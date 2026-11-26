-- 03-functions.sql: views, functions and triggers built on the tables in 01-schema.sql.
--
-- Naming: views start with v_. A view stores nothing: it is a saved query that calculates
-- its result from the tables every time it is read, so it can't go stale. It also can't have
-- foreign keys, which is why SQL clients draw no relationship lines to it.

-------------------------------------------------------------------------------
-- Location
-------------------------------------------------------------------------------

-- Everything nested inside a storage unit, at any depth (replaces the old nested_units array).
-- Usage: SELECT * FROM inventory.storage_unit_contents('FREEZER-01');
CREATE FUNCTION inventory.storage_unit_contents(parent_barcode TEXT)
RETURNS TABLE (barcode TEXT, description TEXT, stored_in TEXT, depth INTEGER)
LANGUAGE sql
STABLE  -- only reads data, so Postgres may optimise calls within one query
AS $$
    WITH RECURSIVE tree AS (
        -- anchor: the parent itself (depth 0), so cycle detection knows it was visited
        SELECT su.barcode, su.description, su.stored_in, 0 AS depth
        FROM inventory.storage_unit su
        WHERE su.barcode = parent_barcode
        UNION ALL
        -- recursive step: units inside anything already found
        SELECT su.barcode, su.description, su.stored_in, tree.depth + 1
        FROM inventory.storage_unit su
        JOIN tree ON su.stored_in = tree.barcode
    ) CYCLE barcode SET is_cycle USING visited  -- stops if bad data forms a loop (Postgres 14+)
    SELECT tree.barcode, tree.description, tree.stored_in, tree.depth
    FROM tree
    WHERE NOT tree.is_cycle
      AND tree.depth > 0  -- exclude the parent itself
    ORDER BY tree.depth, tree.barcode;
$$;

-- Full location of a storage unit, walking UP the tree: 'ROOM-1 > FRZ-1 > RACK-A > BOX-1'.
-- The mirror of storage_unit_contents(), with the same CYCLE guard.
-- Usage: SELECT inventory.location_path('BOX-1');
CREATE FUNCTION inventory.location_path(p_barcode TEXT)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    WITH RECURSIVE up AS (
        SELECT su.barcode, su.stored_in, 0 AS depth
        FROM inventory.storage_unit su
        WHERE su.barcode = p_barcode
        UNION ALL
        SELECT su.barcode, su.stored_in, up.depth + 1
        FROM inventory.storage_unit su
        JOIN up ON su.barcode = up.stored_in
    ) CYCLE barcode SET is_cycle USING visited
    SELECT string_agg(up.barcode, ' > ' ORDER BY up.depth DESC)
    FROM up
    WHERE NOT up.is_cycle;
$$;

-------------------------------------------------------------------------------
-- Vessel capacity
-------------------------------------------------------------------------------

-- How full each vessel is, calculated from its items (never stored, so it can't drift).
-- Only items measured by volume count towards the fill; mass/count units are ignored.
CREATE VIEW inventory.v_vessel_fill AS
SELECT
    v.id                                   AS vessel_id,
    v.max_volume_ul,
    COALESCE(SUM(i.quantity * u.to_base) FILTER (WHERE u.dimension = 'volume'), 0) AS total_volume_ul,
    v.max_volume_ul
      - COALESCE(SUM(i.quantity * u.to_base) FILTER (WHERE u.dimension = 'volume'), 0) AS free_volume_ul
FROM inventory.vessel v
LEFT JOIN inventory.items i ON i.in_vessel = v.id
LEFT JOIN units u          ON u.code = i.unit
GROUP BY v.id;

-- Enforce max_volume_ul as a hard limit whenever an item is added to, changed in, or moved into a vessel.
-- Known gap (accepted): lowering a vessel's max_volume_ul below its current fill is not checked.
CREATE FUNCTION inventory.check_vessel_capacity()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    fill inventory.v_vessel_fill%ROWTYPE;
BEGIN
    SELECT * INTO fill FROM inventory.v_vessel_fill WHERE vessel_id = NEW.in_vessel;
    IF fill.max_volume_ul IS NOT NULL AND fill.total_volume_ul > fill.max_volume_ul THEN
        RAISE EXCEPTION 'Vessel % over capacity: % uL of % uL',
            NEW.in_vessel, fill.total_volume_ul, fill.max_volume_ul;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER items_check_vessel_capacity
AFTER INSERT OR UPDATE OF quantity, unit, in_vessel ON inventory.items
FOR EACH ROW EXECUTE FUNCTION inventory.check_vessel_capacity();

-------------------------------------------------------------------------------
-- Consumption: moving material from one item into another
-------------------------------------------------------------------------------

-- Take p_amount (in p_unit) out of item p_parent and put it either
--   * into vessel p_to_vessel                 (aliquot, dilution copy, well-by-well transfer), or
--   * into an EXISTING item p_to_item         (adding a component to a buffer being made).
--
-- One liquid per vessel: a vessel holds at most one item with quantity > 0 (enforced by
-- the partial unique index items_one_live_item_per_vessel). So transferring into a vessel:
--   * that is empty    -> creates a new item (same material as the parent)
--   * that has content -> empties the existing item into a NEW MIXTURE item, whose lineage
--                         records both the existing content and the parent as its parents.
--                         The mixture's material is p_material if given, else the parent's;
--                         it expires at the earliest expiry of its inputs.
--
-- Decreasing the parent, creating/increasing the child and recording lineage happen together:
-- if any step fails (not enough left, vessel full, wrong unit), none of them happen.
-- Returns the id of the item that now holds the material.
--
-- Usage:
--   SELECT inventory.transfer(1, 100, 'uL', p_to_vessel => 7);   -- 100 uL of item 1 into vessel 7
--   SELECT inventory.transfer(4, 2, 'mL',  p_to_item   => 12);   -- add 2 mL of item 4 into item 12
CREATE FUNCTION inventory.transfer(
    p_parent     INTEGER,
    p_amount     NUMERIC,
    p_unit       TEXT,
    p_to_vessel  INTEGER DEFAULT NULL,
    p_to_item    INTEGER DEFAULT NULL,
    p_user       INTEGER DEFAULT NULL,
    p_material   INTEGER DEFAULT NULL   -- material for a new mixture; default: the parent's
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    parent       inventory.items%ROWTYPE;
    child        inventory.items%ROWTYPE;   -- p_to_item, or the existing content of p_to_vessel
    amount_unit  units%ROWTYPE;
    parent_unit  units%ROWTYPE;
    child_unit   units%ROWTYPE;
    taken        NUMERIC;   -- p_amount converted into the parent's unit
    child_id     INTEGER;
    status       RECORD;    -- the parent's row from v_item_status
    acting_user  INTEGER := COALESCE(p_user, NULLIF(current_setting('app.user_id', true), '')::INTEGER);
BEGIN
    -- 1. Validate the request
    IF (p_to_vessel IS NULL) = (p_to_item IS NULL) THEN
        RAISE EXCEPTION 'Give exactly one of p_to_vessel or p_to_item';
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be positive, got %', p_amount;
    END IF;
    IF p_to_item = p_parent THEN
        RAISE EXCEPTION 'Cannot transfer item % into itself', p_parent;
    END IF;

    -- 2. Lock the parent row: a second transfer from the same item waits here
    --    until this one commits, so two transfers can't both spend the same volume.
    SELECT * INTO parent FROM inventory.items WHERE id = p_parent FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Item % does not exist', p_parent;
    END IF;

    -- Red material can't be used. Yellow is allowed: QC itself consumes material from
    -- a pending lot, and planning decides what to do with reserved / in-use items.
    SELECT * INTO status FROM inventory.v_item_status WHERE item_id = p_parent;
    IF status.light = 'red' THEN
        RAISE EXCEPTION 'Item % is red (%) and cannot be used',
            p_parent, array_to_string(status.red_reasons, ', ');
    END IF;

    SELECT * INTO amount_unit FROM units WHERE code = p_unit;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown unit %', p_unit;
    END IF;
    SELECT * INTO parent_unit FROM units WHERE code = parent.unit;

    -- 3. Convert to the parent's unit and check there is enough
    IF amount_unit.dimension <> parent_unit.dimension THEN
        RAISE EXCEPTION 'Item % is measured in % (%), cannot take an amount in % (%)',
            p_parent, parent.unit, parent_unit.dimension, p_unit, amount_unit.dimension;
    END IF;
    taken := trim_scale(p_amount * amount_unit.to_base / parent_unit.to_base);  -- trim_scale drops trailing zeros from division
    IF taken > parent.quantity THEN
        RAISE EXCEPTION 'Item % has only % %, cannot take % %',
            p_parent, parent.quantity, parent.unit, p_amount, p_unit;
    END IF;

    -- 4. Take it out of the parent
    UPDATE inventory.items
    SET quantity = quantity - taken, updated_at = now()
    WHERE id = p_parent;

    -- 5. Put it into the child (the capacity trigger checks the child's vessel here)
    IF p_to_vessel IS NOT NULL THEN
        SELECT * INTO child FROM inventory.items
        WHERE in_vessel = p_to_vessel AND quantity > 0
        FOR UPDATE;

        IF NOT FOUND THEN
            -- 5a. Empty vessel: new item, same material, inherits the parent's expiry.
            --     lot_id stays NULL because made items are traced to their lot through lineage.
            INSERT INTO inventory.items
                (description, material, manufacturer, in_vessel, quantity, unit, expires_at)
            VALUES
                (parent.description, COALESCE(p_material, parent.material), parent.manufacturer,
                 p_to_vessel, p_amount, p_unit, parent.expires_at)
            RETURNING id INTO child_id;
        ELSE
            -- 5b. Vessel has content: the two liquids become one mixture item.
            IF child.id = p_parent THEN
                RAISE EXCEPTION 'Item % is already in vessel %: source and target are the same', p_parent, p_to_vessel;
            END IF;
            SELECT * INTO child_unit FROM units WHERE code = child.unit;
            IF child_unit.dimension <> amount_unit.dimension THEN
                RAISE EXCEPTION 'Vessel % holds item % measured in % (%), cannot add an amount in % (%)',
                    p_to_vessel, child.id, child.unit, child_unit.dimension, p_unit, amount_unit.dimension;
            END IF;

            -- Empty the existing item first, so the one-live-item index and the capacity
            -- trigger see the vessel correctly when the mixture is inserted.
            UPDATE inventory.items SET quantity = 0, updated_at = now() WHERE id = child.id;

            INSERT INTO inventory.items
                (description, material, in_vessel, quantity, unit, expires_at)
            VALUES
                (concat_ws(' + ', child.description, parent.description),
                 COALESCE(p_material, parent.material),
                 p_to_vessel,
                 child.quantity + trim_scale(p_amount * amount_unit.to_base / child_unit.to_base),
                 child.unit,
                 LEAST(child.expires_at, parent.expires_at))   -- LEAST ignores NULLs
            RETURNING id INTO child_id;

            -- The existing content is the mixture's other parent.
            INSERT INTO inventory.item_lineage (parent_item, child_item, quantity_used, unit, created_by)
            VALUES (child.id, child_id, child.quantity, child.unit, acting_user);
        END IF;
    ELSE
        SELECT * INTO child FROM inventory.items WHERE id = p_to_item FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Item % does not exist', p_to_item;
        END IF;
        SELECT * INTO child_unit FROM units WHERE code = child.unit;
        IF child_unit.dimension <> amount_unit.dimension THEN
            RAISE EXCEPTION 'Item % is measured in % (%), cannot add an amount in % (%)',
                p_to_item, child.unit, child_unit.dimension, p_unit, amount_unit.dimension;
        END IF;
        UPDATE inventory.items
        SET quantity = quantity + trim_scale(p_amount * amount_unit.to_base / child_unit.to_base), updated_at = now()
        WHERE id = p_to_item;
        child_id := p_to_item;
    END IF;

    -- 6. Record lineage. Adding from the same parent into the same mixture twice
    --    accumulates onto the existing edge instead of failing on the primary key.
    INSERT INTO inventory.item_lineage (parent_item, child_item, quantity_used, unit, created_by)
    VALUES (p_parent, child_id, taken, parent.unit, acting_user)
    ON CONFLICT (parent_item, child_item)
    DO UPDATE SET quantity_used = inventory.item_lineage.quantity_used + EXCLUDED.quantity_used;

    RETURN child_id;
END;
$$;

-------------------------------------------------------------------------------
-- Lineage tracing (brief question 4: where did it come from, where did it go?)
-------------------------------------------------------------------------------
-- Lineage is a graph, not a tree: a mixture has several parents, so the same item
-- can be reached by more than one path. Each function therefore returns every item
-- once, at the shortest distance (MIN(depth)).

-- Everything made from an item, at any depth.
-- Usage: SELECT * FROM inventory.item_descendants(1);
CREATE FUNCTION inventory.item_descendants(p_item INTEGER)
RETURNS TABLE (item_id INTEGER, depth INTEGER)
LANGUAGE sql
STABLE
AS $$
    WITH RECURSIVE tree AS (
        SELECT p_item AS item_id, 0 AS depth
        UNION ALL
        SELECT l.child_item, tree.depth + 1
        FROM inventory.item_lineage l
        JOIN tree ON l.parent_item = tree.item_id
    ) CYCLE item_id SET is_cycle USING visited
    SELECT tree.item_id, MIN(tree.depth)
    FROM tree
    WHERE NOT tree.is_cycle AND tree.depth > 0
    GROUP BY tree.item_id
    ORDER BY 2, 1;
$$;

-- Everything an item was made from, at any depth.
-- Usage: SELECT * FROM inventory.item_ancestors(42);
CREATE FUNCTION inventory.item_ancestors(p_item INTEGER)
RETURNS TABLE (item_id INTEGER, depth INTEGER)
LANGUAGE sql
STABLE
AS $$
    WITH RECURSIVE tree AS (
        SELECT p_item AS item_id, 0 AS depth
        UNION ALL
        SELECT l.parent_item, tree.depth + 1
        FROM inventory.item_lineage l
        JOIN tree ON l.child_item = tree.item_id
    ) CYCLE item_id SET is_cycle USING visited
    SELECT tree.item_id, MIN(tree.depth)
    FROM tree
    WHERE NOT tree.is_cycle AND tree.depth > 0
    GROUP BY tree.item_id
    ORDER BY 2, 1;
$$;

-- Every item that came from a supplier lot: the bought items themselves (depth 0)
-- and everything made from them. This answers "this target batch is bad, what did it touch?"
-- Usage: SELECT * FROM inventory.lot_trace(3);
CREATE FUNCTION inventory.lot_trace(p_lot INTEGER)
RETURNS TABLE (item_id INTEGER, depth INTEGER)
LANGUAGE sql
STABLE
AS $$
    WITH RECURSIVE tree AS (
        SELECT i.id AS item_id, 0 AS depth
        FROM inventory.items i
        WHERE i.lot_id = p_lot
        UNION ALL
        SELECT l.child_item, tree.depth + 1
        FROM inventory.item_lineage l
        JOIN tree ON l.parent_item = tree.item_id
    ) CYCLE item_id SET is_cycle USING visited
    SELECT tree.item_id, MIN(tree.depth)
    FROM tree
    WHERE NOT tree.is_cycle
    GROUP BY tree.item_id
    ORDER BY 2, 1;
$$;

-------------------------------------------------------------------------------
-- Traffic light: usable vs merely exists
-------------------------------------------------------------------------------
-- Every state is a boolean. Two kinds:
--   recorded   - stored columns people set (in_use, reserved, in_transit, discarded, shipped,
--                lots.qc_passed / qc_failed)
--   calculated - follow from other data, so they are worked out here and can't go stale
--                (expired, expires_soon, empty, qc_pending, qc_failed via lineage)
--
-- Colour = the most severe active flag:
--   red    - not usable: it's gone, used up, expired or failed QC
--   yellow - usable, but something needs attention or it's spoken for
--   green  - usable and free
--
-- ADDING A STATE: add the boolean (as a column in 01-schema.sql, or calculated in `flags`
-- below), then add ONE line to red_reasons or yellow_reasons. The colour follows automatically.

CREATE VIEW inventory.v_item_status AS
WITH qc AS (
    -- QC flags come from every lot the item depends on: its own lot plus its ancestors' lots.
    -- So failing a lot turns everything made from it red, at any depth.
    SELECT
        i.id AS item_id,
        COALESCE(bool_or(l.qc_failed), FALSE)                        AS qc_failed,
        COALESCE(bool_or(NOT l.qc_passed AND NOT l.qc_failed), FALSE) AS qc_pending
    FROM inventory.items i
    LEFT JOIN LATERAL (
        SELECT i.lot_id
        UNION
        SELECT ai.lot_id
        FROM inventory.item_ancestors(i.id) a
        JOIN inventory.items ai ON ai.id = a.item_id
    ) src ON TRUE
    LEFT JOIN inventory.lots l ON l.id = src.lot_id
    GROUP BY i.id
),
flags AS (
    SELECT
        i.id AS item_id, i.material, i.quantity, i.unit, i.in_vessel, i.expires_at,
        -- recorded
        i.in_use,
        i.reserved,
        i.in_transit,
        i.shipped,
        i.pending_review,
        (i.discarded OR v.discarded OR su.discarded)                                  AS discarded,  -- item, its tube, or its plate
        -- calculated
        COALESCE(i.expires_at <= now(), FALSE)                                        AS expired,
        COALESCE(i.expires_at >  now() AND i.expires_at <= now() + INTERVAL '7 days', FALSE) AS expires_soon,
        (i.quantity = 0)                                                              AS empty,
        qc.qc_failed,
        qc.qc_pending
    FROM inventory.items i
    JOIN inventory.vessel v        ON v.id = i.in_vessel
    JOIN inventory.storage_unit su ON su.barcode = v.stored_in
    JOIN qc                       ON qc.item_id = i.id
),
reasons AS (
    SELECT
        f.*,
        array_remove(ARRAY[
            CASE WHEN f.discarded    THEN 'discarded'    END,
            CASE WHEN f.shipped      THEN 'shipped'      END,
            CASE WHEN f.expired      THEN 'expired'      END,
            CASE WHEN f.empty        THEN 'empty'        END,
            CASE WHEN f.qc_failed    THEN 'qc_failed'    END
        ], NULL) AS red_reasons,
        array_remove(ARRAY[
            CASE WHEN f.qc_pending   THEN 'qc_pending'   END,
            CASE WHEN f.reserved     THEN 'reserved'     END,
            CASE WHEN f.in_use       THEN 'in_use'       END,
            CASE WHEN f.in_transit   THEN 'in_transit'   END,
            CASE WHEN f.pending_review THEN 'pending_review' END,
            CASE WHEN f.expires_soon THEN 'expires_soon' END
        ], NULL) AS yellow_reasons
    FROM flags f
)
SELECT
    r.*,
    CASE
        WHEN cardinality(r.red_reasons)    > 0 THEN 'red'
        WHEN cardinality(r.yellow_reasons) > 0 THEN 'yellow'
        ELSE 'green'
    END AS light
FROM reasons r;

-- Brief question 1: how much do we have, and how much of it is usable?
-- Totals per material category and colour, in each dimension's base unit (uL / ug / pcs).
-- Usage: SELECT * FROM inventory.v_material_quantities WHERE material = 'Target proteins';
CREATE VIEW inventory.v_material_quantities AS
SELECT
    m.name                       AS material,
    u.dimension,
    s.light,
    COUNT(*)                     AS n_items,
    SUM(s.quantity * u.to_base)  AS total_base_unit
FROM inventory.v_item_status s
JOIN materials m ON m.id = s.material
JOIN units u     ON u.code = s.unit
GROUP BY m.name, u.dimension, s.light;

-------------------------------------------------------------------------------
-- Batches: many transfers as one lab action (e.g. a whole plate)
-------------------------------------------------------------------------------
-- All or nothing. If every line succeeds, the batch is applied and nothing extra is stored
-- (the audit log groups it by transaction_id). If ANY line fails:
--   * every line is undone, so the inventory never records a half-done plate;
--   * the request is filed in transfer_batches / transfer_batch_lines with, per line,
--     whether it would have succeeded and why not;
--   * the items involved get the yellow pending_review flag;
--   * the call still COMMITS (the filing must be kept) and returns the per-line report.
-- A person then resolves it later, in a separate transaction:
--   apply_transfer_batch() (re-checks every line), or reject_transfer_batch().
-- Accepted: while a batch is pending the database may not match the bench (the robot may
-- have physically run). The pending_review flag makes that visible instead of hiding it.

-- Items a batch touches: the parents, the target items, and items in the target vessels.
-- p_live_only: only items with quantity > 0 (used when flagging; clearing looks at all).
CREATE FUNCTION inventory.transfer_batch_items(p_batch INTEGER, p_live_only BOOLEAN)
RETURNS SETOF INTEGER
LANGUAGE sql
STABLE
AS $$
    SELECT l.parent_item FROM inventory.transfer_batch_lines l WHERE l.batch_id = p_batch
    UNION
    SELECT l.to_item     FROM inventory.transfer_batch_lines l WHERE l.batch_id = p_batch
    UNION
    SELECT i.id
    FROM inventory.transfer_batch_lines l
    JOIN inventory.items i ON i.in_vessel = l.to_vessel
    WHERE l.batch_id = p_batch AND (NOT p_live_only OR i.quantity > 0);
$$;

-- p_lines: JSON array of {"parent": int, "amount": num, "unit": text, "to_vessel": int} or {..., "to_item": int}
-- Usage:
--   SELECT * FROM inventory.transfer_batch('[{"parent": 4, "amount": 20, "unit": "uL", "to_vessel": 101},
--                                            {"parent": 5, "amount": 20, "unit": "uL", "to_vessel": 102}]');
CREATE FUNCTION inventory.transfer_batch(p_lines JSONB)
RETURNS TABLE (line_no INTEGER, ok BOOLEAN, child_item INTEGER, error TEXT, filed_batch INTEGER)
LANGUAGE plpgsql
AS $$
#variable_conflict use_column
DECLARE
    line        RECORD;
    oks         BOOLEAN[] := '{}';
    children    INTEGER[] := '{}';
    errors      TEXT[]    := '{}';
    any_failed  BOOLEAN   := FALSE;
    new_child   INTEGER;
    new_batch   INTEGER;
BEGIN
    IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'p_lines must be a non-empty JSON array';
    END IF;

    -- Outer block = a savepoint around the whole batch.
    BEGIN
        FOR line IN
            SELECT t.ord, t.e
            FROM jsonb_array_elements(p_lines) WITH ORDINALITY AS t(e, ord)
            ORDER BY t.ord
        LOOP
            -- Inner block = a savepoint per line: a failure undoes only this line,
            -- is recorded, and the loop carries on so every line gets checked.
            BEGIN
                new_child := inventory.transfer(
                    (line.e ->> 'parent')::INTEGER,
                    (line.e ->> 'amount')::NUMERIC,
                    line.e ->> 'unit',
                    p_to_vessel => (line.e ->> 'to_vessel')::INTEGER,
                    p_to_item   => (line.e ->> 'to_item')::INTEGER);
                oks      := array_append(oks, TRUE);
                children := array_append(children, new_child);
                errors   := array_append(errors, NULL::TEXT);
            EXCEPTION WHEN OTHERS THEN
                oks        := array_append(oks, FALSE);
                children   := array_append(children, NULL::INTEGER);
                errors     := array_append(errors, SQLERRM);
                any_failed := TRUE;
            END;
        END LOOP;

        IF any_failed THEN
            -- Undo every line that did succeed. Raising inside the outer block rolls the
            -- database back to its savepoint; local variables (oks, errors) keep their values.
            RAISE EXCEPTION USING ERRCODE = 'IB001', MESSAGE = 'batch has failed lines';
        END IF;
    EXCEPTION WHEN SQLSTATE 'IB001' THEN
        NULL;
    END;

    IF NOT any_failed THEN
        RETURN QUERY
        SELECT i, TRUE, children[i], NULL::TEXT, NULL::INTEGER
        FROM generate_subscripts(oks, 1) AS i;
        RETURN;
    END IF;

    -- File the batch for review.
    INSERT INTO inventory.transfer_batches (context, requested_by)
    VALUES (NULLIF(current_setting('app.context', true), ''),
            NULLIF(current_setting('app.user_id', true), '')::INTEGER)
    RETURNING id INTO new_batch;

    INSERT INTO inventory.transfer_batch_lines
        (batch_id, line_no, parent_item, amount, unit, to_vessel, to_item, would_succeed, error)
    SELECT new_batch, t.ord,
           (t.e ->> 'parent')::INTEGER, (t.e ->> 'amount')::NUMERIC, t.e ->> 'unit',
           (t.e ->> 'to_vessel')::INTEGER, (t.e ->> 'to_item')::INTEGER,
           oks[t.ord], errors[t.ord]
    FROM jsonb_array_elements(p_lines) WITH ORDINALITY AS t(e, ord);

    UPDATE inventory.items it
    SET pending_review = TRUE
    WHERE it.id IN (SELECT inventory.transfer_batch_items(new_batch, TRUE));

    RETURN QUERY
    SELECT i, oks[i], NULL::INTEGER, errors[i], new_batch
    FROM generate_subscripts(oks, 1) AS i;
END;
$$;

-- Clear pending_review on a resolved batch's items, unless another pending batch still touches them.
CREATE FUNCTION inventory.clear_pending_review(p_batch INTEGER)
RETURNS VOID
LANGUAGE sql
AS $$
    UPDATE inventory.items it
    SET pending_review = FALSE
    WHERE it.pending_review
      AND it.id IN (SELECT inventory.transfer_batch_items(p_batch, FALSE))
      AND NOT EXISTS (
          SELECT 1 FROM inventory.transfer_batches b
          WHERE b.id <> p_batch AND NOT b.applied AND NOT b.rejected
            AND it.id IN (SELECT inventory.transfer_batch_items(b.id, FALSE)));
$$;

-- Apply a filed batch. Every line goes through transfer() again against the inventory as it
-- is NOW (the stored "would succeed" may be stale). Still all or nothing: if a line fails,
-- nothing is applied and the batch stays pending. The reviewer can first fix lines with a
-- plain UPDATE on transfer_batch_lines (audited), or pass p_only_ok => TRUE to apply only the
-- lines that originally succeeded; the failed lines stay on record for a physical check.
-- Usage: SELECT * FROM inventory.apply_transfer_batch(3, p_note => 'B7 volume corrected');
CREATE FUNCTION inventory.apply_transfer_batch(
    p_batch    INTEGER,
    p_only_ok  BOOLEAN DEFAULT FALSE,
    p_note     TEXT    DEFAULT NULL
)
RETURNS TABLE (line_no INTEGER, child_item INTEGER)
LANGUAGE plpgsql
AS $$
#variable_conflict use_column
DECLARE
    batch  inventory.transfer_batches%ROWTYPE;
    l      inventory.transfer_batch_lines%ROWTYPE;
BEGIN
    SELECT * INTO batch FROM inventory.transfer_batches WHERE id = p_batch FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Batch % does not exist', p_batch;
    END IF;
    IF batch.applied OR batch.rejected THEN
        RAISE EXCEPTION 'Batch % is already resolved', p_batch;
    END IF;

    FOR l IN
        SELECT * FROM inventory.transfer_batch_lines bl
        WHERE bl.batch_id = p_batch AND (NOT p_only_ok OR bl.would_succeed)
        ORDER BY bl.line_no
    LOOP
        BEGIN
            child_item := inventory.transfer(l.parent_item, l.amount, l.unit,
                                             p_to_vessel => l.to_vessel, p_to_item => l.to_item);
        EXCEPTION WHEN OTHERS THEN
            -- Re-raise with the line number; the error aborts the whole apply.
            RAISE EXCEPTION 'Batch %, line %: %', p_batch, l.line_no, SQLERRM;
        END;
        line_no := l.line_no;
        RETURN NEXT;
    END LOOP;

    UPDATE inventory.transfer_batches
    SET applied = TRUE,
        resolved_by = NULLIF(current_setting('app.user_id', true), '')::INTEGER,
        resolved_at = now(),
        resolution_note = concat_ws(' | ', p_note, CASE WHEN p_only_ok THEN 'applied successful lines only' END)
    WHERE id = p_batch;

    PERFORM inventory.clear_pending_review(p_batch);
END;
$$;

-- Reject a filed batch: nothing is applied; the flags are cleared.
-- Usage: SELECT inventory.reject_transfer_batch(3, 'robot run aborted, plate discarded');
CREATE FUNCTION inventory.reject_transfer_batch(p_batch INTEGER, p_note TEXT DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE inventory.transfer_batches
    SET rejected = TRUE,
        resolved_by = NULLIF(current_setting('app.user_id', true), '')::INTEGER,
        resolved_at = now(),
        resolution_note = p_note
    WHERE id = p_batch AND NOT applied AND NOT rejected;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Batch % does not exist or is already resolved', p_batch;
    END IF;

    PERFORM inventory.clear_pending_review(p_batch);
END;
$$;
