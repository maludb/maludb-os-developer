<?php
declare(strict_types=1);

/**
 * Developer's worker — one pass a minute from developer-worker.timer (design §6.2, §6.5–§6.7, §14). It never opens a connection to a
 * target database: every read of one (discovery, the catalog index, a snapshot, a maintenance job, an export) is a request to the door
 * (services/door/, the only holder of the tool's database credentials). The worker keeps the application's own housekeeping —
 * discovery and the grants state, the catalog index, the nightly snapshots and drift, the applied-draft check, window expiry,
 * workbench quotas and expiry, maintenance and export jobs, the notification outbox (in-app, mail, K6 texts), the DBA Advisor's
 * inputs, retention, key-usage pruning. Idempotent; advisory-locked so two runs never overlap; each pass its own try (one failing never
 * stops the next); the report is printed as one JSON line, logged once as `worker.pass` (counts and sentences, never SQL text, a value,
 * a token or a key) and kept as a worker_passes row when the table exists (db/006+, Spaces' shape).
 *   php bin/worker.php [--passes=a,b] [--limit=200]
 * With --passes the named passes run whether or not they are due; without it every pass runs. DX_WORKER_NOW (ISO 8601) replaces the clock
 * a pass selects by; honoured only when APP_ENV is not prod. Exits 1 when a pass failed.
 *
 * PHASE 0: every pass but `key_usage_prune` is a STUB that changes nothing and answers 0 — the slice whose data it touches fills it in
 * (design §10): `discovery`, `catalog_index` slice 1's; `workbench_expiry`, `applied_drafts` slice 4's; `window_expiry`, `undo_prune`
 * slice 5's; `maintenance_jobs` slice 7's; `snapshots` slice 8's; `export_jobs`, `notify_outbox`, `advisor_inputs`, `retention` slice
 * 10's. Each stub names its slice. REAL from the kit: `key_usage_prune` (dx_prune_key_usage, db/005).
 */
if (PHP_SAPI !== 'cli') { fwrite(STDERR, "CLI only.\n"); exit(1); }
require_once dirname(__DIR__) . '/app/bootstrap.php';

/** The passes, in the order they run. A new pass is a name here and a function worker_pass_<name>(PDO, int $limit, DateTimeImmutable $now): array. */
const WORKER_PASSES = ['discovery', 'catalog_index', 'window_expiry', 'workbench_expiry', 'applied_drafts', 'maintenance_jobs', 'export_jobs',
    'snapshots', 'undo_prune', 'notify_outbox', 'advisor_inputs', 'retention', 'key_usage_prune'];

$only = [];
$limit = 200;
foreach (array_slice($argv, 1) as $a) {
    if (str_starts_with($a, '--passes=')) {
        $only = array_values(array_filter(explode(',', substr($a, 9))));
        if (array_diff($only, WORKER_PASSES) !== []) {
            fwrite(STDERR, 'Unknown pass: ' . implode(', ', array_diff($only, WORKER_PASSES)) . '. Passes: ' . implode(', ', WORKER_PASSES) . ".\n");
            exit(2);
        }
    } elseif (str_starts_with($a, '--limit=')) {
        $limit = max(1, min(1000, (int) substr($a, 8)));
    } else {
        fwrite(STDERR, "Usage: php bin/worker.php [--passes=a,b] [--limit=N]\n");
        exit(2);
    }
}
$now = new DateTimeImmutable();
if (($fake = getenv('DX_WORKER_NOW')) !== false && $fake !== '' && app_is_prod() === false) {
    $now = new DateTimeImmutable($fake);
}
$pdo = db();
if (!(bool) $pdo->query("SELECT pg_try_advisory_lock(hashtext('developer_worker'))")->fetchColumn()) {
    echo json_encode(['skipped' => 'another pass holds the lock']) . "\n";
    exit(0);
}
$GLOBALS['__public_door'] = 'cron';                 // every row a pass writes is source cron, actor none
$started = microtime(true);
$report = ['at' => $now->format(DATE_ATOM), 'ran' => [], 'errors' => []];
foreach ($only === [] ? WORKER_PASSES : $only as $pass) {
    try {
        $report['ran'][$pass] = ('worker_pass_' . $pass)($pdo, $limit, $now);
    } catch (Throwable $e) {
        error_log('worker ' . $pass . ': ' . $e->getMessage());
        $report['errors'][] = $pass . ': ' . mb_substr($e->getMessage(), 0, 200);
    }
}
$report['seconds'] = round(microtime(true) - $started, 2);
log_activity($pdo, 'worker.pass', null, null, ['source' => 'cron', 'actor_member_id' => null, 'after' => $report]);
try {
    if ($pdo->query("SELECT to_regclass('public.worker_passes') IS NOT NULL")->fetchColumn()) {
        $pdo->prepare('INSERT INTO worker_passes (started_at, finished_at, steps, error) VALUES (:s, now(), :steps, :err)')
            ->execute(['s' => date(DATE_ATOM, (int) $started), 'steps' => json_encode($report['ran'], JSON_UNESCAPED_SLASHES),
                       'err' => $report['errors'] === [] ? null : implode('; ', $report['errors'])]);
    }
} catch (Throwable $e) {
    error_log('worker_passes: ' . $e->getMessage());
}
echo json_encode($report, JSON_UNESCAPED_SLASHES) . "\n";
$pdo->query("SELECT pg_advisory_unlock(hashtext('developer_worker'))");
exit($report['errors'] === [] ? 0 : 1);

// ---- the passes (stubs until their slice) ------------------------------------------------------------------------------------------

/** SLICE 1 — discovery: the cluster's pg_database read through the door; a new database appears unclassified with a proposal (design §6.2's precedence); grants_state read per target; a dropped database marked gone. */
function worker_pass_discovery(PDO $pdo, int $limit, DateTimeImmutable $now): array { return ['seen' => 0, 'stub' => 'slice 1']; }
/** SLICE 1 — the catalog index: a registered target every 10 minutes (or asked from its page), objects and columns through the door's named query; the classifier's proposals with it (design §6.9). */
function worker_pass_catalog_index(PDO $pdo, int $limit, DateTimeImmutable $now): array { return ['indexed' => 0, 'stub' => 'slice 1']; }
/** SLICE 5 — windows past expires_at: ended (ended_by expired), logged window.end, the person told. */
function worker_pass_window_expiry(PDO $pdo, int $limit, DateTimeImmutable $now): array { return ['ended' => 0, 'stub' => 'slice 5']; }
/** SLICE 4 — workbenches: warned before expiry, dropped at it (the door's composed lifecycle); a workbench over its quota has its CONNECT suspended; rehearsal clones older than an hour dropped. */
function worker_pass_workbench_expiry(PDO $pdo, int $limit, DateTimeImmutable $now): array { return ['dropped' => 0, 'stub' => 'slice 4']; }
/** SLICE 4 — migration drafts observed applied: the objects a draft creates or alters appear in the latest snapshot with the rehearsal's DDL. */
function worker_pass_applied_drafts(PDO $pdo, int $limit, DateTimeImmutable $now): array { return ['observed' => 0, 'stub' => 'slice 4']; }
/** SLICE 7 — maintenance jobs: VACUUM, ANALYZE, REINDEX CONCURRENTLY, REFRESH … CONCURRENTLY run through the door (its ops tier), progress from pg_stat_progress_*. */
function worker_pass_maintenance_jobs(PDO $pdo, int $limit, DateTimeImmutable $now): array { return ['ran' => 0, 'stub' => 'slice 7']; }
/** SLICE 10 — export jobs: COPY … TO STDOUT through the door at the maker's level, formula injection neutralised, the file kept export_keep_hours. */
function worker_pass_export_jobs(PDO $pdo, int $limit, DateTimeImmutable $now): array { return ['made' => 0, 'stub' => 'slice 10']; }
/** SLICE 8 — nightly snapshots of application, kernel and own targets (normalized DDL per object); drift: each change attributed or marked unexplained. */
function worker_pass_snapshots(PDO $pdo, int $limit, DateTimeImmutable $now): array { return ['taken' => 0, 'stub' => 'slice 8']; }
/** SLICE 5 — before-images older than undo_days dropped (the undo window closed). */
function worker_pass_undo_prune(PDO $pdo, int $limit, DateTimeImmutable $now): array { return ['pruned' => 0, 'stub' => 'slice 5']; }
/** SLICE 10 — notification_outbox: queued email (MaluMail's REST send) and text (K6) rows sent, failed ones retried with backoff. */
function worker_pass_notify_outbox(PDO $pdo, int $limit, DateTimeImmutable $now): array { return ['sent' => 0, 'stub' => 'slice 10']; }
/** SLICE 10 — the DBA Advisor's inputs at advisor_note_at on weekdays: health findings, top statements, drift, drafts not applied, workbenches near expiry, windows used — counts and names of objects, never a row. */
function worker_pass_advisor_inputs(PDO $pdo, int $limit, DateTimeImmutable $now): array { return ['cut' => 0, 'stub' => 'slice 10']; }
/** SLICE 10 — retention: query_runs.sql nulled after sql_text_days, query_runs and door_statements past audit_keep_days removed, snapshot DDL text past snapshot_ddl_days, export files past export_keep_hours. */
function worker_pass_retention(PDO $pdo, int $limit, DateTimeImmutable $now): array { return ['pruned' => 0, 'stub' => 'slice 10']; }
/** dx_prune_key_usage() (db/005): minute buckets older than a day, day buckets older than 35 days. Real from the kit. */
function worker_pass_key_usage_prune(PDO $pdo, int $limit, DateTimeImmutable $now): array
{
    return ['pruned' => (int) one_value($pdo, 'SELECT dx_prune_key_usage()')];
}
