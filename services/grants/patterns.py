"""The built-in SECRET name patterns (design §6.9). The grants service never grants a column whose name matches, unless a super-admin
cleared that column in the tool — independently of the classification plan, so a forged or stale plan cannot open a password hash.
The tool's classifier (PHP, Phase 3 slice 1) proposes from the same list; keep the two in step (one list, tests/door asserts this file).
"""
from __future__ import annotations

import re

SECRET_PATTERNS = [
    r"password", r"passwd", r"pass_?hash", r"secret", r"api_?key", r"private_?key", r"ciphertext", r"_encrypted$", r"^encrypted_",
    r"token_?hash", r"^token$", r"_token$", r"access_?token", r"refresh_?token", r"session_?key", r"signing_?key", r"^salt$", r"pepper",
    r"totp", r"otp_?secret", r"recovery_?code",
]
_RE = re.compile("|".join(f"(?:{p})" for p in SECRET_PATTERNS), re.I)


def is_secret_name(column: str) -> bool:
    return bool(_RE.search(column or ""))
