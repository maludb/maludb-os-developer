-- 008: COLUMN CLASSIFICATIONS AND THE GRANTS PLAN — masks as privileges (design §6.9, §6.1; D11).
--
-- column_classes: per target, relation and column — `secret`, `personal` (with a kind) or `none`. A DETERMINISTIC classifier
-- (dx_classify_column) proposes on every catalog-index pass from names and types; A PROPOSAL IS ENFORCED AT ONCE (fail closed): the
-- grants service revokes the column from the tiers within a minute. A DBA confirms or clears a proposal (classifications.confirm); a
-- column the built-in SECRET patterns match is cleared only by a super-admin (cleared_by_super_admin) — and the grants service applies
-- the same patterns on its own, so a forged row in this table never hands it a secret column.
--
-- mcp_grant_plan is what the grants service reads (as developer_grantor, design §6.1): per registered target whose grants the owner
-- put in place, every classified column with its effective class. The service grants every OTHER column of the target's tables and
-- views to the read, read_masked and write tiers, withholds `secret` from all three and `personal` from read_masked.
--
-- THE ESTATE'S DATA MODEL (design §6.11): NEW CANONICAL (the Data Lake classifies lake columns in its own catalog — a different concept).
BEGIN;

CREATE TABLE column_classes (
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    target_database_id    bigint NOT NULL REFERENCES target_databases(id) ON DELETE CASCADE,
    schema_name           text NOT NULL,
    relation_name         text NOT NULL,
    column_name           text NOT NULL,
    class                 text NOT NULL CHECK (class IN ('secret', 'personal', 'none')),
    kind                  text CHECK (kind IN ('email', 'phone', 'name', 'address', 'birth_date', 'national_id', 'payment_card', 'bank_account',
                                               'ip_address', 'free_text', 'compensation', 'health', 'other')),
    pattern_match         text,                                   -- the built-in pattern that matched (NULL = a person's or an agent's call)
    proposed_by           text NOT NULL CHECK (proposed_by IN ('classifier', 'agent', 'person')),
    proposed_member_id    bigint REFERENCES members(id) ON DELETE SET NULL,
    confirmed_by          bigint REFERENCES members(id) ON DELETE SET NULL,
    confirmed_at          timestamptz,
    cleared_by_super_admin boolean NOT NULL DEFAULT false,        -- a pattern-matched secret a super-admin declared not secret
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    UNIQUE (target_database_id, schema_name, relation_name, column_name),
    CHECK ((class = 'personal') = (kind IS NOT NULL)),
    CHECK ((confirmed_by IS NULL) = (confirmed_at IS NULL)),
    CHECK (NOT cleared_by_super_admin OR (class = 'none' AND confirmed_by IS NOT NULL))
);
CREATE INDEX column_classes_target_idx ON column_classes (target_database_id, schema_name, relation_name);
CREATE INDEX column_classes_unconfirmed_idx ON column_classes (target_database_id) WHERE confirmed_at IS NULL;
CREATE TRIGGER column_classes_touch BEFORE UPDATE ON column_classes FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- The built-in patterns (design §6.9). Returns the proposal for a column name and its type: (class, kind, pattern) — or NULL row when
-- nothing matches. Deterministic and IMMUTABLE: the grants service (services/grants/) carries the same SECRET list and applies it on
-- its own; tests/door/ proves the two agree.
CREATE OR REPLACE FUNCTION dx_classify_column(p_name text, p_type text) RETURNS TABLE (class text, kind text, pattern text)
    LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE n text := lower(p_name); t text := lower(COALESCE(p_type, ''));
BEGIN
    -- secret — never shown to anyone, by any path
    IF n ~ '(^|_)(password|passwd|pass_hash|password_hash|secret|secrets|api_key|apikey|private_key|privkey|ciphertext|totp_secret|otp_secret|refresh_token|access_token|session_token)($|_)'
       OR n ~ '(^|_)token(_hash)?$' OR n ~ '_hash$' AND n ~ '(token|key|secret|password)' OR n ~ '(^|_)(encrypted|sealed)(_|$)' OR n ~ '_encrypted$' THEN
        RETURN QUERY SELECT 'secret'::text, NULL::text, 'secret name'::text; RETURN;
    END IF;
    IF t = 'bytea' AND n ~ '(key|seal|cipher|secret|nonce)' THEN
        RETURN QUERY SELECT 'secret'::text, NULL::text, 'sealed bytes'::text; RETURN;
    END IF;
    -- personal, by kind
    IF n ~ '(^|_)e?mail(_address)?$' OR n ~ '(^|_)email' THEN RETURN QUERY SELECT 'personal'::text, 'email'::text, 'email'::text; RETURN; END IF;
    IF n ~ '(^|_)(phone|mobile|cell|telephone|fax)(_|$)' THEN RETURN QUERY SELECT 'personal'::text, 'phone'::text, 'phone'::text; RETURN; END IF;
    IF n ~ '^(first|last|full|given|family|middle|legal|maiden)_?name$' OR n IN ('surname', 'forename') THEN RETURN QUERY SELECT 'personal'::text, 'name'::text, 'person name'::text; RETURN; END IF;
    IF n ~ '(^|_)(ip|ip_address|remote_addr|client_ip)(_|$)' OR t = 'inet' THEN RETURN QUERY SELECT 'personal'::text, 'ip_address'::text, 'ip address'::text; RETURN; END IF;
    IF n ~ '(^|_)(address|street|address_line[0-9]*|postcode|postal_code|zip|zip_code)(_|$)' THEN RETURN QUERY SELECT 'personal'::text, 'address'::text, 'address'::text; RETURN; END IF;
    IF n ~ '(^|_)(birth|birthday|dob|date_of_birth|birth_date)(_|$)' THEN RETURN QUERY SELECT 'personal'::text, 'birth_date'::text, 'birth date'::text; RETURN; END IF;
    IF n ~ '(^|_)(ssn|sin|national_id|nin|passport|tax_id|tin|driver_licen[cs]e)(_|$)' THEN RETURN QUERY SELECT 'personal'::text, 'national_id'::text, 'national id'::text; RETURN; END IF;
    IF n ~ '(^|_)(card_number|pan|cc_number|credit_card)(_|$)' THEN RETURN QUERY SELECT 'personal'::text, 'payment_card'::text, 'payment card'::text; RETURN; END IF;
    IF n ~ '(^|_)(iban|bank_account|account_number|routing_number|sort_code|bic|swift)(_|$)' THEN RETURN QUERY SELECT 'personal'::text, 'bank_account'::text, 'bank account'::text; RETURN; END IF;
    IF n ~ '(^|_)(salary|wage|wages|pay_rate|hourly_rate|compensation|bonus)(_|$)' THEN RETURN QUERY SELECT 'personal'::text, 'compensation'::text, 'compensation'::text; RETURN; END IF;
    IF n ~ '(^|_)(diagnosis|medical|health|condition|allergy|allergies|disability)(_|$)' THEN RETURN QUERY SELECT 'personal'::text, 'health'::text, 'health'::text; RETURN; END IF;
    IF (t IN ('text', 'character varying', 'varchar', 'citext') AND n ~ '(^|_)(body|content|text|html|message|notes?|description|comment|comments|snippet|summary|payload|transcript)(_|$)')
       OR (t IN ('jsonb', 'json') AND n ~ '^(before|after|payload|data|body|content)$') THEN
        RETURN QUERY SELECT 'personal'::text, 'free_text'::text, 'free text'::text; RETURN;
    END IF;
    RETURN;
END$$;

-- Record the classifier's proposal for a column (the worker's catalog pass): new columns get a row; an existing row a person or an agent
-- made is never overwritten; a classifier row is refreshed. Returns true when a row was made or changed.
CREATE OR REPLACE FUNCTION dx_classify_propose(p_target bigint, p_schema text, p_relation text, p_column text, p_type text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c record; existing column_classes%ROWTYPE;
BEGIN
    SELECT * INTO c FROM dx_classify_column(p_column, p_type);
    IF c.class IS NULL THEN RETURN false; END IF;
    SELECT * INTO existing FROM column_classes WHERE target_database_id = p_target AND schema_name = p_schema AND relation_name = p_relation AND column_name = p_column;
    IF FOUND THEN
        IF existing.proposed_by <> 'classifier' OR existing.confirmed_at IS NOT NULL THEN RETURN false; END IF;
        IF existing.class = c.class AND existing.kind IS NOT DISTINCT FROM c.kind THEN RETURN false; END IF;
        UPDATE column_classes SET class = c.class, kind = c.kind, pattern_match = c.pattern WHERE id = existing.id;
        RETURN true;
    END IF;
    INSERT INTO column_classes (target_database_id, schema_name, relation_name, column_name, class, kind, pattern_match, proposed_by)
    VALUES (p_target, p_schema, p_relation, p_column, c.class, c.kind, c.pattern, 'classifier');
    RETURN true;
END$$;

-- Confirm or change a column's class as the acting member (classifications.confirm — a DBA). Clearing a column the SECRET patterns match
-- is a super-admin's alone (it marks cleared_by_super_admin). Returns the row's id.
CREATE OR REPLACE FUNCTION dx_classify_confirm(p_target bigint, p_schema text, p_relation text, p_column text, p_class text, p_kind text DEFAULT NULL)
    RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE me bigint := app_current_member_id(); pat record; rid bigint; clearing_secret boolean;
BEGIN
    IF NOT dx_has_right('classifications.confirm') THEN
        RAISE EXCEPTION '%', COALESCE(dx_right_refusal('classifications.confirm'), 'You may not confirm classifications') USING ERRCODE = 'insufficient_privilege';
    END IF;
    SELECT * INTO pat FROM dx_classify_column(p_column, NULL);
    clearing_secret := pat.class = 'secret' AND p_class <> 'secret';
    IF clearing_secret AND NOT app_is_super_admin() THEN
        RAISE EXCEPTION 'A column the secret patterns match is cleared only by a super-admin' USING ERRCODE = 'insufficient_privilege';
    END IF;
    INSERT INTO column_classes (target_database_id, schema_name, relation_name, column_name, class, kind, pattern_match, proposed_by, proposed_member_id,
                                confirmed_by, confirmed_at, cleared_by_super_admin)
    VALUES (p_target, p_schema, p_relation, p_column, p_class, CASE WHEN p_class = 'personal' THEN COALESCE(p_kind, 'other') END, pat.pattern,
            'person', me, me, now(), clearing_secret AND p_class = 'none')
    ON CONFLICT (target_database_id, schema_name, relation_name, column_name) DO UPDATE
       SET class = EXCLUDED.class, kind = EXCLUDED.kind, confirmed_by = EXCLUDED.confirmed_by, confirmed_at = EXCLUDED.confirmed_at,
           cleared_by_super_admin = EXCLUDED.cleared_by_super_admin, proposed_by = 'person', proposed_member_id = EXCLUDED.proposed_member_id
    RETURNING id INTO rid;
    RETURN rid;
END$$;

-- What the grants service applies (design §6.1): the targets whose grants are in place, and their classified columns' effective class.
CREATE OR REPLACE VIEW mcp_grant_targets WITH (security_barrier = true) AS
SELECT t.id AS target_database_id, t.datname, t.class, t.grants_state
  FROM target_databases t
 WHERE t.gone_at IS NULL AND t.class IN ('application', 'development') AND t.grants_state IN ('in_place', 'partial');

-- The grants service's contract (services/grants/service.py): one row per classified column of a granted target, PLUS one row with
-- table_name NULL for each granted target — so a target with no classification yet is still passed (every column granted but the
-- built-in secret patterns, which the service withholds on its own).
CREATE OR REPLACE VIEW mcp_grant_plan WITH (security_barrier = true) AS
SELECT t.datname, c.schema_name, c.relation_name AS table_name, c.column_name, c.class, c.cleared_by_super_admin AS cleared_secret
  FROM column_classes c JOIN mcp_grant_targets t ON t.target_database_id = c.target_database_id
UNION ALL
SELECT t.datname, NULL, NULL, NULL, NULL, false FROM mcp_grant_targets t;

-- The grants service's own record of each pass per target (what it granted and revoked, by tier — names of columns, never a value).
CREATE TABLE grants_passes (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    datname      text NOT NULL,
    at           timestamptz NOT NULL DEFAULT now(),
    changes      integer NOT NULL DEFAULT 0,
    detail       jsonb NOT NULL DEFAULT '{}'::jsonb,
    error        text CHECK (error IS NULL OR length(error) <= 2000)
);
CREATE INDEX grants_passes_time_idx ON grants_passes (datname, at DESC);
CREATE OR REPLACE FUNCTION dx_grants_pass_log(p_datname text, p jsonb) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE rid bigint;
BEGIN
    INSERT INTO grants_passes (datname, changes, detail, error)
    VALUES (p_datname, COALESCE((p ->> 'changes')::integer, 0), COALESCE(p -> 'detail', '{}'::jsonb), left(p ->> 'error', 2000))
    RETURNING id INTO rid;
    DELETE FROM grants_passes WHERE at < now() - interval '30 days';
    RETURN rid;
END$$;
REVOKE ALL ON FUNCTION dx_grants_pass_log(text, jsonb) FROM PUBLIC;
GRANT SELECT ON grants_passes TO developer_rw;

GRANT SELECT, INSERT, UPDATE ON column_classes TO developer_rw;
GRANT SELECT ON mcp_grant_targets, mcp_grant_plan TO developer_rw;
GRANT EXECUTE ON FUNCTION dx_classify_column(text, text) TO developer_rw, developer_records_ro;
REVOKE ALL ON FUNCTION dx_classify_propose(bigint, text, text, text, text), dx_classify_confirm(bigint, text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION dx_classify_propose(bigint, text, text, text, text), dx_classify_confirm(bigint, text, text, text, text, text) TO developer_rw;

COMMIT;
