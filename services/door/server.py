"""The door's socket server (design §6.1). Follows the Data Lake's services/query/server.py.

    services/.venv/bin/python services/door/server.py      (developer-door.service, started by developer-door.socket)

THE SOCKET. Production: systemd's socket unit (developer-door.socket — the socket's group is `developer`, so the door's own user stays out
of that group) passes the listening socket as fd 3 (LISTEN_FDS / LISTEN_PID, sd_listen_fds' protocol). Proofs and development: no passed
socket → the server binds DX_DOOR_SOCKET itself (mode 0660). No TCP listener ever.

ON ACCEPT: SO_PEERCRED must be one of the allowed uids (developer-web, developer-mcp — never the web server's shared uid; design D6). One
request per connection: one line of UTF-8 JSON in (≤ 1 MB), one line out. Every request carries `mac` = HMAC-SHA256 under the door's key of
the canonical JSON of the request without `mac` (sorted keys, no spaces), a `ts` within 60 s, and a `request_id` the door has not seen in
the last 120 s (no replay); then the member must be active (dx_door_member_active). Everything else the door computes itself from the
policy — a caller never sends a level, a tier or a right.

Kinds: `ping` · `run` (typed SQL, run.py) · `cancel` (beside the run it interrupts, by the caller who started it) · `named` (named.py, as
the meta tier; counted) · `memory` (memory_queries.py) · `apply` / `undo` (apply.py, the write tier) · `workbench_create` (empty, or a
schema clone of `source`) · `workbench_drop` · `workbench_reset` (a super-admin's) · `rehearse` (refused under `is_eval`).
"""
from __future__ import annotations

import grp
import hashlib
import hmac
import json
import os
import pwd
import socket
import socketserver
import struct
import sys
import threading
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:] = [p for p in sys.path if os.path.abspath(p or ".") != _HERE]
sys.path.insert(0, os.path.dirname(_HERE))

from door import apply as apply_mod  # noqa: E402
from door import clone as clone_mod  # noqa: E402
from door import connections, decide, memory_queries, named, pgquery, rehearse, run, workbench  # noqa: E402

MAX_REQUEST = 1024 * 1024
CLOCK_SKEW = 60
REPLAY_WINDOW = 120
SD_LISTEN_FDS_START = 3


def canonical(req: dict) -> bytes:
    body = {k: v for k, v in req.items() if k != "mac"}
    return json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def sign(key: bytes, req: dict) -> dict:
    req = dict(req)
    req["mac"] = hmac.new(key, canonical(req), hashlib.sha256).hexdigest()
    return req


def peer_uid(sock: socket.socket) -> int | None:
    try:
        creds = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        _pid, uid, _gid = struct.unpack("3i", creds)
        return uid
    except OSError:
        return None


def systemd_socket() -> socket.socket | None:
    """The listening socket systemd passed (sd_listen_fds), or None."""
    if os.environ.get("LISTEN_PID") != str(os.getpid()):
        return None
    try:
        n = int(os.environ.get("LISTEN_FDS", "0"))
    except ValueError:
        return None
    if n < 1:
        return None
    for k in ("LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES"):
        os.environ.pop(k, None)
    return socket.socket(fileno=SD_LISTEN_FDS_START)


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        srv: DoorServer = self.server  # type: ignore[assignment]
        if peer_uid(self.request) not in srv.allowed_uids:
            return self._send({"status": "refused", "refusal_rule": "peer", "message": "Only Developer may ask the door."})
        line = self.rfile.readline(MAX_REQUEST + 1)
        if len(line) > MAX_REQUEST:
            return self._send({"status": "refused", "refusal_rule": "too_long", "message": "The request is too long."})
        try:
            req = json.loads(line.decode("utf-8"))
            assert isinstance(req, dict)
        except Exception:
            return self._send({"status": "refused", "refusal_rule": "bad_request", "message": "Not a request."})
        why = srv.verify(req)
        if why:
            return self._send({"status": "refused", "refusal_rule": why, "message": "The request is not signed for this door."})
        self._send(srv.dispatch(req))

    def _send(self, obj):
        try:
            self.wfile.write((json.dumps(obj, separators=(",", ":"), default=str) + "\n").encode())
        except (BrokenPipeError, ConnectionResetError):
            pass


class DoorServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True

    def __init__(self, path: str | None, cfg, policies, key: bytes, allowed_uids: set[int], group: str | None = None,
                 listening: socket.socket | None = None):
        if listening is not None:                                     # passed by systemd: already bound and listening
            super().__init__(listening.getsockname() or "", Handler, bind_and_activate=False)
            self.socket = listening
        else:
            if path and os.path.exists(path):
                os.unlink(path)
            super().__init__(path, Handler)
            os.chmod(path, 0o660)
            if group:
                try:
                    os.chown(path, -1, grp.getgrnam(group).gr_gid)
                except (KeyError, PermissionError):
                    pass
        self.cfg = cfg
        self.policies = policies
        self.key = key
        self.allowed_uids = allowed_uids
        self.registry = run.Registry()
        self._seen: dict[str, float] = {}
        self._seen_lock = threading.Lock()

    def verify(self, req: dict) -> str | None:
        mac = req.get("mac")
        if not isinstance(mac, str) or not hmac.compare_digest(mac, hmac.new(self.key, canonical(req), hashlib.sha256).hexdigest()):
            return "mac"
        ts = req.get("ts")
        if not isinstance(ts, (int, float)) or abs(time.time() - ts) > CLOCK_SKEW:
            return "stale"
        rid = req.get("request_id")
        if not isinstance(rid, str) or not rid:
            return "bad_request"
        now = time.time()
        with self._seen_lock:
            for k in [k for k, t in self._seen.items() if now - t > REPLAY_WINDOW]:
                del self._seen[k]
            if rid in self._seen:
                return "replay"
            self._seen[rid] = now
        if req.get("kind") != "ping":
            try:
                caller = int(req.get("caller") or 0)
            except (TypeError, ValueError):
                return "bad_request"
            if caller <= 0 or not self.policies.member_active(caller):
                return "inactive"
        return None

    def dispatch(self, req: dict) -> dict:
        kind = req.get("kind")
        handlers = {"run": lambda r: run.run_request(self.cfg, self.policies, self.registry, r), "cancel": self._cancel,
                    "named": self._named, "memory": self._memory, "apply": self._apply, "undo": self._apply,
                    "workbench_create": self._wb_create, "workbench_drop": self._wb_drop, "workbench_reset": self._wb_reset,
                    "rehearse": self._rehearse}
        try:
            if kind == "ping":
                return {"status": "ok", "grammar": pgquery.server_version_num()}
            h = handlers.get(kind)
            if h is None:
                return {"status": "refused", "refusal_rule": "bad_request", "message": "Unknown request kind."}
            return h(req)
        except connections.DoorRefusal as e:
            return {"status": "refused", "refusal_rule": e.rule, "message": e.message}
        except Exception as e:  # pragma: no cover - a fault, logged on the journal; never a traceback to the caller
            import traceback
            traceback.print_exc()
            return {"status": "error", "refusal_rule": "door", "message": "The door could not finish this request.",
                    "error_kind": type(e).__name__}

    # ── helpers ────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    def _policy(self, req, datname=None):
        return self.policies.get(int(req.get("caller") or 0), req.get("on_behalf_of"), datname or req.get("datname") or "")

    @staticmethod
    def _no(rule, message, **extra):
        return {"status": "refused", "refusal_rule": rule, "message": message, **extra}

    def _app(self, req):
        return run.app_name(req.get("caller"), req.get("request_id"))

    # ── kinds ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    def _cancel(self, req):
        ok = self.registry.cancel(str(req.get("target_request_id") or ""), int(req.get("caller") or 0))
        return {"status": "ok" if ok else "refused", "cancelled": ok}

    def _named(self, req):
        p = self._policy(req)
        if not p.ok or p.frozen:
            return self._no("policy", (p.refusal or {}).get("message") or "Not allowed.")
        if not p.has("catalog.read"):
            return self._no("right", "Reading the catalog is a Viewer's.")
        if (p.target or {}).get("class") in (None, "system", "unclassified"):
            return self._no("target", "This database is not one the tool may reach.")
        self.policies.usage_bump(int(req.get("caller")), f"named:{req.get('name')}")
        with connections.connect(self.cfg, "meta", connections.check_name(req["datname"]), app=self._app(req)) as conn:
            return named.run_named(conn, req.get("name") or "", req.get("params") or {})

    def _memory(self, req):
        p = self._policy(req)
        if not p.ok or p.frozen:
            return self._no("policy", (p.refusal or {}).get("message") or "Not allowed.")
        if not p.has("memory.read"):
            return self._no("right", "The memory section is a Viewer's.")
        if (p.target or {}).get("class") != "memory":
            return self._no("target", "This is not a memory database.")
        self.policies.usage_bump(int(req.get("caller")), f"memory:{req.get('name')}")
        with connections.connect(self.cfg, "memory", connections.check_name(req["datname"]), app=self._app(req)) as conn:
            return memory_queries.run_memory(conn, self.cfg.memory_auditor, req.get("name") or "")

    def _apply(self, req):
        p = self._policy(req)
        d = decide.decide_apply(p)
        if d.tier is None:
            return self._no(d.rule, d.refusal)
        with connections.connect(self.cfg, "write", connections.check_name(req["datname"]), app=self._app(req)) as conn:
            if req.get("kind") == "undo":
                return apply_mod.undo_change_set(conn, req.get("images") or [])
            return apply_mod.apply_change_set(conn, req.get("items") or [], p.limits)

    def _wb_create(self, req):
        source = req.get("source")
        p = self._policy(req, source or self.cfg.own_db)
        if not p.ok or p.frozen:
            return self._no("policy", (p.refusal or {}).get("message") or "Not allowed.")
        if p.is_agent:
            return self._no("agent", "Agents do not make workbenches; they rehearse on a throwaway copy.")
        if not p.has("workbench.use"):
            return self._no("right", "Workbenches are an Engineer's.")
        left = p.limits.get("workbenches_left")
        if left is not None and int(left) <= 0:
            return self._no("quota", "You have as many workbenches as you may — drop one first.")
        if source and (p.target or {}).get("class") not in ("application", "development"):
            return self._no("target", "Only an installed application's or a development database is cloned.")
        if source and (p.target or {}).get("grants_state") not in ("in_place", "partial"):
            return self._no("grants", "The owner has not granted this database to the tool yet.")
        wb = workbench.create(self.cfg, template=self.cfg.template if req.get("template", True) else None)
        out = {"status": "ok", **wb}
        if source:
            out["clone"] = clone_mod.schema_clone(self.cfg, source_db=source, target_db=wb["name"], target_role=wb["role"])
        return out

    def _wb_drop(self, req):
        p = self._policy(req)
        wb = p.workbench or {}
        if not p.ok or (p.target or {}).get("class") != "workbench":
            return self._no("target", "That is not a workbench.")
        if wb.get("owner_member_id") != p.caller.get("member_id") and not p.caller.get("is_super_admin"):
            return self._no("owner", "This workbench is someone else's.")
        workbench.drop(self.cfg, req["datname"])
        return {"status": "ok"}

    def _wb_reset(self, req):
        p = self._policy(req)
        if not p.ok or (p.target or {}).get("class") != "workbench":
            return self._no("target", "That is not a workbench.")
        if not p.caller.get("is_super_admin") or p.is_agent:
            return self._no("right", "Resetting a workbench's credential is a super-admin's.")
        workbench.reset_credential(self.cfg, req["datname"])
        return {"status": "ok"}

    def _rehearse(self, req):
        if req.get("is_eval"):
            return self._no("eval", "An evaluation run changes nothing — not even a throwaway copy.")
        p = self._policy(req)
        if not p.ok or p.frozen:
            return self._no("policy", (p.refusal or {}).get("message") or "Not allowed.")
        if not p.has("changes.prepare"):
            return self._no("right", "Preparing changes is an Engineer's.")
        if (p.target or {}).get("class") not in ("application", "development") or \
                (p.target or {}).get("grants_state") not in ("in_place", "partial"):
            return self._no("target", "Rehearsals copy an installed application's or a development database the owner granted.")
        stmts = [s for s in (req.get("statements") or []) if isinstance(s, str) and s.strip()]
        if not stmts or len(stmts) > 200:
            return self._no("bad_request", "A rehearsal takes 1 to 200 statements.")
        return rehearse.rehearse(self.cfg, source_db=req["datname"], statements=stmts, template=req.get("template", True))


def ask(path: str, key: bytes, req: dict, timeout: float = 120.0) -> dict:
    """A client for proofs and for the PHP side's reference: sign, send one line, read one line."""
    req = dict(req)
    req.setdefault("ts", time.time())
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(path)
    try:
        s.sendall((json.dumps(sign(key, req), separators=(",", ":")) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
        return json.loads(buf.decode()) if buf else {}
    finally:
        s.close()


def main() -> int:  # pragma: no cover - the unit's entry point
    from door.policy import SqlPolicies
    cfg = connections.Config.from_env()
    with open(os.environ["DX_DOOR_KEY_FILE"], "rb") as f:
        key = f.read().strip()
    uids = set()
    for u in [u for u in os.environ.get("DX_DOOR_ALLOWED_USERS", "developer-web,developer-mcp").split(",") if u]:
        try:
            uids.add(pwd.getpwnam(u).pw_uid)
        except KeyError:
            pass
    policies = SqlPolicies(lambda: connections.connect(cfg, "meta", cfg.own_db, app="developer:door"))
    srv = DoorServer(os.environ.get("DX_DOOR_SOCKET"), cfg, policies, key, uids, group=os.environ.get("DX_DOOR_GROUP"),
                     listening=systemd_socket())
    srv.serve_forever()
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
