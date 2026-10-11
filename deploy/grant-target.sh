#!/usr/bin/env bash
# Developer — grant the tool's cluster roles on ONE target database (design §6.1, §6.2). NOTHING HERE HAS BEEN RUN — the owner runs it,
# as postgres, once per database an admin registers in the tool (the registry screen prints the exact line), and again after a schema
# change that adds a schema or tables not created by `postgres`:
#
#   sudo -u postgres bash deploy/grant-target.sh <database> <class>          prints every statement, then runs them in one transaction
#   sudo -u postgres bash deploy/grant-target.sh <database> <class> --plan   prints them only
#   sudo -u postgres bash deploy/grant-target.sh <database> --revoke         takes every privilege of the tool's roles off the database
#
# <class> is application | development | own | memory | kernel (design §3). Idempotent: GRANT and ALTER DEFAULT PRIVILEGES are no-ops
# when already in place. The tool can never grant itself a privilege: this script, run by root, is the only grant path for the roles
# below — EXCEPT the column privileges of developer_read, developer_read_masked and developer_write, which the grants service gives
# (as developer_grantor, from the classifications), so this script gives those three tiers nothing on tables directly.
#
# What each class gets (all of it CONNECT plus, for application/development/own, per schema of the database other than the system
# schemas, a co-located MaluDB `memory` schema and any schema an extension owns):
#   application  CONNECT for meta, read, read_masked, write, ops, grantor; schema USAGE for the same; SELECT on sequences for meta (the
#                limits check); USAGE on sequences for write (an INSERT into a serial column calls nextval); table-level MAINTAIN for ops
#                (VACUUM, ANALYZE, REINDEX CONCURRENTLY, REFRESH … CONCURRENTLY and the clone's dump locks — not the cluster-wide
#                pg_maintain); SELECT, INSERT, UPDATE, DELETE WITH GRANT OPTION for grantor; the same as default privileges for objects
#                `postgres` creates later.
#   development  as application without write and ops (structure, and rows where an admin grants a level; nothing changed)
#   own          as development (the tool's own database: structure; rows for admins through the grants service)
#   memory       CONNECT for meta and memory (the memory login reads through maludb_memory_auditor by SET ROLE — ROOT_STEPS step 4)
#   kernel       CONNECT for meta only — structure only, never a row (the owner's (a))
set -euo pipefail

DB=${1:-}; CLASS=${2:-}; MODE=apply
for a in "${@:3}"; do case "$a" in --plan) MODE=plan;; *) echo "unknown argument: $a" >&2; exit 2;; esac; done
[ "$CLASS" = "--revoke" ] && { MODE=revoke; CLASS=; }
[ "${2:-}" = "--plan" ] && { echo "a class comes before --plan" >&2; exit 2; }
KERNEL_DB=${KERNEL_DB:-certstudy}

die() { echo "REFUSED: $*" >&2; exit 3; }
[ -n "$DB" ] || die "usage: grant-target.sh <database> <class> [--plan] | <database> --revoke"
[[ "$DB" =~ ^[a-z0-9_]+$ ]] || die "'$DB' — a target's name is lowercase letters, digits and underscores only (design §3 wall 1)"
case "$DB" in
  postgres|template0|template1) die "$DB is a system database — never a target" ;;
  dxw_*|dxr_*|dx_template) die "$DB is the tool's own workbench, rehearsal clone or template — developer_rolemaker owns those" ;;
esac
[ "$(id -un)" = postgres ] || die "run as postgres: sudo -u postgres bash deploy/grant-target.sh …"

PSQL=(psql -X -q -At -v ON_ERROR_STOP=1)
"${PSQL[@]}" -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$DB'" | grep -q 1 || die "no database $DB on this cluster"

ROLES_ALL="developer_meta developer_read developer_read_masked developer_write developer_ops developer_rolemaker developer_memory developer_grantor"
for r in $ROLES_ALL; do
  "${PSQL[@]}" -d postgres -c "SELECT 1 FROM pg_roles WHERE rolname = '$r'" | grep -q 1 || die "role $r does not exist — run deploy/ROOT_STEPS.sh step 4 first"
done

has_maludb=$("${PSQL[@]}" -d "$DB" -c "SELECT count(*) FROM pg_extension WHERE extname = 'maludb_core'")
if [ "$DB" = "$KERNEL_DB" ] && [ "$MODE" != revoke ] && [ "$CLASS" != kernel ]; then
  die "$DB is the kernel's database — class kernel only (CONNECT for developer_meta, structure only)"
fi
if [ "$CLASS" = kernel ] && [ "$DB" != "$KERNEL_DB" ]; then die "class kernel is for $KERNEL_DB only (set KERNEL_DB if the kernel's database has another name)"; fi
if [ "$CLASS" = memory ] && [ "$has_maludb" = 0 ]; then die "$DB holds no maludb_core — not a memory database"; fi
case "$CLASS" in application|development|own|memory|kernel|"") ;; *) die "class '$CLASS' — one of application, development, own, memory, kernel" ;; esac

# The schemas the tiers may see: not the system's, not a co-located MaluDB schema, not one an extension owns.
SCHEMAS_SQL="SELECT n.nspname FROM pg_namespace n
  WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
    AND n.nspname NOT IN ('memory', 'maludb_core', 'maludb_public', 'mc2db')
    AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_namespace'::regclass AND d.objid = n.oid AND d.deptype = 'e')
  ORDER BY 1"

# Build the statement list (identifiers quoted by the server — format('%I') — never by hand).
build() {
  local q
  case "$1" in
    connect) q="SELECT format('GRANT CONNECT ON DATABASE %I TO %s;', '$DB', '$2')" ;;
    perschema) q="SELECT format('$2', nspname, nspname) FROM ($SCHEMAS_SQL) s(nspname)" ;;
  esac
  "${PSQL[@]}" -d "$DB" -c "$q"
}

STMTS=()
add() { while IFS= read -r line; do [ -n "$line" ] && STMTS+=("$line"); done <<< "$1"; }

if [ "$MODE" = revoke ]; then
  add "$(build perschema 'REVOKE ALL ON ALL TABLES IN SCHEMA %I FROM developer_read, developer_read_masked, developer_write, developer_ops, developer_grantor CASCADE; REVOKE ALL ON ALL SEQUENCES IN SCHEMA %I FROM developer_meta, developer_write;')"
  add "$(build perschema 'REVOKE USAGE ON SCHEMA %I FROM developer_meta, developer_read, developer_read_masked, developer_write, developer_ops, developer_grantor; ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I REVOKE ALL ON TABLES FROM developer_grantor, developer_ops;')"
  add "$(build perschema 'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I REVOKE ALL ON SEQUENCES FROM developer_meta, developer_write; SELECT %L;')"
  add "$("${PSQL[@]}" -d "$DB" -c "SELECT format('REVOKE CONNECT ON DATABASE %I FROM developer_meta, developer_read, developer_read_masked, developer_write, developer_ops, developer_memory, developer_grantor;', '$DB')")"
else
  case "$CLASS" in
    kernel)
      add "$(build connect developer_meta)" ;;
    memory)
      add "$(build connect 'developer_meta, developer_memory')" ;;
    development|own)
      add "$(build connect 'developer_meta, developer_read, developer_read_masked, developer_grantor')"
      add "$(build perschema 'GRANT USAGE ON SCHEMA %I TO developer_meta, developer_read, developer_read_masked, developer_grantor; GRANT SELECT ON ALL SEQUENCES IN SCHEMA %I TO developer_meta;')"
      add "$(build perschema 'GRANT SELECT ON ALL TABLES IN SCHEMA %I TO developer_grantor WITH GRANT OPTION; ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT SELECT ON TABLES TO developer_grantor WITH GRANT OPTION;')"
      add "$(build perschema 'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT SELECT ON SEQUENCES TO developer_meta; SELECT %L;')" ;;
    application)
      add "$(build connect 'developer_meta, developer_read, developer_read_masked, developer_write, developer_ops, developer_grantor')"
      add "$(build perschema 'GRANT USAGE ON SCHEMA %I TO developer_meta, developer_read, developer_read_masked, developer_write, developer_ops, developer_grantor; GRANT SELECT ON ALL SEQUENCES IN SCHEMA %I TO developer_meta;')"
      add "$(build perschema 'GRANT USAGE ON ALL SEQUENCES IN SCHEMA %I TO developer_write; GRANT MAINTAIN ON ALL TABLES IN SCHEMA %I TO developer_ops;')"
      add "$(build perschema 'GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO developer_grantor WITH GRANT OPTION; ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO developer_grantor WITH GRANT OPTION;')"
      add "$(build perschema 'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT MAINTAIN ON TABLES TO developer_ops; ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT SELECT ON SEQUENCES TO developer_meta;')"
      add "$(build perschema 'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT USAGE ON SEQUENCES TO developer_write; SELECT %L;')" ;;
    *) die "a class is required: application, development, own, memory or kernel" ;;
  esac
fi

# Drop the "SELECT 'schema';" fillers some templates end with (format() needs every %I/%L consumed).
FINAL=()
for s in "${STMTS[@]}"; do FINAL+=("$(printf '%s' "$s" | sed -E "s/ SELECT '[^']*';$//")"); done

echo "-- grant-target.sh $DB ${CLASS:-(revoke)} — $(date -u +%FT%TZ)"
for s in "${FINAL[@]}"; do echo "+ $s"; done
if [ "$MODE" = plan ]; then echo "-- (--plan: nothing run)"; exit 0; fi
{ echo "BEGIN;"; printf '%s\n' "${FINAL[@]}"; echo "COMMIT;"; } | psql -X -q -v ON_ERROR_STOP=1 -d "$DB"
echo "-- done. The tool's registry reads grants_state on its next worker pass; the grants service gives the tiers their columns within a minute."
