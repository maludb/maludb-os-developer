# Build spec: Phase 2 — sign-on, the mirror, the shell, the door's client (before any slice)

What exists at the end: a person clicks Developer on the launcher — or types `developer.<domain>` on a phone — and lands, signed in, in the
finished shell of an application with no screens yet: the nxl layout with the sidebar (Home · Databases · Search · SQL · Workbenches ·
Changes · Drafts · Activity · Health · Memory · History · Admin, each gated by its right), the header's search box, **the class badge slot**
(empty on a screen that names no database), the application switcher, the bell, the user menu, the command bar, the bottom tab bar at 375 px
(Home · Databases · Activity · Me); **the red WRITE MODE bar** standing on every screen while the person holds an open write window; the
session remembers **when the person last signed on through the launcher** (the step-up of design §3 wall 4) and ends after 30 idle minutes;
the mirror refreshes every minute; every request is logged; the command bar answers through the kernel; the record picker is in the shell
with its `member` source; **Developer's PHP runs in its own PHP-FPM pool as `developer-web`** and talks to **the door** — running under
systemd beside **the grants service** — only through `app/developer/door.php`, which answers `door_unavailable` in a sentence when the door
is down; every later screen answers as a placeholder that names the slice that builds it; the worker runs a pass every minute whose thirteen
steps are stubs but one. **The kit is in the repo already (Phase 0) and proven without a kernel (`tests/phase0/run.sh`, 102 checks)**; this
phase wires the shell around it and proves it under php -S and a user-level Apache at 375 and 1280. It follows Boards' Phase 2
(`/srv/apps/boards/docs/build-specs/sso-shell.md`, built 2026-10-10) and the Data Lake's (the query service's client is the model for the door's).

Schema it runs on (db/001–012, never modified): `members` (+ `is_agent`), `departments`, `department_members`, `directory_sync_state`,
`sso_nonces`, `member_sessions` (db/001); `activity_log` (+ `token_id`, `target_database_id`) (db/002); `mcp_access_tokens`, `key_usage`,
`mcp_resolve_token()` (db/003); `dx_rights` (+ `held_by`), `dx_roles`, `dx_role_rights`, `dx_member_roles()`, `dx_member_has_right()`,
`dx_has_right()`, `dx_right_refusal()`, `dx_is_developer_admin()`, `dx_is_member_here()`, `mcp_app_roles` (db/004); `dx_settings`
(`idle_timeout_minutes`, `step_up_minutes`, `frozen` …), `dx_setting_int|text|bool()` (db/005); `target_databases`, `access_windows`,
`dx_open_window()`, `dx_door_policy()`, `dx_door_member_active()` (db/006); `notifications`, `notification_prefs`, `worker_passes` (db/011);
`dx_caller_may()`, `mcp_activity_log`, `mcp_visible_targets` (db/012).

## Divergences from the design
1. **The home, the notifications and the search results are the slices'.** `home` is the shell's screen (the manifest's "The shell"
   section) but its role panels are filled by the slices that own their data: Phase 2 renders the search box, "my recent objects" (empty),
   and one card per panel saying which slice fills it; slice 10 completes it (agents-admin.md "The homes"). `search` is slice 1's,
   `notifications` slice 10's. The header's bell (unread `notifications`, a link to `/notifications`) and the header's search box (a GET to
   `/search?q=`) land on placeholders until their slices.
2. **The session records the hand-off time and an idle timeout** — the kit records neither. `html/sso.php` sets `$_SESSION['handoff_at']`
   (the verified claims' `iat`, as an ISO time) and `$_SESSION['last_active']`; `app/bootstrap.php` ends a session idle longer than
   `dx_setting_int('idle_timeout_minutes')` (`end_session($pdo, 'idle')`, logged `member.session_ended` with `reason = idle`, then the
   launcher) and refreshes `last_active` on every request. **Nothing client-influenced is ever deserialised**: the session holds scalars only
   (member id, hand-off time, last active, CSRF token, flash), never an object; no cookie but the session's.
3. **`dx_guard()` learns the schema's refusals.** The kit maps P0001, 23514, 23505, 23503 and P0002 (`DB_SENTENCE_CODES`); db/006–012 also
   raise **42501** (`insufficient_privilege` — "Your role does not let you …", "Only a super-admin …") and **22023** (`invalid_parameter_value`).
   Phase 2 adds 42501 → `refuse(403, db_message($e, 'You may not do that.'))` and 22023 → `refuse(422, db_message($e, 'That request is not
   well formed.'))` — Boards' and Sales CRM's lesson, proven with a fixture route. `db_message()` shows 42501's text only when a function
   raised it; PostgreSQL's own "permission denied for table …" falls back to the handler's sentence.
4. **No personal MCP tokens and no API keys** (design §4): the shell has no tokens screen; `bin/mint_mcp_token.php` stays for the proofs.
5. **The door and the grants service run under systemd from Phase 2**, but the shell asks the door only two things: `ping` (the health
   endpoint and Admin's placeholder) and the named catalog query `databases` (the proof that a named request round-trips with the caller's
   policy). Every other kind is a slice's.

## Who may do what
The shell changes nothing (no actions). Every screen: `require_login()` (a person, or an agent's relayed call through the action token);
**the sidebar shows an entry only to a holder of its right** — and hiding is never authorisation (R67): every placeholder calls
`require_right()` with the right of the screen it stands for, so a typed URL is refused the same way. The rights per entry:

| Entry | URL | Right |
|---|---|---|
| Home | `/` | — (any admitted member) |
| Databases | `/databases` | `catalog.read` |
| Search | `/search` | `catalog.read` |
| SQL | `/sql/history` | `data.read` |
| Workbenches | `/workbenches` | `workbench.use` |
| Changes | `/changes` | `catalog.read` |
| Drafts | `/drafts` | `catalog.read` |
| Activity | `/sessions` | `activity.read` |
| Health | `/health` | `health.read` |
| Memory | `/memory` | `memory.read` |
| History | `/drift` | `health.read` |
| Admin | `/admin/registry` | any of `registry.manage`, `access.manage`, `settings.manage`, `audit.read`, `freeze` (`require_any_right()`) |
| Me | `/me` | — |

## Screens
| Screen id | Canonical URL | Purpose |
|---|---|---|
| `home` | `/` | the search box (`#home-search`, a GET to `/search`); "My recent objects" (from `recents`, empty until slice 1 writes them); one card per role panel naming the slice that fills it (design §9 "Home"); for a super-admin, **the freeze state** read from `dx_settings` (Frozen · by · since · reason) — the switch itself is slice 10's |
| `me` | `/me` | who I am here: my display name, my roles and the rights they give (from `dx_member_roles()` and `dx_rights`, people-only and super-admin-only rights marked), my level on each database (empty until slice 1's `target_access` rows exist, then `mcp_target_databases.my_level`), my open windows (`mcp_access_windows`, empty until slice 5), when I last signed on through the launcher and when a window would need me to again ("Windows need a sign-on newer than 10 minutes — sign on again"), and Sign out |
| `my-trail` | `/me/trail` | my own trail here in sentences (`activity_sentence()`): "You ran 3 statements on *subello_gl*", "You confirmed *subello_hr* as an application database" — the database a link to `/db/{datname}`; paged 50, newest first; filters: since, datname; **never SQL text, never a value** (the log never holds them) |

**The placeholders** (one controller per later screen URL, each calling `render_nav_stub($screen, $slice)` — the registry marks them `stub`;
a placeholder answers 200 to a person, "Built by slice N — {the manifest's line}", and 501 `not_built` to JSON and to a POST):

- slice 1: `/databases` · `/db/{datname}` · `/db/{datname}/s/{schema}` · `/db/{datname}/s/{schema}/{family}` · `/db/{datname}/o/{address}` ·
  `/search` · `/favourites` · `/admin/registry` · `/admin/registry/{datname}` · `/admin/access` · `/admin/access/{datname}` · `/db/{datname}/classifications`
- slice 2: `/db/{datname}/o/{address}/{ddl,dependencies,impact,privileges,statistics}` · `/db/{datname}/join-path` · `/roles` · `/roles/{role}`
- slice 3: `/db/{datname}/sql` · `/sql/history` · `/sql/runs/{id}` · `/saved` · `/saved/{id}` · `/saved/new` · `/saved/{id}/edit`
- slice 4: `/workbenches` · `/workbenches/new` · `/workbenches/{id}` · `/workbenches/{id}/import` · `/forms/{datname}/{family}/{verb}` ·
  `/changes` · `/changes/{id}` · `/changes/{id}/edit` · `/rehearsals/{id}` · `/drafts` · `/drafts/{id}`
- slice 5: `/db/{datname}/o/{address}/data` · `/db/{datname}/o/{address}/rows/{key}` · `/db/{datname}/o/{address}/rows/new` ·
  `/db/{datname}/o/{address}/rows/{key}/edit` · `/changes/{id}/rows` · `/changes/{id}/conflict` · `/windows` · `/windows/new` · `/windows/{id}`
- slice 6: `/plans` · `/plans/{id}`
- slice 7: `/sessions` · `/db/{datname}/activity` · `/sessions/{pid}` · `/sessions/locks` · `/statements` · `/server` · `/db/{datname}/vacuum` ·
  `/maintenance` · `/maintenance/new`
- slice 8: `/health` · `/db/{datname}/health` · `/db/{datname}/bloat` · `/db/{datname}/indexes` · `/db/{datname}/history` ·
  `/db/{datname}/o/{address}/history` · `/drift` · `/compare` · `/compare/object` · `/db/{datname}/diagram` · `/backups`
- slice 9: `/memory` · `/memory/{datname}/{schema}` · `/memory/{datname}/{schema}/{episodes,graph-stats,config,graph,documents}` · `/memory/isolation`
- slice 10: `/proposals` · `/notes` · `/notes/{id}` · `/exports` · `/notifications` · `/me/notifications` · `/admin/settings` · `/admin/audit` ·
  `/admin/audit/{id}` · `/admin/audit/reveals` · `/admin/door` · `/admin/grants` · `/admin/agents` · `/admin/worker` · `/admin/freeze`

A placeholder that names a database (`{datname}` in its URL) checks it first: **a database the caller's class and level do not show answers
404** (`dx_target_or_404()`, below) — the same nothing as a database that does not exist — and the placeholder then shows the database's
**class badge and the caller's level**, so slice 1 inherits the gate and the header from day one.

## The class badge, the level and the WRITE MODE bar (`app/views/shared/{class-badge,level-badge,write-mode-bar}.php`)
Every later screen that names a database uses these three partials, in the header and in every `hx-confirm` question (S24, R69):

| Class | Badge | Colour (border-left of the header and the confirm) |
|---|---|---|
| `application` | `text-bg-danger` "Production · {application_key}" | `#d63939` (or the registry's `colour`) |
| `workbench` | `text-bg-success` "Workbench" | `#2fb344` |
| `development` | `text-bg-info` "Development" | `#4299e1` |
| `memory` | `text-bg-purple` "Memory" | `#ae3ec9` |
| `kernel` | `text-bg-dark` "Kernel — structure only" | `#1d273b` |
| `own` | `text-bg-secondary` "This tool" | `#667382` |

A private-by-design target adds a `text-bg-warning` "Private" chip. **The level badge**: structure `text-bg-light` "Structure only" · masked
`text-bg-warning` "Rows, masked" · rows `text-bg-primary` "Rows". **The WRITE MODE bar** (`#write-mode-bar`, `bg-danger text-white`, sticky
under the header on every screen, the layout reads `dx_open_window(me, null, 'write')` once per request): `WRITE MODE · {datname} · {n} min ·
End now` — "End now" posts `window_end` (slice 5's action; until slice 5 the bar is never shown, as no write window can open). It listens for
`windowChanged` and re-renders. A read window shows a quieter `bg-warning` "READ WINDOW · {datname} · {n} min" bar.

## The browser (design §8)
- **htmx** configured once in `layout.php` by a `<meta name="htmx-config">`: `{"allowEval": false, "allowScriptTags": false,
  "selfRequestsOnly": true, "historyCacheSize": 0, "includeIndicatorStyles": false}` — no result page is kept in local storage.
- **The Content Security Policy** is the vhost's (already in `deploy/apache-developer.conf`): `script-src 'self'`, no inline script, no
  `unsafe-eval`, `frame-ancestors 'none'`, `connect-src 'self'`. Phase 2 moves every inline `<script>` of the kit's views into
  `html/assets/js/app.js`; the proof fails on any inline script or `on*=` attribute in a rendered page.
- **Every string from a database is escaped** (`e()`), never rendered as HTML (S8, R103) — the shell renders none yet, and the proof plants
  a member display name holding `<script>` to show it escaped.
- **No shell-like feature** (R104): no route takes a command; `/api/` answers only `/api/v1/health`.

## The door's client (`app/developer/door.php`) — `docs/build-specs/the-door.md` is the protocol
PHP holds no credential to any database but its own and never opens a connection to a target (E7, S1). Everything it asks of a target goes
through these functions, over the Unix socket `DX_DOOR_SOCKET`, one JSON line per request, the HMAC under `DX_DOOR_KEY` (canonical JSON,
sorted keys, no spaces, without `mac`), `ts` now, a fresh `request_id` (the kit's `request_id()` plus a counter), `caller` = the session's
member id, `on_behalf_of` and `agent_run_id` from the action token's run facts (K38) when an agent's relayed call is the caller, and the
`source` (`web` · `grid` · `form` · `editor` · `worker` · `rehearsal` · `memory`):

- `door_request(array $req, float $timeout = 5.0): array` — **calls `session_write_close()` first** when a session is open (E18 — so Cancel
  is never queued behind the run it cancels), connects, writes, reads one line (≤ 16 MB), decodes. A connect failure, a timeout or a
  malformed answer returns `['status' => 'unavailable', 'rule' => 'door_unavailable', 'message' => 'The door is not answering right now —
  try again in a moment.']`; never throws, never a 500.
- `door_ping(): array` — `{status, version, libpg_query, pool: {held, max}, frozen}`.
- `door_named(string $datname, string $name, array $params = [], string $source = 'web'): array` — a named query of the door's library.
- `door_unavailable_partial(array $answer): string` — the one alert every screen renders for `unavailable` (`app/views/shared/door-unavailable.php`).
- `door_refusal_words(array $answer): string` — the door's `refusal.message`, falling back to the rule's sentence table in the-door.md.

The slices add their kinds' wrappers to this file (`door_run`, `door_cancel`, `door_apply`, `door_workbench_*`, `door_rehearse`,
`door_memory`, `door_explain`) — each named in its slice spec and specified in the-door.md; this phase writes the four above and their tests.

## Files (exactly these)
**In the repo (proven by `tests/phase0/run.sh`):** `app/{bootstrap,db,http,directory,auth,handler,activity,mail,partial_update}.php`,
`app/api/{bootstrap,kernel}.php`, `bin/{directory_sync,dev_handoff,mint_mcp_token,make_brand_images,worker,build_action_registry,sync_approvals}.php`,
`bin/dev_directory.json`, `mcp/{activity_ingest.py,db.py,server_common.py,requirements.txt}`, `tests/{dev_router,fake_kernel,fake_maludb,fake_malumail}.php`,
`tests/setup_dev.sh`, `tests/phase0/`, `html/{index,logout,sso}.php`, `html/sso/logout.php`, `html/api/v1/health.php`, `html/assets/` (the theme),
`services/door/`, `services/grants/`, `deploy/` (the vhost, the pool, the units, ROOT_STEPS.sh).
**Phase 2 adds:**
- `app/features/shell/{nav,queries}.php` — `NAV_ITEMS` (the table above), `NAV_SLICES` (every placeholder's screen → slice, title, the
  manifest's line, its right, its menu entry, whether it names a database), `render_nav_stub(string $screen, int $slice): never`,
  `nav_items_for(int $memberId): array`, `bell_count()`, `business_name()`.
- `app/features/estate/gate.php` — **the target gate every slice calls**: `dx_target_or_404(PDO $pdo, string $datname): array` (the
  `mcp_target_databases` row as the caller, or 404 — a name outside `^[a-z0-9_]{1,63}$` is 404 before any query), `dx_target_header(array
  $target): array` (class, badge, colour, private chip, level — for the partials).
- `app/developer/door.php` (the client above); `app/features/me/queries.php`; `app/features/activity/queries.php`; `app/switcher.php` (verbatim
  from `~/htmx-php-builder/skills/design-system/examples/php/app-switcher/switcher.php`, the kit branch).
- The record picker verbatim from `examples/php/record-picker/`: `app/picker.php`, `app/pickers.php` with **one source** — `member` (people
  admitted here; **agents are never offered**, since no level, window or grant may name one; never an external to an external caller) —,
  `html/pick/index.php`, `app/views/shared/picker-rows.php`, `html/assets/js/record-picker.js`, the one `#record-picker` modal in
  `layout.php` after `</main>`. Slice 1 adds `target`; slice 5 adds the referenced-table source.
- Views: `app/views/layout.php` (the nxl shell of `references/layout-skeleton.html`: the sidebar, the header — the search box `#header-search`,
  the class-badge slot `#header-target`, the switcher before the dark-mode toggle, the bell, the user menu with Me · My trail · Sign out —,
  the WRITE MODE bar, `#page-content`, the command bar `#assistant-bar`, the bottom tab bar at 375), `app/views/shared/{header,tab-bar,
  assistant-bar,assistant-reply,app-switcher,page-header,record-card,nav-stub,notice,class-badge,level-badge,write-mode-bar,door-unavailable}.php`
  (+ the kit's `flash.php`, `message.php`), `app/views/home/page.php` (replacing `home/placeholder.php`), `app/views/me/page.php`,
  `app/views/activity/page.php` + `partials/rows.php`; `html/assets/js/app.js` (the htmx event wiring that was inline).
- Handlers: `html/index.php` (home), `html/me/index.php`, `html/me/trail.php`, `html/assistant/ask.php` (the command bar → the kernel's chat
  endpoint through `ask_assistant()`; refuses an action token — "The command bar is for a person at the screen.", 403), and the placeholders
  listed above, one file each at the controller the rewrites below name.
- `app/handler.php`: `dx_guard()` gains 42501 and 22023 (divergence 3). `html/sso.php`: the hand-off time, `notification_prefs` ensured (`INSERT …
  ON CONFLICT DO NOTHING`); `bin/directory_sync.php` ensures prefs for every admitted member. `app/bootstrap.php`: the idle timeout.
- `deploy/apache-developer.conf`: **the canonical-URL rewrites** (below), `AllowEncodedSlashes NoDecode` in both vhosts; the same rules in
  `tests/dev_router.php`.
- `tests/phase2/{run.sh,lib.php,shell.php,session.php,door.php,guard.php,vhost.php,browser.mjs}`, `tests/phase2/apache.conf.tmpl` (the user-level
  Apache, which hands `.php` to a user-level php-fpm pool on a scratch socket so the proof runs the production handler, not mod_php).

## The canonical-URL rewrites (in this order, before the estate's generic rules; `[B]` re-escapes a back-reference placed in a query string)
```
AllowEncodedSlashes NoDecode
RewriteRule ^/db/([a-z0-9_]{1,63})$                                   /db/view.php?datname=$1 [L,QSA]
RewriteRule ^/db/([a-z0-9_]{1,63})/complete\.json$                    /db/complete.php?datname=$1 [L,QSA]
RewriteRule ^/db/([a-z0-9_]{1,63})/s/([^/]+)$                          /db/schema.php?datname=$1&schema=$2 [B,L,QSA]
RewriteRule ^/db/([a-z0-9_]{1,63})/s/([^/]+)/([a-z_]+)$                /db/family.php?datname=$1&schema=$2&family=$3 [B,L,QSA]
RewriteRule ^/db/([a-z0-9_]{1,63})/o/([^/]+)$                          /db/object.php?datname=$1&address=$2 [B,L,QSA]
RewriteRule ^/db/([a-z0-9_]{1,63})/o/([^/]+)/data/rows$                /db/object-data-rows.php?datname=$1&address=$2 [B,L,QSA]
RewriteRule ^/db/([a-z0-9_]{1,63})/o/([^/]+)/rows/new$                 /db/row-form.php?datname=$1&address=$2 [B,L,QSA]
RewriteRule ^/db/([a-z0-9_]{1,63})/o/([^/]+)/rows/([A-Za-z0-9_-]+)/edit$  /db/row-form.php?datname=$1&address=$2&key=$3 [B,L,QSA]
RewriteRule ^/db/([a-z0-9_]{1,63})/o/([^/]+)/rows/([A-Za-z0-9_-]+)/value$ /db/row-value.php?datname=$1&address=$2&key=$3 [B,L,QSA]
RewriteRule ^/db/([a-z0-9_]{1,63})/o/([^/]+)/rows/([A-Za-z0-9_-]+)$   /db/row.php?datname=$1&address=$2&key=$3 [B,L,QSA]
RewriteRule ^/db/([a-z0-9_]{1,63})/o/([^/]+)/(ddl|dependencies|impact|privileges|statistics|history|data)$ /db/object-$3.php?datname=$1&address=$2 [B,L,QSA]
RewriteRule ^/db/([a-z0-9_]{1,63})/(sql|activity|health|history|diagram|bloat|indexes|vacuum|classifications|join-path)$ /db/$2.php?datname=$1 [L,QSA]
RewriteRule ^/forms/([a-z0-9_]{1,63})/([a-z_]+)/(create|alter|drop|truncate)$ /forms/form.php?datname=$1&family=$2&verb=$3 [L,QSA]
RewriteRule ^/memory/isolation$                                        /memory/isolation.php [L,QSA]
RewriteRule ^/memory/([a-z0-9_]{1,63})/([^/]+)$                        /memory/tenant.php?datname=$1&schema=$2 [B,L,QSA]
RewriteRule ^/memory/([a-z0-9_]{1,63})/([^/]+)/(episodes|graph-stats|config|graph|documents)$ /memory/$3.php?datname=$1&schema=$2 [B,L,QSA]
RewriteRule ^/roles/([^/]+)$                                           /roles/view.php?role=$1 [B,L,QSA]
RewriteRule ^/admin/registry/([a-z0-9_]{1,63})$                        /admin/registry/entry.php?datname=$1 [L,QSA]
RewriteRule ^/admin/access/([a-z0-9_]{1,63})$                          /admin/access/target.php?datname=$1 [L,QSA]
RewriteRule ^/admin/audit/reveals$                                     /admin/audit/reveals.php [L,QSA]
RewriteRule ^/sessions/locks$                                          /sessions/locks.php [L,QSA]
RewriteRule ^/sessions/poll$                                           /sessions/poll.php [L,QSA]
RewriteRule ^/compare/object$                                          /compare/object.php [L,QSA]
```
Then the estate's generic rules already in the vhost (`/x/{id}/verb`, `/x/new`, `/x/{id}/edit`, `/x/{id}`, `/x` → `x.php` or `x/index.php`)
serve `/sql/runs/{id}`, `/saved/…`, `/workbenches/…`, `/changes/…`, `/rehearsals/{id}`, `/drafts/…`, `/windows/…`, `/plans/…`, `/sessions/{pid}`,
`/maintenance/…`, `/notes/…`, `/admin/audit/{id}` and the rest. **A controller re-validates every value a rewrite passed** (the datname pattern,
an address parsed by `dx_parse_address()` — slice 1); the rewrite only routes.

## The receiver, every request, the worker
**The receiver (`/sso`)** — the kit's (verify both signatures, the TTL, the audience `APP_KEY = developer`, the single-use nonce; mirror the
member and departments from the claims; refuse an unknown or ungranted member with `member.sign_on.refused`; **a grant that carries no roles is
no role** — the member is refused here, fail closed; open the hardened session) and then: record the hand-off time; ensure
`notification_prefs`; log `member.sign_on` with the roles; 302 to `/` (or the same-origin `next`, through `safe_local_path()`).
**Every request** — `app/bootstrap.php` as the kit has it: the session re-checked against the mirror (a revoked grant → the launcher within a
minute — the mirror's timer), the idle timeout, `app.member_id` on the connection, the action-token / relay path for the kernel's actions
server (`source = 'agent'`), `json_mode_begin()`, `log_screen_view()` on GET screens.
**The worker** — `bin/worker.php` as the kit has it: one pass a minute under its advisory lock, `worker_passes` written, thirteen steps:
`key_usage_prune` real, the other twelve stubs naming their slice (discovery 1, catalog_index 1, window_expiry 5, workbench_expiry 4,
applied_drafts 4, maintenance_jobs 7, export_jobs 3, snapshots 8, undo_prune 5, notify_outbox 10, advisor_inputs 10, retention 10). The worker
asks the door as its own source (`worker`) through the same client; it holds no target credential either.
**The services** — `developer-door.socket` + `developer-door.service` and `developer-grants.service` (in `deploy/`, the owner's ROOT_STEPS
install them): Phase 2 proves the door answers `ping` and the named `databases` query through the socket from PHP; the grants service runs
its pass over an empty plan and records it (`dx_grants_pass_log()`).

## MCP tools this slice names (Phase 4 serves them; the shell's screens read the same SQL)
`app_roles` (the kernel's token alone; the app-roles view of db/004), `record_history`, `recent_activity`, `activity_search` (the trail
screen is the activity view for oneself; `record_history` for a database's own trail lands with slice 1's database page).

## Query functions (signatures fixed)
- `bell_count(PDO $pdo, int $memberId): int` · `business_name(PDO $pdo): string` · `nav_items_for(int $memberId): array`
- `find_my_activity(PDO $pdo, int $memberId, array $filters, int $page): array{rows, total}` (over `mcp_activity_log`) · `activity_sentence(array $row): string`
- `me_summary(PDO $pdo, int $memberId): array{roles, rights, levels, windows, handoff_at, step_up_due_at}`
- `home_panels(PDO $pdo, int $memberId): array` (Phase 2: recents and the freeze state; each slice adds its panel's query here — the list in agents-admin.md)
- `members_for_pick_q(PDO $pdo, string $q, array $params, int $page): array` (people only)
- `dx_target_or_404(PDO $pdo, string $datname): array` · `dx_target_header(array $target): array`
- the door's client above · `ask_assistant()` — the kit's (`app/api/kernel.php`), unchanged.

## Manifest rows claimed
Screens (3): `home`, `me`, `my-trail`
Actions (0):

Routes, not rows: `/sso`, `/sso/logout`, `/api/v1/health`, `/pick/`, `/assistant/ask` (the command bar's post to the kernel), the switcher's
feed. The placeholders are claimed by the slices that build them, never here.

## Activity log events
`member.sign_on`, `member.sign_on.refused`, `member.sign_out`, `member.session_ended` (`reason`: idle, revoked, kernel_logout), `screen.view`
(every GET screen and placeholder: the screen id, `target_database_id` when it names one), `assistant.ask` (the length and the screen, never the
words), `worker.pass`, `door.unavailable` (once per minute at most, from the client: the kind and the source — never a request's content).

## Status vocabulary
The bell `badge text-bg-danger` with the unread count (hidden at 0). The class badge, the level badge and the two window bars as tabled above.
The role badge in the header: Super-admin › Developer admin › DBA › Engineer › Viewer (`dx_member_roles()`'s highest; a super-admin is always
admin). Ids: `header-search`, `header-target`, `header-user-name`, `bell`, `bell-count`, `tab-bar`, `nav-{key}`, `nav-stub`, `write-mode-bar`,
`read-window-bar`, `home-search`, `home-recents`, `me-roles`, `me-levels`, `activity-row-{id}`, `record-picker`, `assistant-bar`, `door-unavailable`.

## Out of scope for this phase
Every database, object, SQL, change, data, plan, operations, health, memory and admin screen (the slices); the worker's real passes but
key-usage pruning; the door's kinds beyond `ping` and `named`; the MCP servers (Phase 4).

## Proof (`tests/phase2/run.sh`: scratch database `dx_dev2` via `tests/setup_dev.sh`; php -S on 9401, the fake kernel on 9402, the fake MaluDB + MaluMail on 9403; then the same under a user-level Apache on 9407 rendering `deploy/apache-developer.conf` with the scratch ports and a user-level php-fpm pool on a scratch socket — no root; a scratch door on a scratch socket with scratch roles `dx_proof_*`; Playwright from `/var/www/web/node_modules`)
1. **Sign-on**: the Phase 0 refusals re-run — **a replayed hand-off refused**, an expired one, the wrong audience, **an unknown member
   refused**, a tampered signature, no grant, **a grant with no roles refused**; sign-on for the fixtures (Priya engineer, Marco admin + dba,
   Bea no roles → refused, Ann external viewer, Dana dba, the super-admin) with their resolved roles; `notification_prefs` exists for each
   after sign-on, and for every admitted member after one sync; `handoff_at` is the claims' time.
2. **Sessions**: idle past the setting → the launcher and `member.session_ended` (idle); **a revoked grant shuts every door within a minute**
   (the sync drops the role; the next request of an open session goes to the launcher; a door request on that member's behalf answers
   `member` — `dx_door_member_active()` false); the kernel's logout notice ends the session.
3. **The menu per role** (and the same refusal for a typed URL): Admin only for the super-admin and Marco; Workbenches and SQL not for Ann;
   Memory and Health for every role holding them; Bea never gets in.
4. **Every placeholder** answers 200 with its slice's line to a person and 501 to JSON and to a POST; a placeholder naming `subello_gl` (a
   scratch target registered as application) shows the class badge and the level; one naming an unregistered or a system database answers
   404, and a name outside the pattern answers 404 without a query; the registry `--check` counts them as `stub`.
5. **The guard** (a fixture route `/__proof/guard.php`, only under the scratch environment): 403 with the database's sentence for 42501 raised
   by a function, the handler's sentence for a bare permission error, 422 for 22023 — never a 500.
6. **The door**: `door_ping()` answers through the socket from PHP running as the pool's user; `door_named('dx_t2_app', 'databases')` round-trips
   with the caller's policy; **the door refuses a peer outside its group** (a client run as another uid), **a request without its HMAC** and
   one with a stale `ts` or a replayed `request_id`, and **a target outside the registry** (`refusal.rule = unregistered`); with the door
   stopped every screen that asks it renders `door-unavailable`, the health endpoint says `door: down` and still answers 200, and
   `door.unavailable` is logged once.
7. **The grants service** runs one pass over an empty plan and records it; the health endpoint reports the door's state.
8. **The browser**: htmx's config as stated; no inline `<script>` and no `on*=` attribute in any rendered page; the CSP header present under
   Apache; a member display name holding `<script>alert(1)</script>` renders escaped in the header and the trail.
9. **The WRITE MODE bar**: with a scratch open write window inserted for Dana on `dx_t2_app`, the bar stands on every screen with the minutes
   left; for a read window the quieter bar; for nobody else.
10. The trail lists my sign-on in sentences; the command bar's post reaches the fake kernel's chat endpoint and renders the reply; an action
    token at `/assistant/ask` is refused; the switcher renders the fake kernel's applications with Developer current; the picker's `member`
    source never offers an agent.
11. The worker's pass is logged with thirteen steps. Playwright at 375 × 740 and 1280 × 800: no horizontal scroll, the tab bar at 375 and the
    sidebar at 1280, the bell, HTMX navigation pushing URL and title, no console errors (none from the CSP); JavaScript off still renders every
    placeholder. Under Apache, **every `.php` is served by the pool's user** (the fixture route reports `posix_geteuid()`), and an encoded
    address (`table%3Apublic.%22we%2Fird%22`) reaches `object.php` intact.
12. The installer's `plan` clean but for the ports ROOT_STEPS step 0 pins; `php bin/build_action_registry.php --check`; Phase 0's suites
    (`tests/phase0/run.sh`, `tests/door/run.sh`) and Phase 1's checks re-run green.

## Requirements claimed
MUSTs (32): E1, E2, E3, E7, E14, E16, E18, E20, E22, E23, S1, S7, S8, S10, S23, S24, R7, R67, R69, R70, R72, R103, R104, T11, T28, T29, T30, MR3, R101, E19, S3, E17

(E1 the order is this phase's gate; E2 sign-on, mirror, guard, health, switcher, picker; E3 its own database and read roles on views; E7 the
door's client is PHP's only path; E14 the pinned ports read at boot; E16 no modal but the picker; E17 no SPA, no CDN, committed assets only;
E18 the session released before every door call; E19 the door's sentences shown to the asker only, never logged; E20 JSON mode and the action
token; E22 the manifest's `sso`, `assistant`, `agents[]`; E23 nothing secret committed, scratch-named proofs; S1 the pool runs as
`developer-web`, no superuser; S3 no host or connection string accepted anywhere — the gate's pattern; S7 one connection per request, the
door's own; S8 escaping, CSP; S10 POST + CSRF + authorization + log, GET reads only; S23 kernel sign-on and the per-request re-check; S24 the
class badge everywhere; R7 every screen a plain URL; R67 hiding is never authorisation; R69 the environment label; R70 the stricter production
defaults — the idle timeout, the confirm questions carrying the badge; R72 guards fail closed with tests; R101 the tool's state in its own
database; R103 escaping; R104 no shell-like feature; T11 no PDO to a target; T28 the connection cap honoured by the client's single
connection; T29 no persistent connections (`pgsql.allow_persistent` off in the pool); T30 the session service is the door; MR3 one module —
the door's client — talks to every database, memory included.)

## Decisions taken here
1. `/` is the shell's home with the search box, recents and the freeze state; the slices fill their panels (slice 10 completes it).
2. The session records `handoff_at` from the verified claims and an idle timeout from `dx_settings`; the session holds scalars only.
3. `dx_guard()` maps 42501 → 403 and 22023 → 422 with the database's sentence (divergence 3).
4. The picker's `member` source offers people only — no level, window, access grant or classification ever names an agent.
5. The bottom tab bar at 375 is Home · Databases · Activity · Me (design §9); Me opens Me · My trail · Sign out.
6. The target gate (`dx_target_or_404()`) lives in `app/features/estate/gate.php` and is in front of every placeholder that names a database.
7. The shell's proof runs under a user-level Apache handing `.php` to a user-level php-fpm pool, so the production handler path (FPM, not
   mod_php) is the one proven without root.
8. The door's client releases the session before every request; a door that does not answer is a sentence on the screen, never an error page.

## Open questions
None.
