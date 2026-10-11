"""Execute (design §6.1 step 6): one statement per protocol message, as the tier the decision chose.

- psycopg 3 always uses the extended protocol, which refuses a string of several statements ("cannot insert multiple commands into a
  prepared statement") — one statement per message is enforced by the wire as well as by the splitter.
- The tier's settings are re-asserted BEFORE EACH statement (a person cannot SET them — classify refuses SET on read tiers — but a
  workbench's role can, and a function could): statement_timeout, lock_timeout, idle_in_transaction_session_timeout, transaction_timeout.
- Reads run inside BEGIN READ ONLY … COMMIT; a plain SELECT is fetched through a server-side cursor, capped by rows (+1 to know it was
  cut), bytes and cell length; every value is returned as PostgreSQL's own text (R30: numeric, jsonb and timestamps round-trip exactly),
  bytea as its size only.
- Notices are collected; an error answers its SQLSTATE, message, detail, hint and the character position inside the statement.
- `cancel()` from another thread sends libpq's cancel through psycopg's cancel_safe().
"""
from __future__ import annotations

import re
import threading
import time
from dataclasses import asdict, dataclass, field

import psycopg
import psycopg.postgres
from psycopg import pq
from psycopg.adapt import Loader


class RawText(Loader):
    def load(self, data):
        return bytes(data).decode("utf-8", "replace")


def text_everywhere(conn: psycopg.Connection) -> None:
    for t in psycopg.postgres.types:
        conn.adapters.register_loader(t.oid, RawText)
        if getattr(t, "array_oid", 0):
            conn.adapters.register_loader(t.array_oid, RawText)


BYTEA_OIDS = {17}


@dataclass
class StatementResult:
    index: int
    cls: str
    status: str = "ok"                       # ok | error | timeout | cancelled
    command: str | None = None
    columns: list = field(default_factory=list)
    rows: list = field(default_factory=list)
    truncated: bool = False
    cut_cells: int = 0
    rows_affected: int | None = None
    notices: list = field(default_factory=list)
    sqlstate: str | None = None
    message: str | None = None
    detail: str | None = None
    hint: str | None = None
    position: int | None = None              # 0-based character offset inside the statement
    ms: int = 0
    backend_pid: int | None = None

    def as_dict(self) -> dict:
        return asdict(self)


_QUOTED = re.compile(r'"[^"]*"')
_KEYVAL = re.compile(r"\(([^()]*)\)=\(([^()]*)\)")


def mask_message(msg: str | None) -> str | None:
    """The form an error is STORED in (design §6.10): quoted fragments and key values replaced — PostgreSQL puts values in messages."""
    if msg is None:
        return None
    m = _KEYVAL.sub(lambda x: f"({x.group(1)})=(•••)", msg)
    return _QUOTED.sub('"•••"', m)[:500]


class Runner:
    def __init__(self, conn: psycopg.Connection, settings: dict, limits: dict):
        self.conn = conn
        self.settings = settings
        self.limits = limits
        self._cancel_requested = False
        self._lock = threading.Lock()
        self.notices: list[str] = []
        conn.add_notice_handler(self._notice)
        text_everywhere(conn)

    def _notice(self, diag):
        if len(self.notices) < 50:
            self.notices.append((diag.message_primary or "")[:500])

    def cancel(self) -> None:
        with self._lock:
            self._cancel_requested = True
        try:
            self.conn.cancel_safe(timeout=5)
        except Exception:
            pass

    @property
    def tx_status(self):
        return self.conn.info.transaction_status

    def reassert(self) -> None:
        if self.tx_status == pq.TransactionStatus.INERROR:
            return
        s = self.settings
        self.conn.execute(
            "SELECT set_config('statement_timeout', %s, false), set_config('lock_timeout', %s, false),"
            " set_config('idle_in_transaction_session_timeout', %s, false), set_config('transaction_timeout', %s, false)",
            (f"{int(s['statement_timeout_ms'])}ms", f"{int(s['lock_timeout_ms'])}ms", f"{int(s['idle_in_tx_ms'])}ms",
             f"{int(s['transaction_timeout_ms'])}ms"))

    def _fetch(self, cur, res: StatementResult) -> None:
        show_rows = int(self.limits.get("show_rows", 1000))
        show_bytes = int(self.limits.get("show_bytes", 8 * 1024 * 1024))
        cell = int(self.limits.get("cell_chars", 2000))
        if cur.description is None:
            return
        res.columns = [{"name": d.name, "type_oid": d.type_code} for d in cur.description]
        binary_cols = {i for i, d in enumerate(cur.description) if d.type_code in BYTEA_OIDS}
        size = 0
        while True:
            batch = cur.fetchmany(min(200, show_rows + 1 - len(res.rows)) or 1)
            if not batch:
                break
            for row in batch:
                if len(res.rows) >= show_rows or size >= show_bytes:
                    res.truncated = True
                    return
                out = []
                for i, v in enumerate(row):
                    if v is None:
                        out.append(None)
                        continue
                    if i in binary_cols:
                        n = max(0, (len(v) - 2) // 2) if v.startswith("\\x") else len(v)
                        out.append({"binary_bytes": n})
                        size += 32
                        continue
                    if len(v) > cell:
                        out.append({"text": v[:cell], "full_length": len(v)})
                        res.cut_cells += 1
                        size += cell
                    else:
                        out.append(v)
                        size += len(v)
                res.rows.append(out)
            if len(res.rows) >= show_rows + 1:
                break

    def run(self, index: int, text: str, cls: str, *, wrap: str | None, cursorable: bool) -> StatementResult:
        res = StatementResult(index=index, cls=cls)
        self.notices = []
        t0 = time.monotonic()
        began = None
        conn = self.conn
        res.backend_pid = conn.info.backend_pid
        try:
            self.reassert()
            if wrap == "read_only" and self.tx_status == pq.TransactionStatus.IDLE:
                conn.execute("BEGIN READ ONLY")
                began = "commit"
            elif wrap == "rollback":
                if self.tx_status == pq.TransactionStatus.IDLE:
                    conn.execute("BEGIN")
                    began = "rollback"
                else:
                    conn.execute("SAVEPOINT dx_explain")
                    began = "rollback_to"
            if cursorable and self.tx_status != pq.TransactionStatus.IDLE:
                with conn.cursor(name=f"dx_c{index}") as cur:
                    cur.execute(text)
                    self._fetch(cur, res)
                    res.command = "SELECT"
            else:
                with conn.cursor() as cur:
                    cur.execute(text)
                    res.command = (cur.statusmessage or "").split(" ")[0] or None
                    if cur.description is not None:
                        self._fetch(cur, res)
                    elif cur.rowcount is not None and cur.rowcount >= 0:
                        res.rows_affected = cur.rowcount
            if began == "commit":
                conn.execute("COMMIT")
            elif began == "rollback":
                conn.execute("ROLLBACK")
            elif began == "rollback_to":
                conn.execute("ROLLBACK TO SAVEPOINT dx_explain")
        except psycopg.Error as e:
            d = e.diag
            res.sqlstate = d.sqlstate
            res.message = (d.message_primary or str(e))[:500]
            res.detail = (d.message_detail or None) and d.message_detail[:500]
            res.hint = (d.message_hint or None) and d.message_hint[:500]
            try:
                res.position = int(d.statement_position) - 1 if d.statement_position else None
            except (TypeError, ValueError):
                res.position = None
            if d.sqlstate == "57014":
                res.status = "cancelled" if self._cancel_requested else "timeout"
            else:
                res.status = "error"
            try:
                if began in ("commit", "rollback"):
                    conn.execute("ROLLBACK")
                elif began == "rollback_to":
                    conn.execute("ROLLBACK TO SAVEPOINT dx_explain")
            except psycopg.Error:
                pass
        res.notices = list(self.notices)
        res.ms = int((time.monotonic() - t0) * 1000)
        return res

    def finish(self) -> str | None:
        """At the end of a run: a transaction the person left open is rolled back, and said so (design §6.1 step 5)."""
        st = self.tx_status
        if st in (pq.TransactionStatus.INTRANS, pq.TransactionStatus.INERROR):
            try:
                self.conn.execute("ROLLBACK")
            except psycopg.Error:
                pass
            return "The run ended inside a transaction; it was rolled back."
        return None
