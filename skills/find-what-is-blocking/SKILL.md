---
name: find-what-is-blocking
description: Runbook for "something is stuck" — find the root blocker in the lock graph, say what it is doing and for how long, and hand the decision to cancel or terminate to a DBA. Use when a person reports a hang, when a DDL timed out on a lock, or when a dispatch says sessions are blocked.
kind: runbook
---
# Find what is blocking

**Reads**: `blockers`, `activity_now`, `locks`, `table_describe`. **Writes**: nothing (a note in your answer; the Advisor's dispatch
note). Cancelling and terminating are a DBA's — never yours, never "just this once".

1. `blockers` on the database named (or every registered one): each waiting session with the pids blocking it.
2. **Find the root**: follow `blocked_by` until a session that waits on no one. That is the root blocker; often one session blocks a
   chain (a DDL waiting for `ACCESS EXCLUSIVE` behind a long transaction, and every reader queued behind the DDL).
3. `activity_now` for the root: its state (`active`, `idle in transaction`, `idle in transaction (aborted)`), how long its transaction
   has been open (`xact_start`), how long its current statement has run, its wait event, its application name and role, and its query
   **normalized**. A session whose application name starts with `developer:` is the tool's own.
4. `locks` on the relation(s) involved: which lock mode the root holds and which the waiters want. Use the conflict rules: `ACCESS
   EXCLUSIVE` conflicts with everything; `SHARE` blocks writes; `ROW EXCLUSIVE` (writes) conflicts with `SHARE` and above.
5. **Say it in one paragraph**: "<pid> (<role>, <application>) has held a transaction open for 14 min, idle; it holds ROW EXCLUSIVE on
   gl.invoices. A DDL from <pid> waits for ACCESS EXCLUSIVE behind it, and 6 sessions wait behind the DDL." Then the options:
   - the root's owner finishes or rolls back (best);
   - a DBA **cancels** the root's current statement (Activity screen, yellow) — useless for an idle-in-transaction session;
   - a DBA **terminates** the root's session (red) — rolls back its open work;
   - for a waiting DDL: cancel the DDL instead and retry later with a short `lock_timeout`.
6. Limits to state honestly: a **superuser's** session cannot be cancelled by the tool (a DBA uses `psql` as `postgres`); sessions on
   the kernel's and the memory databases are shown, never signalled by the tool.

**Never** guess what a session's transaction is doing beyond its normalized query, ask for the raw text, or recommend terminating a
session you cannot identify.
