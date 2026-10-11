-- 002: activity memory -- the one funnel (memory.md §2). Exists before the first feature ships; it cannot be backfilled. Every row is
-- shipped to the tenant's one MaluDB as an `activity` episode by mcp/activity_ingest.py (payload key "application": "developer" first).
-- WHAT IS LOGGED IS WHAT PEOPLE AND AGENTS DO, NEVER WHAT A DATABASE HOLDS (design §6.10): `before`/`after` carry ids, classes,
-- targets, levels, counts and reasons -- NEVER SQL text, never a cell value, never a password, a token or a file path. A token is
-- named by its label. Never logged: polling, the door's named catalog queries (counted in door_usage instead), the worker's passes.
--
-- THE ESTATE'S DATA MODEL (design §6.11): the contract table (memory.md / Consultant Tracking db/002) with token_id as Knowledge db/002
-- appended it (Sales CRM, the Data Lake, Boards and MaluMail carry it too), and Developer's audit key APPENDED: target_database_id
-- bigint (every event about a registered database -- a statement run on it, a change applied, a window opened, a draft for it, a
-- classification, a grant -- a database's TRAIL is one index). No FK: history outlives a record, and target_databases comes in db/006+.
-- `source` widens the contract's list with 'system' (the worker's expiries and the door's own acts are no one's click) -- an
-- enumeration widened, the shared-schema rule's allowed change.
BEGIN;

CREATE TABLE activity_log (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at     timestamptz NOT NULL DEFAULT now(),
    actor_member_id bigint REFERENCES members(id) ON DELETE SET NULL,
    source          text NOT NULL DEFAULT 'web'
                    CHECK (source IN ('web', 'assistant', 'mcp', 'cron', 'agent', 'desk', 'webhook', 'portal', 'api', 'application', 'system')),
    action          text NOT NULL,                 -- entity.verb
    screen          text,
    route           text,                          -- "METHOD /path"
    entity_type     text,
    entity_id       bigint,
    before          jsonb,
    after           jsonb,                         -- changed fields only
    request_id      text,
    session_id      text,
    ip_address      inet,
    agent_run_id    bigint,                        -- the kernel's run id when an agent acted (no FK)
    department_id   bigint,                        -- the department the event concerns (the contract's; rarely used here)
    location_id     bigint,                        -- the contract's (unused: scope none)
    kernel_request_id text,                        -- the kernel's request id for a call that crossed to it
    created_at      timestamptz NOT NULL DEFAULT now(),
    token_id        bigint,                        -- appended (Knowledge db/002): the token (mcp_access_tokens.id) an event ran under; its LABEL is in `after`, never the token
    -- appended (design §6.10): Developer's audit key (no FK — history outlives a record; target_databases comes in db/006+)
    target_database_id bigint                      -- the registered database the event concerns (a run, a change, a window, a draft, a grant)
);
CREATE INDEX activity_log_actor_idx    ON activity_log (actor_member_id, occurred_at DESC);
CREATE INDEX activity_log_entity_idx   ON activity_log (entity_type, entity_id, occurred_at DESC);
CREATE INDEX activity_log_action_idx   ON activity_log (action, occurred_at DESC);
CREATE INDEX activity_log_time_idx     ON activity_log (occurred_at DESC);
CREATE INDEX activity_log_request_idx  ON activity_log (request_id);
CREATE INDEX activity_log_token_idx    ON activity_log (token_id, occurred_at DESC) WHERE token_id IS NOT NULL;
CREATE INDEX activity_log_target_idx   ON activity_log (target_database_id, occurred_at DESC) WHERE target_database_id IS NOT NULL;

GRANT INSERT, SELECT ON activity_log TO developer_rw;
REVOKE ALL ON activity_log FROM developer_records_ro, developer_activity_ro;

-- The ingest checkpoint: only ever moves forward.
CREATE TABLE activity_ingest_state (
    id          smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    last_id     bigint NOT NULL DEFAULT 0,
    updated_at  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO activity_ingest_state (id, last_id) VALUES (1, 0) ON CONFLICT DO NOTHING;
GRANT SELECT, UPDATE ON activity_ingest_state TO developer_rw;

COMMIT;
