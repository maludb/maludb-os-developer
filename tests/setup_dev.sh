#!/usr/bin/env bash
# Builds the SCRATCH database the proofs run against — never the installed application's database.
#   tests/setup_dev.sh            (needs `sudo -n -u postgres` — for scratch dx_* databases and the three developer_* roles only, the
#                                  owner's leave of 2026-10-11; recreates $DX_DEV_DB, default dx_dev0)
# 1. drops and creates the scratch database; 2. applies db/[0-9]*.sql in order as postgres (the same files the installer applies) —
#    DX_MIGRATIONS_UPTO=005 (or DX_DEV_UPTO) stops after the kit's db/001–005 while the schema's later files are being written;
#    3. leaves the cluster roles' passwords ALONE when the app is installed (reads them from config/.env — the worktree lesson); else
#    gives them a scratch password (the kernel's installer sets fresh ones at `apply`); 4. makes a scratch export store
#    ($DX_DEV_STORAGE, default /tmp/<db>-storage); 5. writes the proofs' environment to $DX_DEV_ENV (default /tmp/dx-dev0.env, mode 600)
#    — app/bootstrap.php reads $DX_DEV_ENV instead of config/.env when it is set (never in production). Nothing here is committed or
#    installed, and nothing here reaches a target database: the door is not part of the kit's proof (tests/door/ proves it).
#    Ports 9401 (the app), 9402 (the fake kernel), 9403 (the fake MaluDB + MaluMail REST), 9404–9405 (the MCP servers, Phase 4),
#    9406 (a scratch door socket's helper, tests/door/), 9407 (spare).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DB=${DX_DEV_DB:-dx_dev0}
case "$DB" in dx_*) ;; *) echo "refused: the scratch database must be named dx_* (got $DB)"; exit 2 ;; esac
ENVF=${DX_DEV_ENV:-/tmp/dx-dev0.env}
PW=$(openssl rand -hex 16)
PSQL="sudo -n -u postgres psql -v ON_ERROR_STOP=1 -q"
$PSQL -c "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB"
UPTO=${DX_MIGRATIONS_UPTO:-${DX_DEV_UPTO:-999}}
for f in "$ROOT"/db/[0-9]*.sql; do n=$(basename "$f" | cut -c1-3); [ "$((10#$n))" -le "$((10#$UPTO))" ] 2>/dev/null || continue; $PSQL -d "$DB" -f "$f" >/dev/null || { echo "FAILED: $f"; exit 1; }; done
LIVEENV="$ROOT/config/.env"
lv() { grep -m1 "^$1=" "$LIVEENV" | cut -d= -f2-; }
if [ -f "$LIVEENV" ] && [ -n "$(lv DB_PASSWORD)" ] && [ -n "$(lv MCP_RECORDS_DB_PASSWORD)" ] && [ -n "$(lv MCP_ACTIVITY_DB_PASSWORD)" ]; then
  PW_RW=$(lv DB_PASSWORD); PW_REC=$(lv MCP_RECORDS_DB_PASSWORD); PW_ACT=$(lv MCP_ACTIVITY_DB_PASSWORD)
else
  PW_RW=$PW; PW_REC=$PW; PW_ACT=$PW
  for r in developer_rw developer_records_ro developer_activity_ro; do $PSQL -c "ALTER ROLE $r WITH LOGIN PASSWORD '$PW'"; done
fi
STORE=${DX_DEV_STORAGE:-/tmp/${DB}-storage}          # the export store: a scratch one, emptied
rm -rf "$STORE"; mkdir -p "$STORE"/{exports,tmp}
umask 077
DOOR_KEY=$(openssl rand -hex 32)
cat > "$ENVF" <<ENV
APP_ENV=dev
APP_DEBUG=1
APP_NAME="Developer"
APP_KEY=developer
APP_URL=http://127.0.0.1:9401
DB_HOST=127.0.0.1
DB_PORT=5432
DB_NAME=$DB
DB_USER=developer_rw
DB_PASSWORD=$PW_RW
MCP_RECORDS_DB_USER=developer_records_ro
MCP_RECORDS_DB_PASSWORD=$PW_REC
MCP_ACTIVITY_DB_USER=developer_activity_ro
MCP_ACTIVITY_DB_PASSWORD=$PW_ACT
APP_INTERNAL_PORT=9401
MCP_RECORDS_PORT=9404
MCP_ACTIVITY_PORT=9405
DX_DOOR_SOCKET=/tmp/${DB}-door.sock
DX_DOOR_KEY=$DOOR_KEY
DX_SHOW_ROWS=1000
DX_SHOW_BYTES=8388608
DX_DOT=/usr/bin/dot
ACTION_TOKEN_KEY=$(openssl rand -hex 32)
ACTIONS_RELAY_KEY=$(openssl rand -hex 32)
OS_LAUNCHER_URL=https://app.example.invalid/
OS_INTERNAL_URL=http://127.0.0.1:9402
OS_APPLICATION_TOKEN=osapp_dev_$(openssl rand -hex 12)
MALUDB_API_URL=http://127.0.0.1:9403
MALUDB_API_TOKEN=dev-maludb-$(openssl rand -hex 8)
MALUMAIL_API_URL=http://127.0.0.1:9403
MALUMAIL_API_KEY=dev-developer-$(openssl rand -hex 8)
MAIL_FROM=developer@example.invalid
MAIL_FROM_NAME="Developer"
DX_STORAGE_DIR=$STORE
ENV
echo "scratch database $DB ready; environment in $ENVF"
