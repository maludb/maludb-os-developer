---
name: weekday-dba-note
description: Runbook for the DBA Advisor's weekday duty (07:20) — read health, statements, drift, drafts, workbenches and windows across the registered databases, propose at most ten fixes as change sets, then write one note for the DBA role holders and send the Sysadmin agent the same summary. Run every weekday or when a DBA asks.
kind: runbook
---
# The weekday DBA note

**When**: weekdays 07:20 (the duty). **Writes**: `change_set_propose` (at most ten), the note (`dba_note_post`), `message_send` to the Sysadmin.
Nothing else. **Reads no rows.**

1. `find_databases` — the targets by class. List any whose grants are pending or partial (the owner runs `grant-target.sh`).
2. `advisor_proposals` — what you proposed in the last 30 days and what became of it. Do not propose again what a DBA discarded.
3. **Per application target**, `health_findings`, most severe first:
   - wraparound age past the warning threshold — first in the note, always;
   - sequences near their limit (name the sequence, its type and how far through it is);
   - invalid indexes (a failed `CONCURRENTLY`) and invalid constraints left `NOT VALID`;
   - unindexed foreign keys on tables over 10,000 rows;
   - missing primary keys;
   - duplicate and overlapping indexes; unused indexes over 100 MB (`idx_scan = 0` since statistics were reset — say since when);
   - `SECURITY DEFINER` functions without a fixed `search_path` or executable by `PUBLIC`;
   - RLS enabled with no policy;
   - sessions idle in transaction for over 10 minutes (from `activity_now`).
4. `top_statements` — the five largest by total time across the cluster (normalized); one line each with calls and mean time.
5. `bloat`, `vacuum_state` — tables whose estimated bloat is over 30 % and 1 GB, or not vacuumed or analyzed for 7 days with changes.
6. `schema_changes` since the last note — every **unexplained** change (not a change set, a draft or the grants service) is drift: the
   database, the object, the kind of change.
7. `find_migration_drafts` not observed applied after three days; `find_workbenches` expiring within two days; `find_change_sets`
   proposed and unreviewed for seven days.
8. **Proposals** (skill `safe-ddl`, runbook `draft-an-index`): for each finding with a structural fix — an index on an unindexed foreign
   key, a drop of an invalid index (`DROP INDEX CONCURRENTLY`), a `VALIDATE CONSTRAINT`, a primary key through a concurrent unique index
   — one `change_set_propose` with a one-sentence rationale from the statistics. At most ten; wraparound and sequences first. Findings
   with no structural fix (vacuum, terminate a session, a setting) go in the note as a recommendation for a DBA or the owner.
9. **The note**: a title with the date; then per database: findings (severity, object, one line), proposals made (linked), drift,
   expiring things. End with the five statements. Names and counts only — **never a value from a database**.
10. `message_send` the same summary to the kernel's Sysadmin agent, prefixed "Developer — DBA note".

If nothing is wrong, say so in one line per database — a quiet note is still a note.
