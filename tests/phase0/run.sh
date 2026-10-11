#!/usr/bin/env bash
# Phase 0 proof, repeatable: the schema (db/proof/phase0_proof.sql, the schema's checks — skipped with a line when the file is
# not there yet) and the kit without a kernel (testing-without-a-kernel.md §4) — the directory fixture applied, the roles from
# access[], Developer's four roles and the walls on who may hold a right (rows, writes and session control a person's, never an
# agent's; administration a super-admin's alone, D9; a grant without roles holds nothing), the settings as §6.1–§6.10 seed them, a
# hand-off minted the kernel's way and presented, its replay / expiry / another audience / an unknown member / a tampered signature /
# a member with no grant refused, every refusal logged, a member admitted with no Developer role told why, health answering, CSRF, the
# activity funnel with the target database's id, a person's key and the rate rule, the sign-out notice ending sessions, a grant the
# kernel revoked shutting the door, the worker's empty pass, the ingest bridge against a fake MaluDB, and PHP holding no target
# database's credential. Scratch database only (dx_dev0); the installed application (if any) is never touched, and nothing here reaches
# a target database (tests/door/ proves the door). Ports 9401 (the app), 9402 (the fake kernel), 9403 (the fake MaluDB + MaluMail REST);
# 9404–9405 are the MCP servers' (Phase 4). Prints ok/FAIL per check and a count; exits non-zero on any failure. Needs
# `sudo -n -u postgres` (scratch dx_* databases and the three developer_* roles only — the owner's leave of 2026-10-11), php 8.3, curl,
# openssl, and for the ingest check a python with asyncpg + httpx (/var/www/mcp/venv/bin/python, else $DX_PY).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
export DX_DEV_DB=${DX_DEV_DB:-dx_dev0}
export DX_DEV_ENV=${DX_DEV_ENV:-/tmp/dx-dev0.env}
PY=${DX_PY:-/var/www/mcp/venv/bin/python}
PORT=9401; P_KERNEL=9402; P_FAKE=9403
TMP=$(mktemp -d /tmp/dx-kit.XXXXXX)
pass=0; fail=0; PIDS=()
ok()   { echo "ok   $1"; pass=$((pass+1)); }
bad()  { echo "FAIL $1"; fail=$((fail+1)); }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, wanted: $2)"; fi; }
has()  { if grep -q -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
hasnt(){ if grep -q -- "$2" <<<"$1"; then bad "$3 (found: $2)"; else ok "$3"; fi; }
sql()  { sudo -n -u postgres psql -d "$DX_DEV_DB" -Atc "$1"; }
as()   { sql "select set_config('app.member_id', '$1', false); select $2" | tail -1; }
cleanup() { local rc=$?; for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -rf "$TMP"; exit $rc; }
trap cleanup EXIT INT TERM
for port in $PORT $P_KERNEL $P_FAKE; do (exec 3<>/dev/tcp/127.0.0.1/$port) 2>/dev/null && { echo "ABORT: port $port is taken"; exit 2; }; done

bash "$ROOT/tests/setup_dev.sh" >/dev/null || { echo "scratch database failed"; exit 1; }
set -a; . "$DX_DEV_ENV"; set +a
export APP_URL="http://127.0.0.1:$PORT" OS_INTERNAL_URL="http://127.0.0.1:$P_KERNEL" MALUDB_API_URL="http://127.0.0.1:$P_FAKE" MALUMAIL_API_URL="http://127.0.0.1:$P_FAKE"
export FAKE_KERNEL_STATE="$TMP/kernel.json" FAKE_MALUDB_LOG="$TMP/maludb.log" FAKE_MALUMAIL_LOG="$TMP/developer.log"
cd "$ROOT"
APP="http://127.0.0.1:$PORT"

echo "== the schema (db/proof/phase0_proof.sql)"
if [ -n "${DX_MIGRATIONS_UPTO:-}${DX_DEV_UPTO:-}" ]; then
  echo "skip db/proof/phase0_proof.sql — the migrations stop at ${DX_MIGRATIONS_UPTO:-$DX_DEV_UPTO} (the kit alone)"
elif [ -f "$ROOT/db/proof/phase0_proof.sql" ]; then
  out=$(sudo -n -u postgres psql -v ON_ERROR_STOP=1 -d "$DX_DEV_DB" -f "$ROOT/db/proof/phase0_proof.sql" 2>&1)
  echo "$out" | grep -E '^ ?FAIL' || true
  summary=$(echo "$out" | grep -E '[0-9]+ ok, [0-9]+ failed' | head -1 | sed 's/^ *//')
  failed=$(echo "$summary" | sed -E 's/.* ([0-9]+) failed.*/\1/')
  check "$failed" "0" "schema proof: $summary"
  if [ -f "$ROOT/db/proof/phase1_proof.sql" ]; then
    out=$(sudo -n -u postgres psql -v ON_ERROR_STOP=1 -d "$DX_DEV_DB" -f "$ROOT/db/proof/phase1_proof.sql" 2>&1)
    echo "$out" | grep -E '^ ?FAIL' || true
    summary=$(echo "$out" | grep -E '[0-9]+ ok, [0-9]+ failed' | head -1 | sed 's/^ *//')
    failed=$(echo "$summary" | sed -E 's/.* ([0-9]+) failed.*/\1/')
    check "$failed" "0" "Phase 1 reads proof: $summary"
  fi
else
  echo "skip db/proof/phase0_proof.sql is not written yet (the schema builder's) — the kit's checks below run on whatever db/*.sql applies"
fi

echo "== the contract tables (db/001–005)"
check "$(sql "select string_agg(role_key, ',' order by sort_order) from mcp_app_roles")" "viewer,engineer,dba,admin" "the four roles, in order (os.app-roles/1; design §3, D9)"
check "$(sql "select string_agg(role_key, ',') from dx_roles where is_admin")" "admin" "exactly one admin role"
check "$(sql "select string_agg(role_key || '=' || capability, ',' order by sort_order) from dx_roles")" "viewer=read,engineer=write,dba=write,admin=admin" "each role's capability — and NO role keyed user, so the installer's standing grant admits nobody (D9)"
check "$(sql "select string_agg(role_key || ':' || cardinality(rights), ',' order by sort_order) from mcp_app_roles")" "viewer:5,engineer:12,dba:21,admin:28" "Viewer 5 rights, Engineer 12, DBA 21, Developer admin all 28"
check "$(sql "select string_agg(right_key, ',' order by right_key) from dx_role_rights where role_key = 'viewer'")" "activity.read,catalog.read,health.read,memory.read,plans.explain" "a Viewer reads structure, plans, activity, health and the memory databases' state — no rows"
check "$(sql "select string_agg(right_key, ',' order by right_key) from dx_rights where held_by = 'super_admins'")" "access.manage,audit.read,freeze,memory.reveal,registry.manage,settings.manage,window.approve" "administration is a super-admin's: access levels, the audit, the freeze, reveals, the registry, settings, approving windows (design §3)"
check "$(sql "select string_agg(right_key, ',' order by right_key) from dx_rights where held_by = 'people'")" "classifications.confirm,data.read,data.unmask,data.write,exports.make,maintenance.run,memory.content,queries.verify,sessions.cancel,sessions.terminate,window.request,workbench.apply,workbench.use" "rows, workbenches, exports, windows, writes, session control, maintenance, classifications and memory content are people's — never an agent's"
check "$(sudo -n -u postgres psql -d "$DX_DEV_DB" -qAt -c "update dx_rights set held_by = 'agents' where right_key = 'catalog.read'" 2>&1 | grep -c 'violates check constraint')" "1" "…and held_by admits nothing else"
check "$(sudo -n -u postgres psql -d "$DX_DEV_DB" -v ON_ERROR_STOP=1 -qAt -c "begin; insert into activity_log (source, action, after) values ('system', 'window.end', '{\"count\":3}'); select source from activity_log; rollback;" 2>&1 | head -1)" "system" "activity_log admits source system (the worker's own passes)"
check "$(sudo -n -u postgres psql -d "$DX_DEV_DB" -v ON_ERROR_STOP=1 -qAt -c "insert into activity_log (source, action) values ('portal2', 'x.y')" 2>&1 | grep -c 'violates check constraint')" "1" "…and refuses a source outside the list"
check "$(sql "select string_agg(column_name || ':' || data_type, ',' order by ordinal_position) from information_schema.columns where table_name = 'activity_log' and column_name in ('token_id','target_database_id')")" "token_id:bigint,target_database_id:bigint" "the audit keys appended to activity_log (token_id; target_database_id, design §6.10 — a database's trail one index)"
check "$(sql "select screen_timeout_seconds || ':' || workbench_timeout_seconds || ':' || show_rows || ':' || show_bytes_mb || ':' || cell_chars || ':' || door_pool_max || ':' || runs_per_person || ':' || grid_page_rows from dx_settings")" "30:300:1000:8:2000:8:2:50" "the door's limits seeded as D8 says (30 s a screen, 300 s a workbench, 1,000 rows and 8 MB shown, cells cut at 2,000, a pool of 8, 2 runs a person, 50 rows a grid page)"
check "$(sql "select window_default_minutes || '/' || window_max_minutes || ':' || step_up_minutes || ':' || idle_timeout_minutes || ':' || change_set_confirm_rows || '/' || change_set_max_rows || ':' || backup_max_age_hours || ':' || undo_days from dx_settings")" "60/240:10:30:1000/10000:24:30" "windows 60 min (at most 4 h) after a sign-on within 10 min; idle 30 min; change sets confirm to 1,000, refused over 10,000; a backup under 24 h; undo 30 days (D5)"
check "$(sql "select workbench_quota_gb || ':' || workbench_expiry_days || ':' || workbenches_per_person || ':' || sql_text_days || ':' || audit_keep_days || ':' || snapshot_ddl_days || ':' || export_max_rows || ':' || export_keep_hours || ':' || advisor_note_at || ':' || personal_tokens_enabled || ':' || frozen from dx_settings")" "2:14:5:90:730:90:1000000:24:07:20:00:false:false" "workbenches 2 GB / 14 days / 5 a person; SQL text 90 days, the audit 2 years; exports; the Advisor's hour; personal tokens off (D16); not frozen"
check "$(sudo -n -u postgres psql -d "$DX_DEV_DB" -qAt -c "update dx_settings set frozen = true" 2>&1 | grep -c 'violates check constraint')" "1" "a freeze names its time and reason (no silent freeze)"
check "$(sudo -n -u postgres psql -d "$DX_DEV_DB" -qAt -c "update dx_settings set window_default_minutes = 300" 2>&1 | grep -c 'violates check constraint')" "1" "a window's default never exceeds its maximum"
check "$(sudo -n -u postgres psql -d "$DX_DEV_DB" -qAt -c "update dx_settings set change_set_confirm_rows = 20000" 2>&1 | grep -c 'violates check constraint')" "1" "the confirm cap never exceeds the refusal cap"
check "$(sql "select count(*) from information_schema.role_table_grants where grantee in ('developer_records_ro','developer_activity_ro') and table_name in ('activity_log','mcp_access_tokens','members','key_usage','dx_settings')")" "0" "the read roles hold no grant on the contract tables (the mcp_* views are their window)"

echo "== the mirror (the fixture through directory_sync --from-file)"
php bin/directory_sync.php --from-file bin/dev_directory.json >/dev/null 2>&1; check "$?" "0" "the directory fixture applies"
check "$(sql "select count(*) || ' of ' || count(*) filter (where capability is not null) from members")" "11 of 10" "eleven members mirrored, ten admitted (the Watcher holds no grant)"
check "$(sql "select roles::text from members where id = 27")" "{admin,dba}" "roles map from the feed's access[]: Marco holds Developer admin and DBA"
check "$(sql "select is_agent::int || ',' || roles::text || ',' || display_name from members where id = 42")" "1,{engineer},SMOKE Advisor" "the DBA Advisor is an agent (is_agent generated) holding Engineer"
check "$(sql "select is_external::int || ',' || capability || ',' || roles::text from members where id = 29")" "1,read,{viewer}" "Ann is external and holds Viewer"
check "$(sql "select dx_member_roles(28)::text || ' ' || dx_member_roles(31)::text || ' ' || dx_member_roles(1)::text || ' ' || dx_member_roles(41)::text || ' ' || dx_member_roles(43)::text")" "{} {} {admin} {} {admin}" "dx_member_roles: a grant without roles is NO role (write or read alike — fail closed, D9); the super-admin admin; an unadmitted agent nothing; Ada holds what she was given"

echo "== roles, rights and who may hold them (dx_has_right, dx_member_has_right, dx_is_developer_admin, dx_right_refusal)"
check "$(as 1 "dx_is_developer_admin() and dx_has_right('access.manage') and dx_has_right('registry.manage') and dx_has_right('freeze') and dx_has_right('memory.reveal') and dx_has_right('data.write') and dx_has_right('catalog.read') and dx_right_refusal('freeze') is null")" "t" "the super-admin runs Developer: every right (D9)"
check "$(as 27 "not dx_is_developer_admin() and not dx_has_right('access.manage') and not dx_has_right('freeze') and not dx_has_right('window.approve') and dx_has_right('data.write') and dx_has_right('sessions.cancel') and not app_is_super_admin()")" "t" "Marco holds the Developer admin role but is no super-admin: every super-admin right refused, a DBA's kept (D9)"
check "$(as 27 "dx_right_refusal('access.manage')")" "Developer's administration is for the OS's super-admins. You hold the Developer admin role, but you are not a super-admin." "…and is told why, never a bare 403"
check "$(as 26 "dx_has_right('data.read') and dx_has_right('workbench.apply') and dx_has_right('migrations.draft') and not dx_has_right('data.write') and not dx_has_right('data.unmask') and dx_is_member_here()")" "t" "an Engineer reads rows, changes their workbench and drafts migrations; never applies row changes or unmasks"
check "$(as 26 "dx_right_refusal('freeze')")" "Only a Developer admin — a super-admin of the OS — can do that." "…told so in a sentence"
check "$(as 26 "dx_right_refusal('data.write')")" "Your Developer role does not let you do that." "…and a DBA's right is the role's to give"
check "$(as 28 "app_is_active_member() and not dx_is_member_here() and not dx_has_right('catalog.read')")" "t" "Bea, admitted with write but sent no roles, holds nothing (fail closed, D9)"
check "$(as 29 "dx_has_right('catalog.read') and not dx_has_right('data.read') and dx_is_member_here()")" "t" "Ann, an external Viewer, reads structure and no rows"
check "$(as 31 "dx_right_refusal('catalog.read')")" "Your access to Developer gives no role yet. A super-admin gives you Viewer, Engineer or DBA." "Lee (read, no roles) is told why"
check "$(as 40 "dx_has_right('catalog.read') and dx_has_right('changes.prepare') and dx_has_right('migrations.draft') and not dx_has_right('data.read') and not dx_has_right('workbench.apply') and not dx_has_right('exports.make') and app_member_kind() = 'agent' and dx_is_member_here()")" "t" "the Database Expert (an agent granted Engineer) explains, proposes and drafts — never reads rows, changes a workbench or exports (design §5)"
check "$(as 40 "dx_right_refusal('data.read')")" "That is a person's to do: an agent reads no rows and changes no database." "…told so"
check "$(as 43 "not dx_has_right('access.manage') and not dx_has_right('freeze') and not dx_has_right('data.write') and not dx_is_developer_admin() and dx_has_right('catalog.read')")" "t" "Ada, an agent GIVEN the Developer admin role, administers nothing and writes nothing"
check "$(as 43 "dx_right_refusal('freeze')")" "Administering Developer is for people: an agent never does it." "…told so"
check "$(as 41 "not app_is_active_member() and not dx_has_right('catalog.read') and not dx_is_member_here()")" "t" "an agent not yet admitted holds nothing (fail closed)"
check "$(as '' "dx_has_right('catalog.read') or dx_is_member_here() or dx_is_developer_admin()")" "f" "nobody (no app.member_id) holds nothing"
check "$(sql "select dx_member_has_right(26, 'data.read')::text || ',' || dx_member_has_right(27, 'access.manage')::text || ',' || dx_member_has_right(1, 'access.manage')::text || ',' || dx_member_has_right(42, 'data.read')::text || ',' || dx_member_has_right(30, 'data.write')::text")" "true,false,true,false,true" "dx_member_has_right answers for a given member (Dana, a person, may write in a window; the Advisor, an agent, reads no rows)"

echo "== sign-on"
php -r '$f = json_decode(file_get_contents("bin/dev_directory.json"), true); file_put_contents(getenv("FAKE_KERNEL_STATE"), json_encode(["feed" => $f["feed"]]));'
php -S 127.0.0.1:$P_KERNEL tests/fake_kernel.php >"$TMP/kernel.log" 2>&1 & PIDS+=($!)
php -S 127.0.0.1:$P_FAKE tests/fake_maludb.php >"$TMP/fake.log" 2>&1 & PIDS+=($!)
PHP_CLI_SERVER_WORKERS=4 php -S 127.0.0.1:$PORT -t html tests/dev_router.php >"$TMP/app.log" 2>&1 & PIDS+=($!)
sleep 1.2
check "$(curl -s -o /dev/null -w '%{http_code}' $APP/api/v1/health)" "200" "health answers 200"
check "$(curl -s $APP/api/v1/health | php -r '$h = json_decode(stream_get_contents(STDIN), true); echo ($h["application"] ?? "?") . ":" . ($h["storage"] ?? "?") . ":" . ($h["door"] ?? "?");')" "developer:ok:down" "…naming the application developer, its export store writable, the door down (no door runs in the kit's proof) — reported, never a failure of this health"
url27=$(php bin/dev_handoff.php 27)
check "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -c "$TMP/jar27" "$url27")" "302 $APP/" "a signed hand-off token opens a session (302 to /)"
home27=$(curl -s -b "$TMP/jar27" "$APP/")
has "$home27" 'id="home-member">SMOKE Marco<' "the home placeholder names the signed-in member"
has "$home27" 'id="home-roles">DBA, Developer admin<' "…and the roles the kernel sent, by their names"
check "$(curl -s -o /dev/null -w '%{http_code}' "$url27")" "403" "the same token a second time is refused (replay)"
check "$(curl -s -o /dev/null -w '%{http_code}' "$(HANDOFF_TTL=-120 php bin/dev_handoff.php 26)")" "403" "an expired token is refused"
bad_url=$(APP_KEY=other php bin/dev_handoff.php 26 | sed "s#$APP##")
check "$(curl -s -o /dev/null -w '%{http_code}' "$APP$bad_url")" "403" "a token minted for another application is refused (audience)"
check "$(curl -s -o /dev/null -w '%{http_code}' "$(php bin/dev_handoff.php 999)")" "403" "an unknown member is refused"
check "$(sql "select count(*) from members where id = 999")" "0" "…and is never created in the mirror"
check "$(curl -s -o /dev/null -w '%{http_code}' "$(HANDOFF_NO_GRANT=1 php bin/dev_handoff.php 30)")" "403" "a hand-off whose claims carry no grant is refused (capability)"
pyld=$(echo "$url27" | sed -E 's/.*token=([^.]+\.[^.]+\.[^.]+\.[^.]+)\.[a-f0-9]+.*/\1/')
check "$(curl -s -o /dev/null -w '%{http_code}' "$APP/sso?token=$pyld.$(printf '0%.0s' $(seq 1 64))&claims=x.y")" "403" "a tampered signature is refused"
check "$(sql "select string_agg(after->>'reason', ',' order by id) from activity_log where action = 'member.sign_on.refused'")" "replay,token,token,capability,capability,token" "every refusal is logged with its reason (an unknown member's claims carry no grant: capability); none is told to the visitor"
check "$(curl -s -o /dev/null -w '%{http_code}' "$APP/")" "302" "an anonymous visit to / is sent to the launcher (never a login form)"
check "$(sql "select count(*) from member_sessions where member_id = 27 and ended_at is null")" "1" "the session is listed for the kernel's sign-out notice"
check "$(sql "select (after->'roles')::text from activity_log where action = 'member.sign_on' and entity_id = 27")" '["admin", "dba"]' "member.sign_on logged with the roles"
code29=$(curl -s -o /dev/null -w '%{http_code}' -c "$TMP/jar29" "$(php bin/dev_handoff.php 29)"); check "$code29" "302" "Ann (external, Viewer) signs on — the kernel's grant stands"
check "$(curl -s -o /dev/null -w '%{http_code}' -b "$TMP/jar29" "$APP/")" "200" "…and, holding Viewer, reaches the home"
code28=$(curl -s -o /dev/null -w '%{http_code}' -c "$TMP/jar28" "$(php bin/dev_handoff.php 28)"); check "$code28" "302" "Bea (write, sent no roles) signs on — the kernel's grant stands"
home28=$(curl -s -w '\n%{http_code}' -b "$TMP/jar28" "$APP/")
check "$(echo "$home28" | tail -1)" "403" "…but with no Developer role the home refuses her (fail closed)"
has "$home28" 'Your access to Developer gives no role yet' "…saying why (dx_right_refusal), never a bare 403"
check "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -c "$TMP/jarn" "$(php bin/dev_handoff.php 26)&next=/db/subello_gl/sql")" "302 $APP/db/subello_gl/sql" "the hand-off lands on the launcher's next path when it is local"
check "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -c "$TMP/jarx" "$(php bin/dev_handoff.php 26)&next=https://evil.example/")" "302 $APP/" "…and on / when it is not"

echo "== CSRF"
tok=$(curl -s -b "$TMP/jar27" "$APP/" | sed -n 's/.*name="csrf_token" value="\([a-f0-9]*\)".*/\1/p' | head -1)
check "$(curl -s -o /dev/null -w '%{http_code}' -b "$TMP/jar27" -X POST "$APP/logout.php")" "403" "a POST without a CSRF token is refused"
check "$(curl -s -o /dev/null -w '%{http_code}' -b "$TMP/jar27" -X POST -d 'csrf_token=deadbeef' "$APP/logout.php")" "403" "a POST with a bad CSRF token is refused"
check "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -X POST -d 'csrf_token=x' "$APP/")" "302 https://app.example.invalid/launcher?app=developer" "an anonymous POST to a screen goes to the launcher (there is no login form here)"
check "$(curl -s -o /dev/null -w '%{http_code}' -H 'Accept: application/json' -X POST "$APP/")" "401" "…and answers a JSON caller 401, never a bare 403"

echo "== the activity funnel"
out=$(php tests/phase0/probe.php log 2>/dev/null)
check "$(sql "select target_database_id || ':' || entity_id || ':' || entity_type || ':' || source from activity_log where action = 'probe.event'")" "1:77:change_set:cron" "log_activity writes the target database's id beside the entity (source cron under the CLI)"
check "$(sql "select target_database_id from activity_log where action = 'probe.target'")" "2" "…and takes the target from the entity when the entity IS a target database"
check "$(sql "select count(*) || ':' || count(target_database_id) || ':' || count(entity_id) from activity_log where action = 'probe.bad_target'")" "1:0:0" "…and drops a target id or an entity id that is not a positive number without losing the row"
check "$(echo "$out" | tr '\n' ' ')" "logged survived " "log_activity never throws on a bad actor, an unencodable payload or a bad key"

echo "== keys: a person's own, rate-limited"
RAW="mcp_$(openssl rand -hex 24)"; HASH=$(printf '%s' "$RAW" | openssl dgst -sha256 | sed 's/.* //')
sql "insert into mcp_access_tokens (member_id, label, token_hash, scope) values (26, 'SMOKE key', '$HASH', 'api')" >/dev/null
TOK=$(sql "select id from mcp_access_tokens where token_hash = '$HASH'")
check "$(sql "select rate_per_minute || '/' || rate_per_day from mcp_access_tokens where id = $TOK")" "60/5000" "a key's limits default from the settings (the trigger: 60/min, 5,000/day)"
check "$(sql "select member_id || ':' || label || ':' || rate_per_minute from dx_resolve_key('$HASH')")" "26:SMOKE key:60" "a key resolves to its person, label and limits (dx_resolve_key)"
check "$(sudo -n -u postgres psql -d "$DX_DEV_DB" -qAt -c "insert into mcp_access_tokens (member_id, label, token_hash, scope, rate_per_minute) values (26, 'SMOKE bad', 'x$(openssl rand -hex 8)', 'mcp', 5)" 2>&1 | grep -c 'violates check constraint')" "1" "a person's mcp token can never carry a key's limits"
r1=$(php tests/phase0/probe.php apikey "$RAW" 2>&1 | tr '\n' ' ')
has "$r1" "authenticated:26:key=yes:label=SMOKE key" "the token API authenticates a key as its person"
check "$(sql "select token_id || ':' || source || ':' || (after->>'label') from activity_log where action = 'probe.api'")" "$TOK:api:SMOKE key" "…every row under a key carries token_id, source api and the key's label, never the key"
MCP="mcp_$(openssl rand -hex 24)"; MH=$(printf '%s' "$MCP" | openssl dgst -sha256 | sed 's/.* //')
sql "insert into mcp_access_tokens (member_id, label, token_hash, scope) values (26, 'SMOKE mcp', '$MH', 'mcp')" >/dev/null
has "$(php tests/phase0/probe.php apikey "$MCP" 2>&1 | tr '\n' ' ')" '"code":"unauthorized"' "a person's mcp token is not a door to the token API"
# 61 calls in one statement: the key's API call above counts when it fell in this same minute (then 59 more pass and 2 are refused), not when the
# minute turned since (then 60 pass and 1 is refused) — either way the 61st call of a minute is refused. (A run crossing the minute failed the old form.)
rl=$(sql "select string_agg(ok::text, ',' order by n) from (select n, (dx_rate_ok($TOK)).ok from generate_series(1, 61) n) s" | tr ',' '\n' | sort | uniq -c | tr -s ' ' | tr '\n' ';')
case "$rl" in " 2 false; 59 true;"|" 1 false; 60 true;") ok "the rate rule counts 60 calls a minute and refuses the 61st (dx_rate_ok) — $rl" ;; *) bad "the rate rule (got: $rl, wanted 60 a minute with the earlier call counted or not)" ;; esac
NEW=$(sql "select dx_key_rotate($TOK, '$(openssl rand -hex 32)')"); check "$(sql "select rotated_from = $TOK and rate_per_minute = 60 from mcp_access_tokens where id = $NEW") $(sql "select expires_at <= now() + interval '25 hours' from mcp_access_tokens where id = $TOK")" "t t" "rotation mints a key of the same person and limits and gives the old one 24 hours"

echo "== the kernel's word shuts the doors"
notice="27.$(date +%s).developer"; sig=$(printf 'sso-logout:%s' "$notice" | openssl dgst -sha256 -hmac "$ACTION_TOKEN_KEY" | sed 's/.* //')
check "$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-urlencode "notice=$notice.$sig" "$APP/sso/logout")" "204" "the kernel's sign-out notice answers 204"
check "$(sql "select ended_by from member_sessions where member_id = 27 order by created_at desc limit 1")" "kernel" "…and ends the member's session"
check "$(curl -s -o /dev/null -w '%{http_code}' -b "$TMP/jar27" "$APP/")" "302" "…so the next request goes to the launcher"
check "$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-urlencode "notice=27.1.developer.deadbeef" "$APP/sso/logout")" "204" "a bad notice also answers 204 and changes nothing"
check "$(curl -s -o /dev/null -w '%{http_code}' -b "$TMP/jar29" "$APP/")" "200" "Ann's session stands while her grant does"
php -r '$s = json_decode(file_get_contents(getenv("FAKE_KERNEL_STATE")), true); $s["incremental"] = ["schema" => "os.directory-changes/1", "since" => "2026-01-01T00:00:00.000000Z", "next" => "2026-01-02T00:00:00.000000Z", "full" => false, "members" => [], "departments" => [], "memberships" => [], "deleted_departments" => [], "scopes" => [], "access" => [["member_id" => 29, "capability" => null, "roles" => [], "scopes" => []]]]; file_put_contents(getenv("FAKE_KERNEL_STATE"), json_encode($s));'
php bin/directory_sync.php >/dev/null 2>&1; check "$?" "0" "the change feed applies through the kernel's internal API (the fake kernel)"
check "$(curl -s -o /dev/null -w '%{http_code}' -b "$TMP/jar29" "$APP/")" "302" "a grant the kernel revoked shuts the door within one sync"
check "$(sql "select ended_by from member_sessions where member_id = 29 order by created_at desc limit 1") $(sql "select capability is null from members where id = 29")" "directory t" "…the session ended by the directory and the mirror holds no grant"
check "$(curl -s -o /dev/null -w '%{http_code}' "$(HANDOFF_NO_GRANT=1 php bin/dev_handoff.php 29)")" "403" "…and a hand-off whose claims now carry no grant is refused (the kernel's claims are the authority)"
tok26=$(curl -s -c "$TMP/jar26" -b "$TMP/jar26" -o /dev/null "$(php bin/dev_handoff.php 26)"; curl -s -b "$TMP/jar26" "$APP/" | sed -n 's/.*name="csrf_token" value="\([a-f0-9]*\)".*/\1/p' | head -1)
check "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -b "$TMP/jar26" -X POST -d "csrf_token=$tok26" "$APP/logout.php")" "302 https://app.example.invalid/launcher" "Developer's own sign-out (POST + CSRF) goes back to the launcher"
check "$(curl -s -o /dev/null -w '%{http_code}' -b "$TMP/jar26" "$APP/")" "302" "…and the session is over"

echo "== the worker, the ingest bridge, mail"
php bin/worker.php >"$TMP/worker.out" 2>&1; check "$?:$(sql "select count(*) from activity_log where action = 'worker.pass' and source = 'cron'")" "0:1" "the worker runs a pass of stubs, logs worker.pass (source cron) and exits 0"
check "$(php -r '$r = json_decode(file_get_contents($argv[1]), true); echo count($r["ran"] ?? []) . ":" . (isset($r["ran"]["key_usage_prune"]["pruned"]) ? "pruned" : "?") . ":" . ($r["ran"]["discovery"]["stub"] ?? "?") . ":" . ($r["ran"]["snapshots"]["stub"] ?? "?");' "$TMP/worker.out")" "13:pruned:slice 1:slice 8" "…thirteen passes: the key-usage prune real, the rest stubs naming their slice"
if [ -x "$PY" ] && "$PY" -c 'import asyncpg, httpx' 2>/dev/null; then
  "$PY" mcp/activity_ingest.py >"$TMP/ingest.out" 2>&1; check "$?" "0" "the ingest bridge ships the log to MaluDB (fake) and advances its checkpoint"
  check "$(php -r '$first = json_decode(file(getenv("FAKE_MALUDB_LOG"))[0], true); echo array_key_first($first["payload"]) . "=" . $first["payload"]["application"] . ":" . $first["kind"];')" "application=developer:activity" "the payload names the application first (memory.md)"
  check "$(php -r 'foreach (file(getenv("FAKE_MALUDB_LOG")) as $l) { $b = json_decode($l, true); if (($b["payload"]["action"] ?? "") === "probe.event") echo $b["payload"]["target_database_id"] ?? "-"; }')" "1" "…and carries the target database's id"
  check "$(sql "select last_id = (select max(id) from activity_log) from activity_ingest_state")" "t" "…the checkpoint stands at the last row"
else
  bad "the ingest bridge needs a python with asyncpg and httpx (DX_PY)"; bad "the payload names the application first"; bad "payload carries the audit keys"; bad "the checkpoint"
fi
check "$(php tests/phase0/probe.php mail 2>&1)" "sent:200" "notification mail goes through MaluMail's (fake) API when a key is set"
check "$(MALUMAIL_API_KEY= php tests/phase0/probe.php mail 2>&1 | cut -d: -f1)" "mail-threw" "with no key the send raises a catchable error (mail is optional)"

echo "== PHP holds no target database's credential (design §6.1)"
check "$(grep -rlE 'DX_DOOR_PASSFILE|DX_GRANTS_PASSFILE|developer_(meta|read|read_masked|write|ops|rolemaker|memory|grantor)\b' app html bin | wc -l)" "0" "no PHP file names the door's or the grants service's passfile or logs in as one of the tool's cluster roles"
check "$(grep -cE '^(DX_DOOR_PASSFILE|DX_GRANTS_PASSFILE|PGPASSFILE)=' "$DX_DEV_ENV")" "0" "the proofs' PHP environment holds no passfile"
check "$(grep -rlE 'new PDO|pg_connect' app html bin | grep -v 'app/db.php' | wc -l)" "0" "PHP opens one database connection, in app/db.php (its own database) — never to a target"

echo "== $pass ok, $fail failed"
[ "$fail" -eq 0 ]
