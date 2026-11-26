-- 04-audit.sql: who changed what, when, and what the record said before (brief question 5).
--
-- How it works:
--   * One generic trigger function, attached to every data table, writes a row to audit.log
--     for each INSERT / UPDATE / DELETE, with the full old and new row as JSONB.
--   * The acting user and a free-text context come from transaction-local settings that the
--     API sets at the start of each request:
--         SELECT set_config('app.user_id', '7', true);                 -- true = SET LOCAL
--         SELECT set_config('app.context', 'plate transfer PLATE-1 -> PLATE-2', true);
--   * transaction_id groups every change made by one action (e.g. 96 well transfers in one
--     API request share one id), so a bulk action can be reviewed as a unit.
--   * The log is append-only: updating or deleting audit rows is rejected.

CREATE SCHEMA IF NOT EXISTS audit;

CREATE TABLE audit.log (
    id               BIGSERIAL PRIMARY KEY,
    changed_at       TIMESTAMPTZ NOT NULL DEFAULT now(),          -- transaction start time: same for one action
    transaction_id   BIGINT      NOT NULL DEFAULT txid_current(),
    changed_by       INTEGER REFERENCES users(id),                -- from app.user_id; NULL if not set
    db_role          TEXT        NOT NULL DEFAULT current_user,   -- catches changes made outside the API (e.g. psql)
    context          TEXT,                                        -- from app.context: why / which action
    table_name       TEXT        NOT NULL,                        -- e.g. 'inventory.items'
    row_key          TEXT        NOT NULL,                        -- primary key value(s), comma-joined if composite
    action           TEXT        NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
    changed_columns  TEXT[],                                      -- UPDATE only: which columns actually changed
    old_row          JSONB,                                       -- NULL for INSERT
    new_row          JSONB                                        -- NULL for DELETE
);

CREATE INDEX ON audit.log (table_name, row_key);   -- "history of this record"
CREATE INDEX ON audit.log (transaction_id);        -- "everything this action did"
CREATE INDEX ON audit.log (changed_by);            -- "everything this person did"

-------------------------------------------------------------------------------
-- The trigger
-------------------------------------------------------------------------------
-- TG_ARGV[0] names the table's primary key column(s), comma-separated, because the
-- tables use different keys (id, barcode, code, or parent_item+child_item).
CREATE FUNCTION audit.log_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER                  -- runs with the owner's rights, so callers need no INSERT on audit.log
SET search_path = pg_catalog, public  -- standard SECURITY DEFINER hygiene: no lookup hijacking
AS $$
DECLARE
    old_j        JSONB := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END;
    new_j        JSONB := CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END;
    changed      TEXT[];
    key_value    TEXT;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        -- Compare old and new column by column; keep only the ones that differ.
        SELECT array_agg(n.key ORDER BY n.key) INTO changed
        FROM jsonb_each(new_j) n
        WHERE n.value IS DISTINCT FROM old_j -> n.key;

        IF changed IS NULL THEN
            RETURN NULL;   -- an UPDATE that changed nothing isn't worth logging
        END IF;
    END IF;

    -- Build the row key from the primary key column(s) named in the trigger argument.
    SELECT string_agg(COALESCE(new_j, old_j) ->> pk.col, ',' ORDER BY pk.ord) INTO key_value
    FROM unnest(string_to_array(TG_ARGV[0], ',')) WITH ORDINALITY AS pk(col, ord);

    INSERT INTO audit.log (changed_by, context, table_name, row_key, action, changed_columns, old_row, new_row)
    VALUES (
        NULLIF(current_setting('app.user_id', true), '')::INTEGER,   -- true = return NULL if never set
        NULLIF(current_setting('app.context', true), ''),
        TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
        key_value,
        TG_OP,
        changed,
        old_j,
        new_j
    );
    RETURN NULL;   -- AFTER trigger: the return value is ignored
END;
$$;

-- Data tables
CREATE TRIGGER audit_log_change AFTER INSERT OR UPDATE OR DELETE ON inventory.lots
    FOR EACH ROW EXECUTE FUNCTION audit.log_change('id');
CREATE TRIGGER audit_log_change AFTER INSERT OR UPDATE OR DELETE ON inventory.storage_unit
    FOR EACH ROW EXECUTE FUNCTION audit.log_change('barcode');
CREATE TRIGGER audit_log_change AFTER INSERT OR UPDATE OR DELETE ON inventory.stock
    FOR EACH ROW EXECUTE FUNCTION audit.log_change('id');
CREATE TRIGGER audit_log_change AFTER INSERT OR UPDATE OR DELETE ON inventory.vessel
    FOR EACH ROW EXECUTE FUNCTION audit.log_change('id');
CREATE TRIGGER audit_log_change AFTER INSERT OR UPDATE OR DELETE ON inventory.items
    FOR EACH ROW EXECUTE FUNCTION audit.log_change('id');
CREATE TRIGGER audit_log_change AFTER INSERT OR UPDATE OR DELETE ON inventory.item_lineage
    FOR EACH ROW EXECUTE FUNCTION audit.log_change('parent_item,child_item');

-- Reference tables: changing a unit's to_base silently changes every quantity in that unit,
-- so these are audited too.
CREATE TRIGGER audit_log_change AFTER INSERT OR UPDATE OR DELETE ON materials
    FOR EACH ROW EXECUTE FUNCTION audit.log_change('id');
CREATE TRIGGER audit_log_change AFTER INSERT OR UPDATE OR DELETE ON units
    FOR EACH ROW EXECUTE FUNCTION audit.log_change('code');
CREATE TRIGGER audit_log_change AFTER INSERT OR UPDATE OR DELETE ON storage_unit_kinds
    FOR EACH ROW EXECUTE FUNCTION audit.log_change('code');

-- `users` is deliberately NOT audited by this trigger: the row contains password_hash,
-- which shouldn't be copied into a log that many people can read.

-------------------------------------------------------------------------------
-- Append-only
-------------------------------------------------------------------------------
-- Rejects edits to the log itself. A superuser could still drop this trigger; the real
-- protection is that the API's database role only gets SELECT on audit.*. It can still
-- cause audit rows to be written, because log_change() is SECURITY DEFINER, but it can't
-- write, edit or delete them itself.
CREATE FUNCTION audit.reject_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'audit.log is append-only: % is not allowed', TG_OP;
END;
$$;

CREATE TRIGGER audit_log_append_only BEFORE UPDATE OR DELETE ON audit.log
    FOR EACH ROW EXECUTE FUNCTION audit.reject_change();
CREATE TRIGGER audit_log_no_truncate BEFORE TRUNCATE ON audit.log
    FOR EACH STATEMENT EXECUTE FUNCTION audit.reject_change();

-------------------------------------------------------------------------------
-- Reading the log
-------------------------------------------------------------------------------

-- Every change to one record, oldest first.
-- Usage: SELECT * FROM audit.history('inventory.items', '3');
--        SELECT * FROM audit.history('inventory.storage_unit', 'PLATE-1');
CREATE FUNCTION audit.history(p_table TEXT, p_key TEXT)
RETURNS SETOF audit.log
LANGUAGE sql
STABLE
AS $$
    SELECT * FROM audit.log
    WHERE table_name = p_table AND row_key = p_key
    ORDER BY id;
$$;

-- What a record looked like at a point in time ("what did it say before the change?").
-- Returns NULL if the record didn't exist yet, or had been deleted, at that time.
-- Usage: SELECT audit.as_of('inventory.items', '3', '2026-11-25 14:00+00');
CREATE FUNCTION audit.as_of(p_table TEXT, p_key TEXT, p_at TIMESTAMPTZ)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT new_row            -- NULL when the latest change before p_at was a DELETE
    FROM audit.log
    WHERE table_name = p_table AND row_key = p_key AND changed_at <= p_at
    ORDER BY id DESC
    LIMIT 1;
$$;

-- Filed batches and their lines (added with the transfer-batch feature).
CREATE TRIGGER audit_log_change AFTER INSERT OR UPDATE OR DELETE ON inventory.transfer_batches
    FOR EACH ROW EXECUTE FUNCTION audit.log_change('id');
CREATE TRIGGER audit_log_change AFTER INSERT OR UPDATE OR DELETE ON inventory.transfer_batch_lines
    FOR EACH ROW EXECUTE FUNCTION audit.log_change('batch_id,line_no');
