#!/usr/bin/env bash
# The door proof (design §6.12). Builds libpg_query and services/.venv if needed, creates scratch cluster roles `dx_proof_*` and scratch
# databases `dx_door_*` with `sudo -n -u postgres` (the owner's leave covers dx_* roles and databases only — design §15 (d)), runs every
# bullet of §6.12 through tests/door/proof.py, prints `ok N` / `not ok N` and a total, and drops everything it made unless KEEP=1.
#
#   tests/door/run.sh            KEEP=1 tests/door/run.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
"${HERE}/deploy/build-libpg_query.sh" >/dev/null
if [[ ! -x "${HERE}/services/.venv/bin/python" ]]; then
    python3 -m venv "${HERE}/services/.venv"
    "${HERE}/services/.venv/bin/pip" install -q -r "${HERE}/services/requirements.txt"
fi
exec "${HERE}/services/.venv/bin/python" -I "${HERE}/tests/door/proof.py" "$@"
