"""A schema-only clone of a registered target into a workbench (design §6.5).

    report = schema_clone(cfg, source_db="subello_gl", target_db="dxw_7", target_role="dxw_7")

pg_dump runs as the ops role — table-level MAINTAIN admits the dump's ACCESS SHARE locks (the LOCK TABLE rule: "If the user has MAINTAIN,
UPDATE, DELETE, or TRUNCATE privileges on the table, any lockmode is permitted") — in the custom format, schema only, with a lock wait
timeout, the co-located MaluDB schema and extension left out. The target is a conninfo built by psycopg's quoting from a validated name and
passed as ONE argument (never through a shell; a database name holding `=` or a URI can never turn into connection options — wall 1).
pg_restore runs as the workbench's own role, without owners or privileges; the role's password reaches pg_restore through a temporary 0600
passfile in the door's private directory, never on a command line.
"""
from __future__ import annotations

import os
import subprocess
import tempfile
import time

from door import connections


def schema_clone(cfg, *, source_db: str, target_db: str, target_role: str, timeout: int = 600) -> dict:
    connections.check_name(source_db)
    connections.check_name(target_db)
    t0 = time.monotonic()
    tmpdir = tempfile.mkdtemp(prefix="dx-clone-")
    os.chmod(tmpdir, 0o700)
    dump = os.path.join(tmpdir, "schema.dump")
    try:
        src = connections.conninfo(cfg, cfg.roles["ops"], source_db, app="developer:clone")
        # maludb_core's schemas are not extension members (CREATE EXTENSION made them), so --exclude-extension alone leaves them as
        # empty schemas: the co-located MaluDB is left out by its schemas too.
        p = subprocess.run([cfg.pg_dump, "--format=custom", "--schema-only", "--lock-wait-timeout=5s", "--exclude-schema=memory",
                            "--exclude-schema=maludb*", "--exclude-schema=mc2db", "--exclude-extension=maludb_core",
                            "--file", dump, "--dbname", src],
                           capture_output=True, text=True, timeout=timeout, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C.UTF-8"})
        if p.returncode != 0:
            return {"status": "error", "step": "dump", "message": (p.stderr or "")[-1000:]}
        pw = connections.WorkbenchStore(cfg.workbench_store).get(target_role)
        if pw is None:
            return {"status": "error", "step": "credential", "message": "The workbench's credential is lost."}
        passfile = os.path.join(tmpdir, "pass")
        fd = os.open(passfile, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            esc = pw.replace("\\", "\\\\").replace(":", "\\:")
            f.write(f"*:*:{target_db}:{target_role}:{esc}\n")
        dst = connections.make_conninfo(host=cfg.host, port=cfg.port, dbname=target_db, user=target_role, sslmode=cfg.sslmode,
                                        passfile=passfile, application_name="developer:clone")
        r = subprocess.run([cfg.pg_restore, "--no-owner", "--no-privileges", "--dbname", dst, dump],
                           capture_output=True, text=True, timeout=timeout, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C.UTF-8"})
        # pg_restore prints each failure as an `error:` line followed by `Command was: …`. COMMENT ON EXTENSION fails for a
        # non-owner (the extension came from the template, owned by postgres) — expected and harmless; anything else is reported.
        lines = (r.stderr or "").splitlines()
        errors, benign = [], 0
        for i, ln in enumerate(lines):
            if "error:" not in ln:
                continue
            cmd = next((x for x in lines[i + 1:i + 3] if x.startswith("Command was:")), "")
            if cmd.startswith("Command was: COMMENT ON EXTENSION"):
                benign += 1
            else:
                errors.append((ln + " " + cmd)[:300])
        return {"status": "ok" if not errors else "errors", "restore_errors": errors[:20], "error_count": len(errors),
                "benign_count": benign, "ms": int((time.monotonic() - t0) * 1000), "dump_bytes": os.path.getsize(dump)}
    finally:
        for fn in os.listdir(tmpdir):
            try:
                os.unlink(os.path.join(tmpdir, fn))
            except OSError:
                pass
        os.rmdir(tmpdir)
