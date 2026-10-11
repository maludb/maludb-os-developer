# Build spec: agents, exports, notifications, the homes and admin (slice 10)

What exists at the end: **the two shipped agents work end to end** — the Database Expert answers in the command bar and the ask window from
the catalog, plans and statistics and proposes, drafts and rehearses (its four free actions, built by slices 3 and 4, proven here through the
kernel's relay); **the DBA Advisor** runs its weekday duty (`20 7 * * 1-5`, the runbook `weekday-dba-note`) and posts **one DBA note** through
`dba_note_post`, naming the change sets it proposed, which reaches every DBA as a notification; a session blocking others for ten minutes
**dispatches** the Advisor to note the root blocker; **every action an agent may not take is refused, not paused** — in SQL (`held_by`) and in
the handler (`require_human()`); **Proposals** shows what the agents proposed and what became of each. A person's **exports** wait, are
downloaded once and expire; **notifications** reach people in the app, by email and — opt-in — by text through the kernel (K6), with
preferences per kind; **the homes** are complete for each role (the panels the shell left as cards); **Admin** holds the settings, **the
audit** of every run through the door (and one run in full), **who unmasked, opened a window or revealed what**, **the door's** and **the
grants service's** pages, the tool's agents, the worker's passes and **the freeze**. `bin/backup_mark.php` lets the owner's backup script
record each dump. This slice is the worker's (Sonnet 5.5) — it replicates slice 1 (the CRUD exemplar) for its screens and the shell's
patterns for the homes.

Schema (db/005, 009, 011, 012, never modified): `dx_settings`, `dx_freeze()` (db/005, 006); `query_runs`, `door_statements`, `door_usage`
(db/009); `exports` + `dx_exports_before`, `notifications`, `notification_prefs`, `notification_outbox`, `dx_notify()`,
`dx_notify_self_approved_window()`, `agent_dispatches`, `worker_passes`, `backup_marks`, `dx_last_backup()` (db/011); `dba_notes` +
`dx_dba_notes_before`, `mcp_dba_notes`, `mcp_agent_proposals`, `mcp_activity_log`, `mcp_visible_targets` (db/012). **The database is the
referee**: a note's author must hold `health.read` and name change sets that exist (and is marked an agent's when it is); an export is a
person's; notifications are people's (`dx_notify()` refuses an agent); the freeze is a super-admin's (`dx_freeze()`), and freezing ends every
open window.

## Divergences from the design
1. **The Advisor's "notification" is the action `dba_note_post`** (design §5 named a notification; Phase 1 named the action and its table
   `dba_notes`). The note is one row; the handler then calls `dx_notify()` for every active member holding `maintenance.run` (the DBA role
   holders) with kind `advisor_note`. The summary to the kernel's Sysadmin agent is the agent's own `message_send` — a kernel tool, not this
   application's.
2. **The blocked-session threshold is ten minutes, fixed in v1** (design §5's words). `dx_settings` has no column for it; a setting is
   proposed to the planning model (`blocked_alert_minutes`, a db/013 append) and the code reads `dx_setting_int('blocked_alert_minutes')` with
   10 as its fallback once it exists.
3. **The export file is made by slice 3** (the worker's `export_jobs` pass and `export_make`). This slice builds the list, the one-time
   download door, `export_delete` and the purge in the `retention` pass.
4. **A dispatch reaches the Advisor through the kernel's chat endpoint** (`ask_assistant($pdo, $acting, $text, $context, 'advisor')`) until
   K8's wake lands, acting as the first active DBA by member id — the reply is written into a `blocked_session` notification for every DBA,
   never acted on. Failures retry with back-off (`next_attempt_at`: 1, 5, 15 minutes; then `failed`); `dispatch_retry` re-queues one.
5. **The settings screen leaves `door_pool_max` out** — the door reads it at start, so a change needs the owner to restart the door; it is
   shown read-only with that sentence. `idle_timeout_minutes`, `step_up_minutes` and `snapshot_ddl_days` are offered once the manifest's
   `settings_save` lists them (reported); until then shown read-only.

## Who may do what
| Action | Right (`held_by`) | Agent |
|---|---|---|
| dba_note_post | `health.read` (anyone) — the Advisor's; a person may post one too | **yes** |
| export_delete | own | people |
| notification_read, notification_read_all, notification_prefs_save | own | people |
| dispatch_retry | `settings.manage` (super_admins) | people |
| settings_save | `settings.manage` (super_admins) | people |
| freeze_on, freeze_off | `freeze` (super_admins) | people |

Screens: `proposals`, `notes-list`, `note-view`: `catalog.read` (`health.read` for notes); `exports-list`, `notifications`,
`notification-prefs`: any admitted person (own rows); `admin-settings`: `settings.manage`; `audit`, `audit-run`, `audit-reveals`:
`audit.read`; `admin-door`, `admin-grants`, `admin-agents`, `admin-worker`: `settings.manage`; `admin-freeze`: `freeze`. The agents' refusals
(design §5): **every one of the 59 people-only actions answers 403 to an agent's token** with the right's refusal words, and `is_eval`
refuses the five agent actions too (the kernel's actions server first, the handler again).

## Screens
| Screen id | Canonical URL | Purpose |
|---|---|---|
| `proposals` | `/proposals?agent=&state=` | `mcp_agent_proposals` as cards: kind chip (change set · draft · note), title (a link to `change-review`, `draft-view` or `note-view`), the database badge, the agent's name with the "Agent" chip, state, who decided and when; filters by agent and state (open · applied · drafted · discarded) |
| `notes-list` | `/notes` | the DBA notes newest first: title, author (agent chipped), when, the count of proposals it carries |
| `note-view` | `/notes/{id}` | one note: its body rendered from markdown **as text through an allow-list renderer** (headings, lists, emphasis, code, links to this application's own paths only — never raw HTML), then its proposals as rows with their current state and a link to each review |
| `exports-list` | `/exports` | my exports: kind, database, format, rows, size, status (queued · running · done · failed), made, expires; Download (once — the door `GET /exports/{id}/download`, then "Downloaded {when}"), Delete |
| `notifications` | `/notifications` | my notifications newest first, unread bold: kind icon, title, the database badge, when; each a link to its record; Mark read; Mark all read |
| `notification-prefs` | `/me/notifications` | per kind a row: in the app (always), email (on/off), text (on/off — only when the kernel knows a verified phone; "the kernel keeps the opt-out"); the digest switch; Save (`notification_prefs_save`) |
| `admin-settings` | `/admin/settings` | the limits, caps, retention and expiry from `dx_settings` as a full-page form in four groups (Statements · Windows · Change sets and backups · Workbenches, retention and exports), each field with its allowed range from the CHECKs; Save (✔ "These limits apply to every person and agent at once") |
| `audit` | `/admin/audit?member=&datname=&status=&since=` | every run through the door from `query_runs`: when, who (person or agent, on behalf of whom), source, database badge, kind, tier, level, window, statements, rows, ms, status (refusals and timeouts included, with the refusal rule); paged 50; filters |
| `audit-run` | `/admin/audit/{id}` | one run: its fields, **the SQL while kept** (escaped, in a `<pre>`; "kept 90 days, nulled on {date}" after), each statement from `door_statements` (class, tier, fingerprint, status, SQLSTATE, the masked error, rows, ms, pid), the change set, rehearsal or window it served |
| `audit-reveals` | `/admin/audit/reveals?since=` | `access.grant` / `access.revoke`, `window.*`, `classification.confirm` that cleared a secret, `memory.view`, `memory.reveal`, `session.text_open` and `freeze.*` from `mcp_activity_log`: who, what, which database, when, the reason given — never the content revealed |
| `admin-door` | `/admin/door` | `door_ping()`: up or down, version, libpg_query's version, the pool held / max; today's requests by kind and source (`query_runs`, `door_usage`), refusals today by rule, the longest runs; **whether per-role pgaudit is set** for the write, ops and rolemaker roles (the door's named `role_settings` — "Set by the owner" or "Not set: run ROOT_STEPS step N") |
| `admin-grants` | `/admin/grants` | per registered target: the grants service's last pass (`grants_passes`: when, changes, errors), columns pending (classified since the last pass), tables "not granted to the tool" (the owner re-runs `grant-target.sh`), and the printed root step |
| `admin-agents` | `/admin/agents` | the agents admitted here: name, roles, the rights they keep (`anyone`-held only — the rest refused, said so), **what each may read** (schema and plans only — no rows in version 1; the targets their roles show), their duty, their last runs from the activity log, and their dispatches (`agent_dispatches`: kind, status, attempts, next attempt, the reply's excerpt) with Retry |
| `admin-worker` | `/admin/worker` | `worker_passes` newest first: when, each step's result, errors |
| `admin-freeze` | `/admin/freeze` | the state (Frozen — by whom, since, why — or Running); **Freeze** (reason required, ✔ "Every window ends, no workbench or write runs, every agent tool answers frozen") or **Unfreeze** (✔); the history of `freeze.on` / `freeze.off` |

**The homes** (the shell's `home`, completed here — `home_panels()` gains each slice's query; a panel shows only to a holder of its right):
everyone — the search box, my favourite and recent objects; an Engineer — my workbenches and their expiry (`mcp_workbenches`, mine), change
sets awaiting me (mine in `draft`/`reviewed`/`rehearsed`), drafts not yet observed applied (mine), my open windows; a DBA — blocked sessions now
(the door's named `blocking`, with Cancel linking to the session), health findings by severity (counts from the last `health_findings` pass,
linking to `health-all`), proposals awaiting review, window requests of mine; a super-admin — unclassified databases, grants pending, window
requests awaiting approval, the door's state, the freeze switch (a link to `admin-freeze`). Each panel says "nothing here" in a sentence when
empty and `door-unavailable` when it needed the door and the door did not answer.

## The Advisor's duty and the dispatches (the worker)
- **The duty** is the kernel's (`maludb-os.json` `agents[].duty`, hired by the kernel's `bin/hire_application_agent.php`): weekdays 07:20 the
  kernel runs the Advisor; it reads with its 30 records tools, proposes with `change_set_propose` (at most ten), and posts one note with
  `dba_note_post`. This application holds no model key and calls no model.
- **`advisor_inputs`** (the worker, every minute): reads the door's named `blocking` across the registered application and development
  targets; a root blocker whose victims have waited at least the threshold inserts **one** `agent_dispatches` row (kind `blocked_session`,
  via `chat`, `target_database_id`, keyed so one blocker raises one dispatch per episode) and one `blocked_session` notification per DBA
  (`dx_notify()`; texted to those whose `text_kinds` include it, through the outbox). It sends queued dispatches due now through the chat
  endpoint (divergence 4). A wraparound age above 1.2 billion on any target raises one `wraparound` notification per DBA per day.
- **`notify_outbox`**: email through MaluMail (`malumail_send()`, the kit's) and texts through the kernel (`kernel_send_text()`, K6) for the
  outbox rows due, each once (the dedupe key), with failures retried three times.
- **`retention`**: `query_runs.sql` nulled after `sql_text_days`, `query_runs` and `door_statements` deleted after `audit_keep_days`
  (`dx_query_runs_prune()`), exports past `expires_at` deleted with their files, `row_images` past `undo_days` (`dx_row_images_prune()` — slice
  5's function, run here), read notifications after 90 days.

## Files (exactly these)
- `html/proposals.php`, `html/notes/{index,view,post}.php`, `html/exports/{index,delete,download}.php`, `html/notifications/{index,read,read-all,prefs}.php`,
  `html/me/notifications.php`, `html/admin/settings/{index,save}.php`, `html/admin/audit/{index,view,reveals}.php`, `html/admin/door.php`,
  `html/admin/grants.php`, `html/admin/agents.php`, `html/admin/dispatches/retry.php`, `html/admin/worker.php`, `html/admin/freeze/{index,on,off}.php`
- `app/features/agents/{queries,present,write,dispatch}.php`, `app/features/notes/{queries,write,markdown}.php`, `app/features/exports/{queries,write}.php`,
  `app/features/notifications/{queries,write,outbox}.php`, `app/features/admin/{settings,audit,door,grants,worker,freeze}.php`,
  `app/features/shell/queries.php` (gains `home_panels()`'s queries)
- `app/views/proposals/index.php`, `app/views/notes/{index,view}.php`, `app/views/exports/index.php`, `app/views/notifications/{index,prefs}.php`,
  `app/views/admin/{settings,audit,audit-run,reveals,door,grants,agents,worker,freeze}.php` + `app/views/admin/partials/{audit-row,dispatch-row,setting-field}.php`,
  `app/views/home/partials/{engineer,dba,admin}.php`
- `bin/backup_mark.php` (`php bin/backup_mark.php <datname> <kind> [--at=ISO] [--note=…]` — validates the datname against the registry and
  the kind against `backup_marks`' check; one row; the owner's cron line in `deploy/ROOT_STEPS.sh`'s notes); `bin/worker.php`: the passes
  `advisor_inputs`, `notify_outbox` and `retention` made real
- `tests/phase3/slice10/{run.sh,lib.php,agents.php,notes.php,dispatch.php,exports.php,notifications.php,settings.php,audit.php,admin.php,freeze.php,homes.php,json.php,browser.mjs}`

## Query functions (signatures fixed)
- `find_proposals(PDO $pdo, array $filters, int $page): array{rows, total}` (`mcp_agent_proposals`) · `find_notes(PDO $pdo, int $page): array{rows, total}` ·
  `find_note(PDO $pdo, int $id): ?array` (with its change sets' current states) · `note_markdown(string $body): string` (allow-list renderer, escaped)
- `my_exports(PDO $pdo, int $memberId): array` · `export_download(PDO $pdo, int $memberId, int $id): ?array{path, name, type}` (own, done, not
  expired, not yet downloaded — then `downloaded_at` set)
- `my_notifications(PDO $pdo, int $memberId, int $page): array{rows, total}` · `my_prefs(PDO $pdo, int $memberId): array`
- `audit_runs(PDO $pdo, array $filters, int $page): array{rows, total}` · `audit_run(PDO $pdo, int $id): ?array{run, statements}` ·
  `audit_reveals(PDO $pdo, array $filters, int $page): array{rows, total}`
- `door_page(PDO $pdo): array` (`door_ping()` + today's counts) · `grants_page(PDO $pdo): array` · `agents_page(PDO $pdo): array` (each agent's
  visible targets read with `app.member_id` set to the agent, transaction-locally) · `worker_page(PDO $pdo, int $page): array`
- `home_panels(PDO $pdo, int $memberId): array` (the panels above)
- writes: `dba_note_post(PDO $pdo, int $by, string $title, string $body, array $changeSetIds, ?int $runId): int` (inserts, then
  `dx_notify()` per DBA) · `export_delete(PDO $pdo, int $memberId, int $id): void` (row and file) · `notification_read(PDO $pdo, int $memberId,
  ?int $id): int` (one, or all when null) · `notification_prefs_save(PDO $pdo, int $memberId, array $kinds, array $textKinds, bool $email, bool
  $texts, bool $digest): void` · `dispatch_retry(PDO $pdo, int $id): void` · `settings_save(PDO $pdo, int $by, array $fields): array{before, after}`
  (only the keys sent; the CHECKs refuse out-of-range values with their sentence) · `freeze(PDO $pdo, bool $on, ?string $reason): void` (`dx_freeze()`)
- the worker: `advisor_inputs_pass(PDO $pdo, DateTimeImmutable $now): array{blockers, dispatched, sent}` · `notify_outbox_pass(PDO $pdo, int $limit): array{email, text, failed}` ·
  `retention_pass(PDO $pdo, DateTimeImmutable $now): array{sql_nulled, runs_deleted, exports_purged, images_pruned, notifications_pruned}`

## MCP tools this slice makes real (Phase 4 serves them; the screens read the same views)
`advisor_proposals` (the proposals screen is its SQL), `actor_timeline` (the agents page's last runs and a DBA's view of a person's or an
agent's timeline over the activity view).

## Manifest rows claimed
Screens (15): `proposals`, `notes-list`, `note-view`, `exports-list`, `notifications`, `notification-prefs`, `admin-settings`, `audit`, `audit-run`, `audit-reveals`, `admin-door`, `admin-grants`, `admin-agents`, `admin-worker`, `admin-freeze`
Actions (9): `dba_note_post`, `export_delete`, `notification_read`, `notification_read_all`, `notification_prefs_save`, `dispatch_retry`, `settings_save`, `freeze_on`, `freeze_off`

## Activity log events
`dba_note.post` (the note's id, the count of change sets, the agent run), `export.delete`, `export.download` (the export's id, rows and
bytes — never the content), `notification.read`, `notification.read_all`, `notification.prefs_save`, `dispatch.create` / `dispatch.send` /
`dispatch.retry` (source `cron` or `web`: the kind, the target, the status), `settings.save` (before/after of the keys changed),
`freeze.on` (the reason's first 200 characters), `freeze.off`, `audit.view` (a run opened in full: its id — so the auditor is audited),
`screen.view`.

## Status vocabulary
Proposal states: change set `draft` / `reviewed` / `rehearsed` `text-bg-info` "Awaiting review" · `applied` `text-bg-success` "Applied" ·
`drafted_as_migration` `text-bg-primary` "Drafted" · `discarded` `text-bg-secondary` · `failed` `text-bg-danger`; a note `text-bg-light`
"Posted". Export: queued `text-bg-secondary` · running `text-bg-info` · done `text-bg-success` "Ready — download once" · failed
`text-bg-danger` · downloaded `text-bg-light`. Dispatch: queued · sent · answered · failed · skipped. Run status (audit): ok `text-bg-success`
· error `text-bg-danger` · refused `text-bg-warning` (with the rule) · timeout · cancelled `text-bg-secondary`. Freeze: Frozen `text-bg-danger`
· Running `text-bg-success`. Ids: `proposal-{kind}-{id}`, `note-{id}`, `note-body`, `export-{id}`, `export-{id}-download`,
`notification-{id}`, `prefs-{kind}`, `settings-form`, `setting-{key}`, `audit-row-{id}`, `audit-sql`, `reveal-row-{id}`, `door-state`,
`grants-target-{datname}`, `agent-{id}`, `dispatch-{id}-retry`, `worker-pass-{id}`, `freeze-form`, `home-panel-{key}`.

## Out of scope for this slice
The MCP servers and the registry wrapper (Phase 4 — this slice proves the actions' refusals through the relay, Phase 4 the tools); the
export's making (slice 3); the backups screen (slice 8); the windows' screens (slice 5); the kernel's hire, duty and `message_send`.

## Proof (`tests/phase3/slice10/run.sh`: scratch database `dx_dev10`; php -S on 9401, the fake kernel on 9402 (its chat endpoint answers the Advisor's turn), the fakes on 9403; then the user-level Apache on 9407; a scratch door with scratch roles `dx_proof_*` and scratch targets `dx_t10_app`; Playwright; the registry `--check`)
1. **The agents' doors**: through the fake kernel's relay with the Expert's and the Advisor's action tokens — the five agent actions accepted
   where their slices built them (`dba_note_post` here), **every one of the 59 people-only actions refused 403** with its refusal words and
   nothing written, `is_eval` refusing `dba_note_post`; an agent not admitted refused.
2. **The note**: the Advisor posts a note naming two of its proposals; every DBA has an `advisor_note` notification, a Viewer none; the note's
   body with `<script>` and a link to another host renders as text and an unlinked URL; a note naming a missing change set refused by the
   database; Proposals lists the note and the two change sets with their states as a person applies one and discards the other.
3. **Dispatch**: a scratch session holds a lock on `dx_t10_app` and three others wait past a shortened threshold → one dispatch, one
   notification per DBA, one text to the DBA who opted in (the fake kernel records it); the blocker still there next minute raises no second
   dispatch; the fake kernel's chat endpoint down → `next_attempt_at` backs off; `dispatch_retry` re-queues.
4. **Exports**: an export slice 3 made is listed, downloaded once (a second download 404), deleted with its file; one past `expires_at` purged
   by `retention`.
5. **Notifications**: read, read all, preferences saved; a text kind chosen without the kernel's verified phone is refused with the sentence;
   the outbox sends each email once.
6. **Settings**: a super-admin saves `show_rows` 500 — the door's next run caps at 500; an out-of-range value refused with the CHECK's
   sentence; Marco (admin role, not super) refused.
7. **Audit**: runs of every source and status listed with filters; one opened in full shows its SQL while kept and its masked error, and
   writes `audit.view`; after `sql_text_days` (time moved) the SQL reads "nulled"; reveals lists a cleared secret, a window and a memory reveal
   without their content.
8. **Admin pages**: the door's state up and then down (stopped) — `door-unavailable` and still a page; the grants page names a table not
   granted; the agents page lists both agents with "no rows in version 1"; the worker's passes.
9. **Freeze**: a super-admin freezes with a reason — every open window ends (the WRITE MODE bar goes), a workbench apply and a write refused,
   an agent's tool call answers frozen through the relay; unfreeze; Marco refused both.
10. **The homes** per role (Priya, Dana, the super-admin, Ann) with the panels' data and their empty sentences; `bin/backup_mark.php` records a
    mark and refuses an unknown database.
11. JSON mode on every screen and action; Playwright at 375 × 740 and 1280 × 800 (no horizontal scroll; the audit table becomes cards at
    375); JavaScript off renders every screen; the registry `--check`; every earlier suite re-run green.

## Requirements claimed
MUSTs (17): R88, R91, R92, R93, R94, R102, E8, E10, S12, S17, S18, S19, S20, S21, S22, R72, E11

(R88 exports as background jobs with caps and an audit row — the list, the one-time download, the purge; R91 the agents' SQL lands in the
editor or as a proposed change set, never run; R92 what the AI sees is schema only in version 1, shown on the agents page; R93 the agents'
reads run as the meta tier through the door's named library, capped; R94 agents' proposals and runs in the same history and change log,
attributed; R102 long work in the worker with progress; E8 the audit screens over every statement's row; E10 read tools by default, five
manifest actions, `is_eval` refused, the chat-turn intersection; S12 the tool's audit plus the per-role pgaudit state shown; S17 the backup
posture recorded by `bin/backup_mark.php`; S18 agents hold no database credential; S19 agents' reads bounded; S20 agents' writes are
proposals; S21 no outbound tool in the tool's agents; S22 evaluations never execute; R72 every refusal tested; E11 the freeze and every
destructive admin action behind a full-page confirm, never a modal.)

## Decisions taken here
1. The Advisor's note is `dba_note_post` + `dba_notes`, notified to every holder of `maintenance.run` (divergence 1).
2. The blocked-session threshold is ten minutes until a setting exists (divergence 2).
3. Dispatches go through the chat endpoint as the first active DBA until K8 (divergence 4).
4. A note's markdown is rendered by an allow-list renderer to text; links only to this application's own paths.
5. An auditor opening a run in full is itself logged (`audit.view`).
6. The settings form shows `door_pool_max` read-only (a door restart is the owner's).

## Open questions
None.
