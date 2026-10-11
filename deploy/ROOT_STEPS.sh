#!/usr/bin/env bash
# Developer — what root (the owner) does to install it beside the kernel, in order. Written in Phase 0 (2026-10-11); later phases ADD
# steps and mark them. NOTHING HERE HAS BEEN RUN — the owner runs it. The proofs use scratch databases and roles named dx_* (the owner's
# leave, design §15 (d)), php -S and fixtures, and never touch an installed application, Apache, systemd, pg_hba or the MaluDB API.
#
#   bash deploy/ROOT_STEPS.sh                         prints this plan (the default; nothing changes)
#   sudo bash deploy/ROOT_STEPS.sh apply              steps 0–10, BEFORE the installer's apply (each idempotent)
#   sudo bash deploy/ROOT_STEPS.sh after [--with-io-timing]
#                                                     steps 11–14, AFTER the installer's apply — and again after EVERY later apply
#                                                     (the installer re-groups config/.env to www-data whenever it writes a key)
#
# Design §6.1 (the door, the grants service and the tool's roles), §12 (what the host owes), §14 (ports, names, files), D6, D14, K54.
set -euo pipefail
APP=/srv/apps/developer
KERNEL=/var/www
TENANT=${TENANT:-subello}
APPDB=${TENANT}_developer
KERNEL_DB=${KERNEL_DB:-certstudy}
ETC=/etc/developer
MODE=plan; IOT=0
for a in "$@"; do case "$a" in apply) MODE=apply;; after) MODE=after;; --with-io-timing) IOT=1;; *) echo "unknown argument: $a" >&2; exit 2;; esac; done
if [ "$MODE" != plan ] && [ "$(id -u)" != 0 ]; then echo "$MODE needs root: sudo bash deploy/ROOT_STEPS.sh $MODE" >&2; exit 2; fi
DO_BEFORE=0; DO_AFTER=0
case "$MODE" in plan) DO_BEFORE=1; DO_AFTER=1;; apply) DO_BEFORE=1;; after) DO_AFTER=1;; esac
REAL=0; [ "$MODE" != plan ] && REAL=1

ENVF=$APP/config/.env
envval() { [ -f "$ENVF" ] && sed -n "s/^$1=//p" "$ENVF" | tail -1 | sed -E "s/^([\"'])(.*)\\1\$/\\2/" || true; }
run() { echo "+ $*"; if [ "$REAL" = 1 ]; then "$@"; fi; }
envset() {   # one key into config/.env in place (the inode kept); never prints a secret's value
    local k=$1 v=$2 shown=${3:-$2} tmp
    [ "$(envval "$k")" = "$v" ] && { echo "   $k already set"; return; }
    echo "+ $k=$shown → config/.env"
    [ "$REAL" = 1 ] || return 0
    tmp=$(mktemp); grep -v "^$k=" "$ENVF" > "$tmp" || true; printf '%s=%s\n' "$k" "$v" >> "$tmp"; cat "$tmp" > "$ENVF"; rm -f "$tmp"
}
pg() {       # SQL as postgres on stdin, against database $1 (printed in plan mode)
    local db=$1 sql; sql=$(cat)
    if [ "$REAL" = 1 ]; then printf '%s\n' "$sql" | runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 -d "$db"
    else printf '%s\n' "$sql" | sed "s/^/+ ($db) /"; fi
}
pgval() { runuser -u postgres -- psql -X -At -v ON_ERROR_STOP=1 -d "${2:-postgres}" -c "$1"; }

if [ "$DO_BEFORE" = 1 ]; then
# ------------------------------------------------------------------------------------------------------------------------------------
# 0. PIN THE PORTS AND THE DOOR'S KEYS in config/.env before the installer's first apply (Help Desk's lesson of 2026-10-02: the installer
#    otherwise takes the first free port from 8100). DX_DOOR_SOCKET and DX_DOOR_KEY are required by maludb-os.json and the installer knows
#    no value for them; DX_DOOR_KEY (the HMAC every request to the door carries, design §6.1) is made here once — the same key goes into
#    the door's own environment file in step 6. DX_BRIDGE_KEY (the HMAC of the records server's loopback bridge to PHP's DDL generators,
#    docs/build-specs/ddl-generators.md) is made here once too.
echo "== 0. Pin the ports and the door's keys in $ENVF"
if [ ! -f "$ENVF" ]; then
  KEY=$( [ "$REAL" = 1 ] && head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' || echo '<64 hex>')
  run install -d -m 750 "$APP/config"
  echo "+ write APP_INTERNAL_PORT=8201, MCP_RECORDS_PORT=8858, MCP_ACTIVITY_PORT=8859, DX_DOOR_SOCKET=/run/developer/door.sock, DX_DOOR_KEY=(new) → $ENVF"
  if [ "$REAL" = 1 ]; then
    umask 027
    BKEY=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
    printf 'APP_INTERNAL_PORT=8201\nMCP_RECORDS_PORT=8858\nMCP_ACTIVITY_PORT=8859\nDX_DOOR_SOCKET=/run/developer/door.sock\nDX_DOOR_KEY=%s\nDX_BRIDGE_KEY=%s\n' "$KEY" "$BKEY" > "$ENVF"
    umask 022
  fi
else
  echo "   (config/.env exists — the ports are kept as they are)"
  [ -n "$(envval APP_INTERNAL_PORT)" ] || envset APP_INTERNAL_PORT 8201
  [ -n "$(envval MCP_RECORDS_PORT)" ] || envset MCP_RECORDS_PORT 8858
  [ -n "$(envval MCP_ACTIVITY_PORT)" ] || envset MCP_ACTIVITY_PORT 8859
  [ -n "$(envval DX_DOOR_SOCKET)" ] || envset DX_DOOR_SOCKET /run/developer/door.sock
  if [ -z "$(envval DX_DOOR_KEY)" ]; then
    KEY=$( [ "$REAL" = 1 ] && head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' || echo x)
    envset DX_DOOR_KEY "$KEY" '(new, 64 hex — never printed)'
  else echo "   DX_DOOR_KEY already set (kept)"; fi
  if [ -z "$(envval DX_BRIDGE_KEY)" ]; then
    BKEY=$( [ "$REAL" = 1 ] && head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' || echo x)
    envset DX_BRIDGE_KEY "$BKEY" '(new, 64 hex — never printed)'
  else echo "   DX_BRIDGE_KEY already set (kept)"; fi
fi
#    See that it worked:  php $KERNEL/bin/app_install.php plan $APP | grep -E '^(todo|done) +(ports|vhost|services)'   -> no {{...}} unfilled

# ------------------------------------------------------------------------------------------------------------------------------------
# 1. THE SYSTEM USERS (idempotent; none can log in). developer-web runs Developer's PHP (the FPM pool, the worker, the directory sync, the
#    activity ingest); developer-mcp runs the two MCP servers; both are in the group `developer`, which reads config/.env and talks to the
#    door's socket. developer-door (the door) and developer-grants (the grants service) each have only their own group — neither reads
#    config/.env, and neither is in `developer` or www-data.
echo "== 1. Group developer; users developer-web, developer-mcp (in developer), developer-door, developer-grants (nologin)"
if ! getent group developer >/dev/null; then run groupadd --system developer; else echo "   group developer exists"; fi
for u in developer-web developer-mcp; do
  if ! id -u "$u" >/dev/null 2>&1; then
    run useradd --system --user-group --groups developer --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin "$u"
  else echo "   user $u exists"; run usermod -a -G developer "$u"; fi
done
for u in developer-door developer-grants; do
  if ! id -u "$u" >/dev/null 2>&1; then
    run useradd --system --user-group --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin "$u"
  else echo "   user $u exists"; fi
done

# ------------------------------------------------------------------------------------------------------------------------------------
# 2. PHP-FPM, GRAPHVIZ, APACHE'S MODULES AND THE POOL (idempotent; D6, D12, K54). php8.3-fpm runs Developer's PHP as developer-web; the
#    vhost hands this application's .php to /run/php/developer.sock (proxy_fcgi) while mod_php keeps serving every other application.
#    Graphviz draws the ER diagrams (the owner's (b)). Ubuntu's own `www` pool (www-data) also starts with php8.3-fpm and serves nothing.
echo "== 2. php8.3-fpm and graphviz; a2enmod proxy proxy_http proxy_fcgi setenvif rewrite headers; the pool developer"
for p in php8.3-fpm graphviz; do
  if dpkg -s "$p" >/dev/null 2>&1; then echo "   $p installed"; else run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$p"; fi
done
run a2enmod -q proxy proxy_http proxy_fcgi setenvif rewrite headers
run install -d -o developer-web -g developer -m 0700 /var/lib/php/sessions-developer
POOL=/etc/php/8.3/fpm/pool.d/developer.conf
echo "+ render deploy/php-fpm-developer.conf (APP_DIR=$APP) → $POOL; php-fpm8.3 -t; enable and reload php8.3-fpm"
if [ "$REAL" = 1 ]; then
  sed -e "s#{{APP_DIR}}#$APP#g" "$APP/deploy/php-fpm-developer.conf" > "$POOL.new"
  if cmp -s "$POOL.new" "$POOL" 2>/dev/null; then rm -f "$POOL.new"; echo "   pool unchanged"; else mv "$POOL.new" "$POOL"; fi
  php-fpm8.3 -t
  systemctl enable -q --now php8.3-fpm && systemctl reload php8.3-fpm
fi

# ------------------------------------------------------------------------------------------------------------------------------------
# 3. CONFIG/.ENV GROUPED TO `developer` (idempotent; design §6.1, K54). The installer writes config/.env group www-data, which every
#    application's PHP on this host shares; Developer's is root-or-installer:developer 0640 instead (developer-web and developer-mcp
#    read it). Step 11 repeats this after every apply. storage/ is developer-web's.
echo "== 3. config/ and config/.env → group developer (0750 / 0640); storage/ → developer-web"
if [ -d "$APP/config" ]; then run chgrp developer "$APP/config"; run chmod 0750 "$APP/config"; fi
if [ -f "$ENVF" ]; then run chgrp developer "$ENVF"; run chmod 0640 "$ENVF"; fi
if [ -d "$APP/storage" ]; then run chown -R developer-web:developer "$APP/storage"; run chmod 2770 "$APP/storage"; fi
# storage/exports and storage/imports are the door's (it writes an export's file and reads an upload — the-door.md §6.9–6.10): developer-door, setgid developer.
for d in exports imports; do run install -d -o developer-door -g developer -m 2770 "$APP/storage/$d"; done

# ------------------------------------------------------------------------------------------------------------------------------------
# 4. THE CLUSTER ROLES AND THEIR PASSFILES (idempotent; design §6.1's table). None is a superuser; none holds BYPASSRLS itself or the
#    file and program roles; CREATEROLE only for developer_rolemaker (PostgreSQL 16 confines it to the roles it creates). Passwords are
#    random, set as SCRAM verifiers (so no server log can ever hold one), and written ONLY to two passfiles:
#      $ETC/door.pgpass    developer-door 0600   — meta, read, read_masked, write, ops, rolemaker, memory
#      $ETC/grants.pgpass  developer-grants 0600 — grantor
#    A role whose passfile line exists is left alone; a missing line gets a fresh password.
echo "== 4. The cluster roles of design §6.1 and the passfiles $ETC/door.pgpass, $ETC/grants.pgpass"
run install -d -o root -g root -m 0755 "$ETC"
login_role() {   # role passfile owner
  local role=$1 pf=$2 owner=$3 pw ver
  if [ "$REAL" != 1 ]; then echo "+ (postgres) CREATE ROLE $role LOGIN if missing; a fresh password as a SCRAM verifier unless $pf holds one; append to $pf ($owner 0600)"; return; fi
  [ -f "$pf" ] || { install -m 0600 -o "$owner" -g "$owner" /dev/null "$pf"; }
  if [ -z "$(pgval "SELECT 1 FROM pg_roles WHERE rolname = '$role'")" ]; then
    printf 'CREATE ROLE %s LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;\n' "$role" | runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1
  fi
  if grep -q "^127\.0\.0\.1:5432:\*:$role:" "$pf"; then echo "   $role: password kept"; return; fi
  read -r pw ver < <(python3 -I - <<'PY'
import base64, hashlib, hmac, os, secrets
pw = secrets.token_hex(24); salt = os.urandom(16); it = 4096
salted = hashlib.pbkdf2_hmac('sha256', pw.encode(), salt, it)
ck = hmac.new(salted, b'Client Key', 'sha256').digest(); sk = hmac.new(salted, b'Server Key', 'sha256').digest()
b = lambda x: base64.b64encode(x).decode()
print(pw, 'SCRAM-SHA-256$%d:%s$%s:%s' % (it, b(salt), b(hashlib.sha256(ck).digest()), b(sk)))
PY
)
  printf "ALTER ROLE %s PASSWORD '%s';\n" "$role" "$ver" | runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1
  printf '127.0.0.1:5432:*:%s:%s\n::1:5432:*:%s:%s\n' "$role" "$pw" "$role" "$pw" >> "$pf"
  chown "$owner:$owner" "$pf"; chmod 0600 "$pf"
  echo "   $role: new password set (verifier) and written to $pf"
}
for r in developer_meta developer_read developer_read_masked developer_write developer_ops developer_rolemaker developer_memory; do
  login_role "$r" "$ETC/door.pgpass" developer-door
done
login_role developer_grantor "$ETC/grants.pgpass" developer-grants
AUDITOR=$( [ "$REAL" = 1 ] && pgval "SELECT 1 FROM pg_roles WHERE rolname = 'maludb_memory_auditor'" || echo 1)
pg postgres <<SQL
DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'developer_signaller') THEN CREATE ROLE developer_signaller NOLOGIN; END IF; END \$\$;
ALTER ROLE developer_rolemaker CREATEROLE CREATEDB;
GRANT pg_monitor TO developer_meta;
GRANT pg_signal_backend, pg_read_all_stats TO developer_signaller;
ALTER ROLE developer_meta        SET default_transaction_read_only = on;
ALTER ROLE developer_meta        SET statement_timeout = '15s';
ALTER ROLE developer_meta        SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE developer_read        SET default_transaction_read_only = on;
ALTER ROLE developer_read        SET statement_timeout = '60s';
ALTER ROLE developer_read        SET lock_timeout = '5s';
ALTER ROLE developer_read        SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE developer_read        SET transaction_timeout = '120s';
ALTER ROLE developer_read_masked SET default_transaction_read_only = on;
ALTER ROLE developer_read_masked SET statement_timeout = '60s';
ALTER ROLE developer_read_masked SET lock_timeout = '5s';
ALTER ROLE developer_read_masked SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE developer_read_masked SET transaction_timeout = '120s';
ALTER ROLE developer_write       SET statement_timeout = '30s';
ALTER ROLE developer_write       SET lock_timeout = '5s';
ALTER ROLE developer_write       SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE developer_write       SET transaction_timeout = '120s';
ALTER ROLE developer_ops         SET statement_timeout = 0;
ALTER ROLE developer_ops         SET lock_timeout = '10s';
ALTER ROLE developer_ops         SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE developer_rolemaker   SET statement_timeout = '60s';
ALTER ROLE developer_rolemaker   SET createrole_self_grant = 'set';
ALTER ROLE developer_memory      SET default_transaction_read_only = on;
ALTER ROLE developer_memory      SET statement_timeout = '15s';
SQL
if [ "$AUDITOR" = 1 ]; then
  # Design §6.1: the memory login reaches maludb_memory_auditor ONLY by SET ROLE inside the door's own fixed, statically tested queries
  # (that role holds BYPASSRLS once set and can read ciphertext — acknowledged; a narrower MaluDB role is asked upstream).
  echo "GRANT maludb_memory_auditor TO developer_memory WITH INHERIT FALSE, SET TRUE;" | pg postgres
else
  echo "   maludb_memory_auditor does not exist on this cluster — the memory section stays unavailable until MaluDB is installed"
fi

# ------------------------------------------------------------------------------------------------------------------------------------
# 5. PG_HBA (idempotent; design §6.1). deploy/pg_hba-developer.conf goes FIRST in pg_hba.conf (between its markers, replacing an older
#    copy): the tool's roles from loopback with SCRAM, refused from anywhere else and on the local socket. Reload; any error in the file is
#    shown from pg_hba_file_rules and the previous file is put back.
echo "== 5. pg_hba: the tool's roles from loopback only (deploy/pg_hba-developer.conf, first in the file); reload"
if [ "$REAL" = 1 ]; then
  HBA=$(pgval 'show hba_file')
  cp -p "$HBA" "$HBA.bak-developer"
  { cat "$APP/deploy/pg_hba-developer.conf"; sed '/^# BEGIN maludb-os-developer$/,/^# END maludb-os-developer$/d' "$HBA.bak-developer"; } > "$HBA.new"
  chown --reference="$HBA" "$HBA.new"; chmod --reference="$HBA" "$HBA.new"; mv "$HBA.new" "$HBA"
  ERR=$(pgval "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL")
  if [ "$ERR" != 0 ]; then
    pgval "SELECT line_number, error FROM pg_hba_file_rules WHERE error IS NOT NULL" >&2
    cp -p "$HBA.bak-developer" "$HBA"; echo "REFUSED: pg_hba.conf had errors — the previous file is back" >&2; exit 3
  fi
  pgval 'SELECT pg_reload_conf()' >/dev/null && echo "   pg_hba.conf updated and reloaded (backup $HBA.bak-developer)"
else
  echo "+ prepend deploy/pg_hba-developer.conf to \$(show hba_file) (older block removed); check pg_hba_file_rules; SELECT pg_reload_conf()"
fi

# ------------------------------------------------------------------------------------------------------------------------------------
# 6. THE SERVICES' ENVIRONMENT FILES (idempotent). The door and the grants service never read config/.env; each has its own file:
#      $ETC/door.env    root:developer-door 0640    $ETC/grants.env  root:developer-grants 0640
echo "== 6. $ETC/door.env and $ETC/grants.env"
DOOR_KEY=$(envval DX_DOOR_KEY)
echo "+ write $ETC/door.env (DX_DOOR_KEY from config/.env — never printed — DX_DOOR_SOCKET, PGPASSFILE, PGHOST, DX_APP_DB=$APPDB, DX_DOOR_POOL_MAX=12, DX_DOOR_STATE, DX_SQUAWK)"
echo "+ write $ETC/grants.env (PGPASSFILE, PGHOST, DX_APP_DB=$APPDB)"
if [ "$REAL" = 1 ]; then
  umask 027
  cat > "$ETC/door.env" <<ENV
DX_DOOR_KEY=$DOOR_KEY
DX_DOOR_SOCKET=/run/developer/door.sock
PGPASSFILE=$ETC/door.pgpass
PGHOST=127.0.0.1
PGPORT=5432
DX_APP_DB=$APPDB
DX_KERNEL_DB=$KERNEL_DB
DX_DOOR_POOL_MAX=12
DX_DOOR_STATE=/var/lib/developer-door
DX_SQUAWK=$APP/services/.venv/bin/squawk
ENV
  cat > "$ETC/grants.env" <<ENV
PGPASSFILE=$ETC/grants.pgpass
PGHOST=127.0.0.1
PGPORT=5432
DX_APP_DB=$APPDB
ENV
  umask 022
  chown root:developer-door "$ETC/door.env"; chmod 0640 "$ETC/door.env"
  chown root:developer-grants "$ETC/grants.env"; chmod 0640 "$ETC/grants.env"
fi

# ------------------------------------------------------------------------------------------------------------------------------------
# 7. THE WORKBENCH TEMPLATE dx_template (idempotent; design §6.5, the owner's (d)). A schema-only clone of a database that uses an
#    untrusted extension (vector) is restored into a database made FROM this template, where root installed it once; the rolemaker (a
#    CREATEDB role) may clone it because it is marked a template. maludb_core is NOT in it (a co-located MaluDB schema is never cloned).
echo "== 7. dx_template (IS_TEMPLATE, vector and the trusted extensions the applications use; CONNECT revoked from PUBLIC)"
EXISTS=$( [ "$REAL" = 1 ] && pgval "SELECT 1 FROM pg_database WHERE datname = 'dx_template'" || echo '')
if [ -z "$EXISTS" ]; then echo "CREATE DATABASE dx_template IS_TEMPLATE true;" | pg postgres; else echo "   dx_template exists"; fi
pg dx_template <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
SQL
echo "REVOKE CONNECT ON DATABASE dx_template FROM PUBLIC;" | pg postgres

# ------------------------------------------------------------------------------------------------------------------------------------
# 8. PGAUDIT PER TOOL ROLE (idempotent; D14). Set by a superuser, so the tool cannot turn it off: a server record of every change the tool
#    makes, without the volume that turned cluster-wide pgaudit off on 2026-10-10. developer_write runs only composed statements with
#    bound values, and pgaudit does not log parameters unless pgaudit.log_parameter is on — no value reaches the server log. The read
#    tiers are not server-audited (the tool's own audit holds every read); workbench roles cannot be (the setting is a superuser's).
echo "== 8. pgaudit per role: write on developer_write; ddl, misc on developer_ops; role, ddl on developer_rolemaker"
pg postgres <<'SQL'
ALTER ROLE developer_write     SET pgaudit.log = 'write';
ALTER ROLE developer_ops       SET pgaudit.log = 'ddl, misc';
ALTER ROLE developer_rolemaker SET pgaudit.log = 'role, ddl';
SQL

# ------------------------------------------------------------------------------------------------------------------------------------
# 9. THE SERVICES' PYTHON AND LIBPG_QUERY (idempotent; D7, K39). The door and the grants service run from services/.venv (psycopg 3, our
#    own ctypes binding of libpg_query, squawk), root-owned and read-only to them; the kernel's installer builds only mcp/venv. libpg_query
#    (BSD-3) is built from a pinned release by deploy/build-libpg_query.sh (gcc and make are on this host) — Phase 0's door proof writes it.
echo "== 9. services/.venv from services/requirements.txt; deploy/build-libpg_query.sh"
if [ ! -f "$APP/services/requirements.txt" ]; then
  echo "   services/requirements.txt is not there yet (the door proof's) — skipped"
else
  [ -x "$APP/services/.venv/bin/python" ] || run python3 -m venv "$APP/services/.venv"
  run "$APP/services/.venv/bin/pip" install -q --disable-pip-version-check -r "$APP/services/requirements.txt"
  run chown -R root:root "$APP/services/.venv"
  run chmod -R go-w "$APP/services/.venv"
fi
if [ -f "$APP/deploy/build-libpg_query.sh" ]; then run bash "$APP/deploy/build-libpg_query.sh"
else echo "   deploy/build-libpg_query.sh is not there yet (the door proof's) — skipped"; fi

# ------------------------------------------------------------------------------------------------------------------------------------
# 10. THE UNITS (printed). The kernel's installer renders, installs and enables the eleven units of maludb-os.json services[] — the two MCP
#     servers (developer-mcp), the ingest, the directory sync and the worker with their timers (developer-web), the door's socket and
#     service (developer-door; the socket is developer-door:developer 0660 at /run/developer/door.sock) and the grants service
#     (developer-grants). The door and the grants service skip themselves (ConditionPathExists) until services/door/server.py and
#     services/grants/service.py exist. After the apply:
#       systemctl status developer-door.socket developer-door developer-grants developer-records-mcp developer-activity-mcp
#       stat -c '%U:%G %a %n' /run/developer/door.sock          -> developer-door:developer 660
echo "== 10. The units — installed by the installer's apply from services[] (printed, not run here)"
echo "   php $KERNEL/bin/app_install.php plan $APP --by <super-admin email> --domain <domain>          (read-only)"
echo "   sudo php $KERNEL/bin/app_install.php apply $APP --by <super-admin email> --domain <domain> --hire-agents"
echo "   — NEVER --grant-standing-departments: nobody is admitted to Developer by default (grant_standing_departments false, K14)."
echo "   — then: sudo bash deploy/ROOT_STEPS.sh after"
fi

if [ "$DO_AFTER" = 1 ]; then
# ------------------------------------------------------------------------------------------------------------------------------------
# 11. AFTER EVERY APPLY: config/.env back to group `developer` (the installer writes it group www-data whenever it writes a key — K54 owes
#     the fix), storage/ back to developer-web.
echo "== 11. (after apply) config/.env and storage/ back to the group developer"
if [ -f "$ENVF" ]; then run chgrp developer "$APP/config" "$ENVF"; run chmod 0750 "$APP/config"; run chmod 0640 "$ENVF"; fi
if [ -d "$APP/storage" ]; then run chown -R developer-web:developer "$APP/storage"; fi
# storage/exports and storage/imports are the door's (it writes an export's file and reads an upload — the-door.md §6.9–6.10): developer-door, setgid developer.
for d in exports imports; do run install -d -o developer-door -g developer -m 2770 "$APP/storage/$d"; done
run systemctl try-restart developer-records-mcp developer-activity-mcp php8.3-fpm
# The installer enables every listed unit but a .socket (its filter keeps only timers and services without a timer); the door's service
# Requires= its socket, so it starts with it — enabling the socket too makes it come up at boot on its own.
run systemctl enable -q developer-door.socket

# ------------------------------------------------------------------------------------------------------------------------------------
# 12. AFTER EVERY APPLY: the tool's own database (deploy/own-database.sql, idempotent): pg_stat_statements (once — one database covers the
#     cluster), the door's login (developer_meta) on the policy and audit functions, the grants service's plan for developer_grantor,
#     dx_signal() owned by developer_signaller with EXECUTE for developer_ops alone.
echo "== 12. (after apply) deploy/own-database.sql in $APPDB"
if [ "$REAL" = 1 ]; then
  if [ -n "$(pgval "SELECT 1 FROM pg_database WHERE datname = '$APPDB'")" ]; then
    runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 -d "$APPDB" -f "$APP/deploy/own-database.sql"
  else echo "   $APPDB does not exist yet — run the installer's apply first" >&2; fi
else echo "+ (postgres) psql -d $APPDB -f deploy/own-database.sql"; fi

# ------------------------------------------------------------------------------------------------------------------------------------
# 13. THE TARGETS' GRANTS (printed — the owner runs each line once an admin has registered and classified the database in the tool; the
#     registry screen prints the same line, and grants_state reads in_place on the next worker pass). Suggested from this cluster:
echo "== 13. (after apply) deploy/grant-target.sh per registered target — printed, run each as postgres once it is classified in the tool"
if [ "$REAL" = 1 ]; then
  echo "   sudo -u postgres bash $APP/deploy/grant-target.sh $KERNEL_DB kernel"
  echo "   sudo -u postgres bash $APP/deploy/grant-target.sh $APPDB own"
  pgval "SELECT datname FROM pg_database WHERE datname ~ '^${TENANT}_[a-z0-9_]+\$' AND datname <> '$APPDB' ORDER BY 1" | while read -r d; do
    if [ -n "$(runuser -u postgres -- psql -X -At -d "$d" -c "SELECT 1 FROM pg_extension WHERE extname = 'maludb_core'" 2>/dev/null)" ] \
       && [ -z "$(runuser -u postgres -- psql -X -At -d "$d" -c "SELECT 1 FROM pg_namespace WHERE nspname = 'memory'" 2>/dev/null)" ]; then
      echo "   sudo -u postgres bash $APP/deploy/grant-target.sh $d memory"
    else
      echo "   sudo -u postgres bash $APP/deploy/grant-target.sh $d application"
    fi
  done
  echo "   (and ${KERNEL_DB}_memory and maludb as memory, should the memory section read them; development databases only as wanted)"
else
  echo "+ list ${TENANT}_* databases and print one grant-target.sh line each (application, or memory for a dedicated memory database)"
fi

# ------------------------------------------------------------------------------------------------------------------------------------
# 14. OPTIONAL (--with-io-timing): let the read tiers turn on track_io_timing for EXPLAIN (ANALYZE, BUFFERS) — the door sets it for that
#     statement only; people never can (SET is refused in their SQL). Without it, BUFFERS shows counts but no I/O times.
if [ "$IOT" = 1 ]; then
  echo "== 14. GRANT SET ON PARAMETER track_io_timing TO developer_read, developer_read_masked"
  echo "GRANT SET ON PARAMETER track_io_timing TO developer_read, developer_read_masked;" | pg postgres
else
  echo "== 14. (optional, --with-io-timing) GRANT SET ON PARAMETER track_io_timing — not asked for"
fi
fi
