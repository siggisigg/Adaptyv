-- 03-functions.sql: views, functions and triggers built on the tables in 01-schema.sql.

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

-------------------------------------------------------------------------------
-- Vessel capacity
-------------------------------------------------------------------------------

-- How full each vessel is, calculated from its items (never stored, so it can't drift).
-- Only items measured by volume count towards the fill; mass/count units are ignored.
CREATE VIEW inventory.vessel_fill AS
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
    fill inventory.vessel_fill%ROWTYPE;
BEGIN
    SELECT * INTO fill FROM inventory.vessel_fill WHERE vessel_id = NEW.in_vessel;
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
--   * into a NEW item in vessel p_to_vessel   (aliquot, dilution copy, well-by-well transfer), or
--   * into an EXISTING item p_to_item         (adding a component to a mixture/buffer).
-- Decreasing the parent, creating/increasing the child and recording lineage happen together:
-- if any step fails (not enough left, vessel full, wrong unit), none of them happen.
-- Returns the child item's id.
--
-- Usage:
--   SELECT inventory.transfer(1, 100, 'uL', p_to_vessel => 7);   -- aliquot 100 uL into vessel 7
--   SELECT inventory.transfer(4, 2, 'mL',  p_to_item   => 12);   -- add 2 mL of item 4 into mixture 12
CREATE FUNCTION inventory.transfer(
    p_parent     INTEGER,
    p_amount     NUMERIC,
    p_unit       TEXT,
    p_to_vessel  INTEGER DEFAULT NULL,
    p_to_item    INTEGER DEFAULT NULL,
    p_user       INTEGER DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    parent       inventory.items%ROWTYPE;
    child        inventory.items%ROWTYPE;
    amount_unit  units%ROWTYPE;
    parent_unit  units%ROWTYPE;
    child_unit   units%ROWTYPE;
    taken        NUMERIC;   -- p_amount converted into the parent's unit
    child_id     INTEGER;
    status       RECORD;    -- the parent's row from item_status
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
    SELECT * INTO status FROM inventory.item_status WHERE item_id = p_parent;
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
        -- New item: same material, inherits the parent's expiry. lot_id stays NULL
        -- because made items are traced to their lot through lineage.
        INSERT INTO inventory.items
            (description, material, manufacturer, in_vessel, quantity, unit, expires_at)
        VALUES
            (parent.description, parent.material, parent.manufacturer, p_to_vessel, p_amount, p_unit, parent.expires_at)
        RETURNING id INTO child_id;
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
    VALUES (p_parent, child_id, taken, parent.unit,
            COALESCE(p_user, NULLIF(current_setting('app.user_id', true), '')::INTEGER))  -- fall back to the API's request user
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

CREATE VIEW inventory.item_status AS
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
-- Usage: SELECT * FROM inventory.material_quantities WHERE material = 'Target proteins';
CREATE VIEW inventory.material_quantities AS
SELECT
    m.name                       AS material,
    u.dimension,
    s.light,
    COUNT(*)                     AS n_items,
    SUM(s.quantity * u.to_base)  AS total_base_unit
FROM inventory.item_status s
JOIN materials m ON m.id = s.material
JOIN units u     ON u.code = s.unit
GROUP BY m.name, u.dimension, s.light;
