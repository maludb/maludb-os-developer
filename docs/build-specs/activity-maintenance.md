# Build spec: activity and maintenance (slice 7)

What exists at the end: **what the server is doing, on a phone** — sessions running, waiting and blocking across the databases I may see,
**the root blocker** highlighted with whom it blocks and for how long, idle-in-transaction age, wait events with their descriptions, the
query texts **normalized** (literals → `$n`), the tool's own sessions marked, refreshed every 5 s while open; one session's page with its
locks and its chain; **Cancel** (yellow) and **Terminate** (red) as separate, confirmed actions through `dx_signal()` — never the kernel's
or a memory database's sessions, never a superuser's, no "kill all"; a DBA may open one session's raw text, with a reason, logged; the locks
view linked to sessions and objects; **the top statements** from `pg_stat_statements` linking to Explain; the server's I/O, checkpointer,
WAL and archiver panels; **the vacuum and wraparound panel**; **maintenance jobs** — VACUUM, ANALYZE, REINDEX CONCURRENTLY, REFRESH
MATERIALIZED VIEW CONCURRENTLY — queued with the lock each takes said first, run by the door with progress, cancellable. Every screen says
what the tool's roles cannot see (T21). The worker notices a session that has blocked others past the threshold and wakes the Advisor.

Schema (db/005, 009, 011, 012, never modified, plus this slice's migration): `maintenance_jobs`, `dx_maintenance_jobs_before()` (people with
`maintenance.run`; `application` targets only), `agent_dispatches` (kind `blocked_session`), `notifications`, `dx_notify()` (db/011);
`mcp_maintenance_jobs`, `mcp_visible_targets` (db/012); `dx_signal(pid, kind)` (`deploy/own-database.sql` — the owner's root step).
Door: kinds `named` (`activity`, `blocking`, `locks`, `session_text`, `progress`, `top_statements`, `server_stats`, `vacuum_state`,
`archiver`), `signal`, `maintenance`, `cancel` (`the-door.md` §1, §4, §6.6, §6.7).

## Divergences from the design
1. **Maintenance jobs run on the door's own thread**, not in the worker's process (a VACUUM of a large table would hold the minute timer for
   its whole length): the worker's `maintenance_jobs` pass hands a queued job to the door (`door_ask('maintenance', …)`), which answers at
   once and reports through **`dx_door_job_update(job_id bigint, p jsonb)`** — this slice's migration `db/0NN_maintenance_jobs.sql` creates it
   (`SECURITY DEFINER`, `SET search_path = public, pg_temp`; it updates only `status`, `progress`, `started_at`, `finished_at`,
   `error_masked`, `query_run_id` of a job in `queued`/`running`; `EXECUTE` to `developer_meta` by `deploy/own-database.sql`'s `dx_door_*`
   loop). Reported to the planning model as a schema addition.
2. **Opening a session's raw text is an action** (`session_text_open`, POST, a reason, logged `session.text_open`) whose answer is the text
   rendered once in the session's page — never a GET, never cached (`Cache-Control: no-store`).
3. **The blocked-session dispatch is noticed here, delivered by slice 10**: the worker's `blocked_sessions` pass (every minute) writes one
   `agent_dispatches` row (kind `blocked_session`, the Advisor, the target, the root pid's fingerprint — never its text) and one
   `dx_notify()` to each DBA per root blocker that has blocked others longer than `blocked_minutes` (10, a setting this slice's migration
   adds to `dx_settings` — reported); the same root is not dispatched again while it lasts. Slice 10 delivers dispatches and texts.
4. **Statements live in the tool's own database**: `pg_stat_statements` is created there by the owner (ROOT_STEPS); one installation covers
   the cluster and the named query filters by `dbid`. Until it exists, `statements` says "The owner has not created pg_stat_statements yet".

## Who may do what
| Action / screen | Right | Rule |
|---|---|---|
| `sessions`, `db-activity`, `session-view`, `locks`, `statements`, `server`, `vacuum` | `activity.read` (`vacuum`: `health.read`) | texts normalized always; **no text at all** for a session on the kernel's or a memory database (the named query returns none); the tool's roles' limits said on each screen |
| `session_cancel` | `sessions.cancel` | people; `dx_signal(pid, 'cancel')` refuses a superuser's session, the tool's own, and any session not on an `application`, `development` or workbench database of the registry; the target is the session's database |
| `session_terminate` | `sessions.terminate` | the same, with a reason |
| `session_text_open` | `sessions.cancel` (a DBA) | people; refused for the kernel's and memory databases' sessions; logged with the reason |
| `maintenance-list` | `health.read` | jobs on visible targets |
| `maintenance_queue`, `maintenance-add` | `maintenance.run` | people; `application` targets only (the trigger); `VACUUM FULL` and `CLUSTER` are not operations |
| `maintenance_cancel` | own or `maintenance.run` | a queued job → `cancelled`; a running one → the door's `cancel` |

## Screens
| Screen id | Canonical URL | Purpose |
|---|---|---|
| `sessions` | `/sessions?datname=&state=` | **phone-first.** A summary strip (running · waiting · idle in transaction · blocked, each a filter chip); **the root blockers first** as cards (database badge, pid, user, application, "blocking 3 for 4 min", the normalized text's first two lines, Cancel / Terminate); then every session as a card at 375 and a table at 1280 (pid, database, user, application — "Developer" chip for the tool's own —, state, wait event with its description as a tooltip and a line at 375, transaction age, query age, the normalized text cut at 200 characters); refreshed every 5 s while the page is visible (`hx-trigger="every 5s [document.visibilityState=='visible']"` on `GET /sessions/poll`); the note "The tool sees other users' sessions through pg_monitor; superusers' sessions are shown but cannot be signalled — cancel those from psql as postgres" |
| `db-activity` | `/db/{datname}/activity` | the same for one database, under its verb tabs |
| `session-view` | `/sessions/{pid}?datname=` | one session: its fields, the normalized text in full, the locks it holds and waits on (linked to objects), the chain it heads or sits in; **Cancel** (yellow, ✔ "Cancel the running statement of pid 4182 on subello_gl?"), **Terminate** (red, ✔, a reason field), **Open the raw text** (a DBA; a reason field; the text shown once below, escaped) |
| `locks` | `/sessions/locks?datname=&object=` | locks as a table (pid → `session-view`, mode, granted or waiting with how long, lock type, the object → its page) |
| `statements` | `/statements?datname=&order=` | the top statements by total time (default), mean time, calls, rows, shared reads, temp written: the normalized text, calls, total and mean ms, rows, the database; each row's **Explain** opens the editor of that database with the text and `GENERIC_PLAN` ticked (slice 6); `stats_since` shown |
| `server` | `/server` | panels: `pg_stat_io` by backend type and context, `pg_stat_checkpointer` (requested vs timed, write and sync time), `pg_stat_wal`, the archiver (mode, last archived, failures); the predefined roles the tool holds and what is hidden without them |
| `vacuum` | `/db/{datname}/vacuum` | the database's `age(datfrozenxid)` against `autovacuum_freeze_max_age` (a bar), per table dead tuples, last vacuum / autovacuum / analyze / autoanalyze, `age(relfrozenxid)` — sortable; the sessions holding the xmin horizon; vacuum progress of a running one |
| `maintenance-list` | `/maintenance?datname=&state=` | jobs as a table: database, object, operation, status, progress (a bar from `pg_stat_progress_*` — phase, blocks or tuples done of total), requested by, started, finished, the masked error; Cancel on a queued or running job; polled every 2 s while a job runs (`GET /maintenance/{id}/progress`) |
| `maintenance-add` | `/maintenance/new?datname=&object=&operation=` | `page-header-form`: the database (application targets only), the object (a table, an index or a materialized view — the record picker over the catalog index), the operation; **the lock it takes said before Queue** ("VACUUM takes SHARE UPDATE EXCLUSIVE: reads and writes continue; another VACUUM, ANALYZE or DDL on this table waits", "REINDEX CONCURRENTLY … cannot run inside a transaction and takes longer", …); Queue (✔) |

## Files (exactly these)
- `html/sessions/{index,poll,view,locks,cancel,terminate,text}.php`, `html/db/activity.php`, `html/db/vacuum.php`, `html/statements.php`,
  `html/server.php`, `html/maintenance/{index,form,queue,cancel,progress}.php`
- `app/features/ops/{queries,present,signal}.php`, `app/features/maintenance/{queries,present,write}.php`
- `app/views/ops/{sessions,session,locks,statements,server,vacuum}.php` + `app/views/ops/partials/{session-card,session-row,blocker-card,
  summary,lock-row,limits-note}.php`, `app/views/maintenance/{index,form}.php` + `app/views/maintenance/partials/{job-row,progress,lock-note}.php`
- the worker's `maintenance_jobs` pass (queued → the door; a running job past 24 h is reported to the DBAs) and a new `blocked_sessions` pass
  in `bin/worker.php`
- `db/0NN_maintenance_jobs.sql` — `dx_door_job_update()`, the setting `blocked_minutes` (default 10); nothing else
- `tests/phase3/slice7/{run.sh,lib.php,sessions.php,signals.php,locks.php,statements.php,maintenance.php,blocked.php,json.php,browser.mjs}`

## Query functions (signatures fixed)
- `ops_sessions(string|null $datname, ?string $state): array{summary, roots, sessions}` — `door_named(own, 'activity')` and
  `door_named(own, 'blocking')` (the cluster views are read from the tool's own database; `$datname` filters), each session joined to its
  target's class (no text for kernel and memory) and marked `is_tool`
- `ops_session(int $pid, string $datname): ?array` — the session, its locks (`locks` with `pid`), its chain
- `ops_locks(?string $datname, ?string $object): array`
- `ops_statements(?string $datname, string $order, int $limit): array` — `top_statements`, or `['not_installed' => true]`
- `ops_server(): array` — `server_stats` + `archiver`
- `ops_vacuum(string $datname): array` — `vacuum_state` + `progress` of a running vacuum
- `ops_signal(string $datname, int $pid, string $signal, ?string $reason): array` — `door_signal()`; answers the door's refusal words
  ("pid 4182 belongs to a superuser — cancel it from psql as postgres", "that session is on the kernel's database")
- `ops_session_text(string $datname, int $pid, string $reason): ?string` — `door_named($datname, 'session_text', ['pid' => $pid])`
- `find_jobs(PDO $pdo, array $filters, int $page): array{rows, total}` (over `mcp_maintenance_jobs`) · `job_queue(PDO $pdo, array $fields): int`
  (the lock note from `maintenance_lock_note($operation)`, a fixed map) · `job_cancel(PDO $pdo, int $id): void`

## MCP tools this slice makes real
`activity_now`, `blockers`, `locks`, `top_statements`, `vacuum_state`, `maintenance_jobs` — each through the door's named query as the
agent on behalf of the person (K38), texts normalized, never a raw text, never a signal.

## Manifest rows claimed
Screens (9): `sessions`, `db-activity`, `session-view`, `locks`, `statements`, `server`, `vacuum`, `maintenance-list`, `maintenance-add`
Actions (5): `session_cancel`, `session_terminate`, `session_text_open`, `maintenance_queue`, `maintenance_cancel`

## Activity log events
`session.cancel` `{target, pid, outcome}`; `session.terminate` `{target, pid, outcome, reason}` (the reason is the person's words, kept);
`session.text_open` `{target, pid, reason}` (never the text); `maintenance.queue` `{job_id, target, operation, object}`;
`maintenance.cancel` `{job_id}`; the worker's `maintenance.start` / `.done` / `.failed` `{job_id, ms}` and `session.blocked`
`{target, root_pid, blocked: n, minutes, dispatch_id}` (source `cron`).

## Status vocabulary
A session: `active`, `idle`, `idle in transaction`, `idle in transaction (aborted)`, `fastpath function call`, `disabled` (PostgreSQL's), and
*waiting* / *blocking* / *root blocker* derived. A job: `queued`, `running`, `ok`, `failed`, `cancelled` (db/011).

## Out of scope for this slice
`VACUUM FULL`, `CLUSTER`, `pg_repack` (Extended); trends over time and alerts beyond the blocked-session dispatch (Extended); the delivery of
dispatches and K6 texts (slice 10); health findings and index advice (slice 8); cancelling a superuser's session (never — said on the screen).

## Proof (`tests/phase3/slice7/run.sh`: scratch `dx_dev7`; php -S on 9401, fake kernel 9402, fakes 9403; user-level Apache on 9407; the scratch door with `dx_proof_*` roles — the proof's meta role holds no `pg_monitor` (FINDINGS: it would expose the real applications' texts), so the activity checks run on the proof's own sessions; targets `dx_t7_app` and a scratch database classed `kernel`; Playwright)
- A scratch session holds a row lock on `dx_t7_app`, two others wait: `sessions` shows one root blocker blocking 2, the chain on
  `session-view`, the locks on `locks`; texts are normalized (a literal `'jane@example.invalid'` in the blocker's text never appears — the
  page and `activity_log` grepped); a session on the `kernel`-classed scratch database shows no text.
- Cancel the root blocker (browser, ✔): its statement ends with 57014 and the waiters proceed; terminate another (a reason) ends its backend;
  a superuser's session and the tool's own session are refused with their sentences; a Viewer's cancel is refused (`sessions.cancel`); an
  agent's through the JSON door is refused (`require_human()`).
- `session_text_open` by a DBA shows the raw text once and logs the reason; refused for the kernel-classed session.
- `statements` lists the proof's statements once `pg_stat_statements` exists in the scratch own database, and says "not created" when it does
  not; a row's Explain opens the editor with `GENERIC_PLAN`.
- `maintenance_queue` of `VACUUM (ANALYZE)` and `REINDEX CONCURRENTLY` on `dx_t7_app`: the lock note shown first, the worker hands the job to
  the door, `dx_door_job_update()` reports running with progress and then `ok`; a job cancelled while queued and while running; a job on a
  development target refused by the trigger; an Engineer refused.
- The blocked-session pass: a blocker held past a 1-minute test threshold writes one dispatch and one notification per DBA, not a second
  while it lasts, and none for a kernel-classed session.
- The 5-second refresh stops while the page is hidden (browser); 375 and 1280 screenshots of `sessions`, `session-view`, `maintenance-list`;
  no horizontal scroll.

## Requirements claimed
MUSTs (18): R57, R58, R71, R72, R102, R103, T21, T22, T24, T27, T38, T42, E11, E18, S7, S10, S12, S24

## Decisions taken here
1. **Cancel and terminate name the session's database as the target**, so the class badge in the confirmation is the session's.
2. **The root blocker is the session that blocks others and waits on nobody**; chains are shown to depth 5, then "…".
3. **One running maintenance job per target**: a second waits queued.

## Open questions
1. `blocked_minutes` (10) is this slice's setting; the owner may want a different threshold — it is in Admin → Settings (slice 10).
