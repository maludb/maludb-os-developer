-- What the door proof may have left behind (run as postgres): scratch databases and roles named dx*. Empty when the proof cleaned up.
SELECT 'db ' || datname FROM pg_database WHERE datname LIKE 'dx%'
UNION ALL
SELECT 'role ' || rolname FROM pg_roles WHERE rolname LIKE 'dx%';
