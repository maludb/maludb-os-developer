"""A small ctypes binding to libpg_query — the PostgreSQL parser as a library (BSD-3, design §6.1 step 2, D7).

    from door import pgquery
    tree = pgquery.parse("select 1")                 # the JSON parse tree as a dict: {"version": 170…, "stmts": [...]}
    parts = pgquery.split("select 1; select 2")      # [Part(text, start, length)] — split by the PARSER, not by `;`
    pgquery.normalize("select * from t where a = 'x'")  # 'select * from t where a = $1'
    pgquery.fingerprint("select 1")                  # '…16 hex…' (stable across literal values)

The library is built from a pinned release by deploy/build-libpg_query.sh into services/vendor/lib/libpg_query.so (DX_LIBPG_QUERY
overrides the path). Locations from libpg_query are BYTE offsets into the UTF-8 text; this module slices bytes and returns str.
libpg_query keeps its memory contexts per thread, so every call is safe from any thread. Every result is freed by the matching
pg_query_free_* call before this module returns.
"""
from __future__ import annotations

import ctypes
import json
import os
from dataclasses import dataclass

_HERE = os.path.dirname(os.path.abspath(__file__))
_DEFAULT_LIB = os.path.join(os.path.dirname(_HERE), "vendor", "lib", "libpg_query.so")


class PgQueryError(ctypes.Structure):
    _fields_ = [("message", ctypes.c_char_p), ("funcname", ctypes.c_char_p), ("filename", ctypes.c_char_p),
                ("lineno", ctypes.c_int), ("cursorpos", ctypes.c_int), ("context", ctypes.c_char_p)]


class _ParseResult(ctypes.Structure):
    _fields_ = [("parse_tree", ctypes.c_char_p), ("stderr_buffer", ctypes.c_char_p), ("error", ctypes.POINTER(PgQueryError))]


class _SplitStmt(ctypes.Structure):
    _fields_ = [("stmt_location", ctypes.c_int), ("stmt_len", ctypes.c_int)]


class _SplitResult(ctypes.Structure):
    _fields_ = [("stmts", ctypes.POINTER(ctypes.POINTER(_SplitStmt))), ("n_stmts", ctypes.c_int),
                ("stderr_buffer", ctypes.c_char_p), ("error", ctypes.POINTER(PgQueryError))]


class _FingerprintResult(ctypes.Structure):
    _fields_ = [("fingerprint", ctypes.c_uint64), ("fingerprint_str", ctypes.c_char_p), ("stderr_buffer", ctypes.c_char_p),
                ("error", ctypes.POINTER(PgQueryError))]


class _NormalizeResult(ctypes.Structure):
    _fields_ = [("normalized_query", ctypes.c_char_p), ("error", ctypes.POINTER(PgQueryError))]


class ParseError(Exception):
    """The parser refused the text. `position` is a 0-based CHARACTER offset into the text (converted from libpg_query's 1-based byte
    cursor), or None."""

    def __init__(self, message: str, position: int | None):
        super().__init__(message)
        self.message = message
        self.position = position


@dataclass(frozen=True)
class Part:
    text: str      # the statement, without the separating `;`, leading/trailing whitespace kept as the parser gave it
    start: int     # 0-based character offset of the statement in the original text
    length: int    # its length in characters


_lib = None


def _load():
    global _lib
    if _lib is not None:
        return _lib
    path = os.environ.get("DX_LIBPG_QUERY") or _DEFAULT_LIB
    if not os.path.exists(path):
        raise RuntimeError("libpg_query is not built — run deploy/build-libpg_query.sh")
    lib = ctypes.CDLL(path)
    lib.pg_query_parse.argtypes = [ctypes.c_char_p]
    lib.pg_query_parse.restype = _ParseResult
    lib.pg_query_free_parse_result.argtypes = [_ParseResult]
    lib.pg_query_free_parse_result.restype = None
    lib.pg_query_split_with_parser.argtypes = [ctypes.c_char_p]
    lib.pg_query_split_with_parser.restype = _SplitResult
    lib.pg_query_free_split_result.argtypes = [_SplitResult]
    lib.pg_query_free_split_result.restype = None
    lib.pg_query_fingerprint.argtypes = [ctypes.c_char_p]
    lib.pg_query_fingerprint.restype = _FingerprintResult
    lib.pg_query_free_fingerprint_result.argtypes = [_FingerprintResult]
    lib.pg_query_free_fingerprint_result.restype = None
    lib.pg_query_normalize.argtypes = [ctypes.c_char_p]
    lib.pg_query_normalize.restype = _NormalizeResult
    lib.pg_query_free_normalize_result.argtypes = [_NormalizeResult]
    lib.pg_query_free_normalize_result.restype = None
    _lib = lib
    return lib


def _raise(err_ptr, raw: bytes):
    err = err_ptr.contents
    msg = (err.message or b"").decode("utf-8", "replace")
    pos = None
    if err.cursorpos and err.cursorpos > 0:
        pos = len(raw[: err.cursorpos - 1].decode("utf-8", "replace"))
    raise ParseError(msg, pos)


def _encode(sql: str) -> bytes:
    if "\x00" in sql:
        raise ParseError("the text holds a NUL character", sql.index("\x00"))
    return sql.encode("utf-8")


def parse(sql: str) -> dict:
    """The parse tree of every statement in `sql`, as libpg_query's JSON (a dict)."""
    lib = _load()
    raw = _encode(sql)
    res = lib.pg_query_parse(raw)
    try:
        if res.error:
            _raise(res.error, raw)
        return json.loads(res.parse_tree.decode("utf-8"))
    finally:
        lib.pg_query_free_parse_result(res)


def split(sql: str) -> list[Part]:
    """The statements of a script, split by PostgreSQL's own parser (dollar quotes, E'' strings, quoted identifiers, nested comments and
    BEGIN ATOMIC bodies all handled). Empty statements are dropped. A script the parser refuses raises ParseError."""
    lib = _load()
    raw = _encode(sql)
    res = lib.pg_query_split_with_parser(raw)
    try:
        if res.error:
            _raise(res.error, raw)
        out: list[Part] = []
        for i in range(res.n_stmts):
            st = res.stmts[i].contents
            b = raw[st.stmt_location: st.stmt_location + st.stmt_len]
            text = b.decode("utf-8")
            if not text.strip():
                continue
            start = len(raw[: st.stmt_location].decode("utf-8"))
            out.append(Part(text=text, start=start, length=len(text)))
        return out
    finally:
        lib.pg_query_free_split_result(res)


def fingerprint(sql: str) -> str:
    lib = _load()
    raw = _encode(sql)
    res = lib.pg_query_fingerprint(raw)
    try:
        if res.error:
            _raise(res.error, raw)
        return res.fingerprint_str.decode("ascii")
    finally:
        lib.pg_query_free_fingerprint_result(res)


def normalize(sql: str) -> str:
    """Literals replaced by $n — the form other sessions' query texts are shown in (design §6.7). Raises ParseError on a text the
    parser refuses (a text cut by track_activity_query_size); callers show `<not normalisable>` then."""
    lib = _load()
    raw = _encode(sql)
    res = lib.pg_query_normalize(raw)
    try:
        if res.error:
            _raise(res.error, raw)
        return res.normalized_query.decode("utf-8")
    finally:
        lib.pg_query_free_normalize_result(res)


def server_version_num() -> int:
    """The grammar's PostgreSQL version (e.g. 170005 for the 17 line)."""
    return int(parse("select 1").get("version") or 0)
