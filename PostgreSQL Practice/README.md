# Practice: PostgreSQL — Backups and Access Control

All commands are run via [Runme.dev](https://runme.dev) (the ▶ button next to each block) or manually from the project directory.
Session logs go to `logs/`, SQL scripts to `sql/`, backups to `backups/`.

> The `crew` table and the data below are a custom variant (the DDL/DML from the lesson was not provided). If needed, substitute your own definitions in the `sql/*.sql` blocks.

## 0. Preparation

Create the project directory structure:

```sh {"name":"prep-dirs"}
mkdir -p sql backups logs
ls -la
```

Refresh the package index:

```sh {"name":"prep-apt"}
sudo apt update
```

---

## 1. Installation

Install the server and the client:

```sh {"name":"pg-install"}
sudo apt install -y postgresql postgresql-client
```

Check that the service is running, and print the version:

```sh {"name":"pg-status"}
systemctl status postgresql --no-pager
psql --version
```

## 2. Create the database

```sh {"name":"pg-createdb"}
sudo -u postgres createdb nst_station
sudo -u postgres psql -l | grep nst_station
```

## 3. SQL scripts (DDL / DML / SELECT with JOIN)

DDL — tables `ships` and `crew` (linked via `ship_id`):

```sh {"name":"pg-write-ddl"}
cat > sql/pg_01_ddl.sql <<'EOF'
DROP TABLE IF EXISTS crew;
DROP TABLE IF EXISTS ships;

CREATE TABLE ships (
    id    SERIAL PRIMARY KEY,
    name  VARCHAR(50) NOT NULL UNIQUE,
    class VARCHAR(30)
);

CREATE TABLE crew (
    id        SERIAL PRIMARY KEY,
    full_name VARCHAR(80) NOT NULL,
    rank      VARCHAR(30) NOT NULL,
    ship_id   INTEGER REFERENCES ships(id),
    hired_at  DATE DEFAULT CURRENT_DATE
);
EOF
```

DML — 2 ships and 10 crew members (10 INSERTs into `crew`):

```sh {"name":"pg-write-dml"}
cat > sql/pg_02_dml.sql <<'EOF'
INSERT INTO ships (name, class) VALUES
    ('Aurora', 'Cruiser'),
    ('Nostromo', 'Freighter');

INSERT INTO crew (full_name, rank, ship_id) VALUES ('Ivan Petrov',    'Captain',   1);
INSERT INTO crew (full_name, rank, ship_id) VALUES ('Anna Smirnova',  'Pilot',     1);
INSERT INTO crew (full_name, rank, ship_id) VALUES ('Oleg Sidorov',   'Engineer',  1);
INSERT INTO crew (full_name, rank, ship_id) VALUES ('Maria Volkova',  'Medic',     1);
INSERT INTO crew (full_name, rank, ship_id) VALUES ('Denis Kuznetsov','Navigator', 1);
INSERT INTO crew (full_name, rank, ship_id) VALUES ('Ellen Ripley',   'Officer',   2);
INSERT INTO crew (full_name, rank, ship_id) VALUES ('Arthur Dallas',  'Captain',   2);
INSERT INTO crew (full_name, rank, ship_id) VALUES ('Joan Lambert',   'Navigator', 2);
INSERT INTO crew (full_name, rank, ship_id) VALUES ('Dennis Parker',  'Engineer',  2);
INSERT INTO crew (full_name, rank, ship_id) VALUES ('Samuel Brett',   'Engineer',  2);
EOF
```

SELECT with JOIN:

```sh {"name":"pg-write-select"}
cat > sql/pg_03_select_join.sql <<'EOF'
SELECT c.id, c.full_name, c.rank, s.name AS ship, s.class
FROM crew c
JOIN ships s ON s.id = c.ship_id
ORDER BY s.name, c.id;

SELECT s.name AS ship, COUNT(*) AS crew_count
FROM ships s
JOIN crew c ON c.ship_id = s.id
GROUP BY s.name;
EOF
```

## 4. Run the scripts

Files are fed in via `<` so the `postgres` user does not need access to the home directory. Output is saved to a log.

```sh {"name":"pg-run-ddl-dml"}
{
  sudo -u postgres psql -d nst_station -e < sql/pg_01_ddl.sql
  sudo -u postgres psql -d nst_station -e < sql/pg_02_dml.sql
} 2>&1 | tee logs/pg_ddl_dml.log
```

```sh {"name":"pg-run-select"}
sudo -u postgres psql -d nst_station -e < sql/pg_03_select_join.sql 2>&1 | tee logs/pg_select_join.log
```

## 5. Backups

Plain-text SQL dump (`backup.sql`):

```sh {"name":"pg-dump-sql"}
sudo -u postgres pg_dump nst_station > backups/pg_backup.sql
ls -lh backups/pg_backup.sql
```

Custom-format dump (required for `pg_restore`):

```sh {"name":"pg-dump-custom"}
sudo -u postgres pg_dump -Fc nst_station > backups/pg_backup.dump
ls -lh backups/pg_backup.dump
```

## 6. Restore

Restore the custom-format dump into a new database `nst_station_restore` (with a log):

```sh {"name":"pg-restore"}
sudo -u postgres dropdb --if-exists nst_station_restore
sudo -u postgres createdb nst_station_restore
sudo -u postgres pg_restore -v -d nst_station_restore < backups/pg_backup.dump 2>&1 | tee logs/pg_restore.log
```

Alternative — restore the plain-text SQL dump via psql:

```sh {"name":"pg-restore-sql"}
sudo -u postgres dropdb --if-exists nst_station_restore_sql
sudo -u postgres createdb nst_station_restore_sql
sudo -u postgres psql -d nst_station_restore_sql < backups/pg_backup.sql 2>&1 | tee logs/pg_restore_sql.log
```

Verify that the restored databases match the original:

```sh {"name":"pg-verify-restore"}
for db in nst_station nst_station_restore nst_station_restore_sql; do
  echo -n "$db: "
  sudo -u postgres psql -At -d "$db" -c "SELECT COUNT(*) FROM crew;"
done 2>&1 | tee logs/pg_verify_restore.log
```

## 7. User `tadmin` and privileges

Create the user, grant SELECT/INSERT (plus DELETE for demonstration purposes), then revoke DELETE:

```sh {"name":"pg-write-roles"}
cat > sql/pg_04_roles.sql <<'EOF'
DROP OWNED BY tadmin;
DROP ROLE IF EXISTS tadmin;
CREATE USER tadmin WITH PASSWORD '<tadmin-password>';

GRANT CONNECT ON DATABASE nst_station TO tadmin;
GRANT USAGE ON SCHEMA public TO tadmin;
GRANT SELECT, INSERT, DELETE ON ALL TABLES IN SCHEMA public TO tadmin;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO tadmin;   -- required for INSERT into SERIAL columns

REVOKE DELETE ON ALL TABLES IN SCHEMA public FROM tadmin;
EOF
```

If the role does not exist yet, `DROP OWNED BY` prints an error — harmless on the first run (psql continues after errors by default). Apply:

```sh {"name":"pg-apply-roles"}
sudo -u postgres psql -d nst_station -e < sql/pg_04_roles.sql 2>&1 | tee logs/pg_roles.log
```

Show the granted privileges (`\dp`) and roles (`\du`):

```sh {"name":"pg-show-grants"}
sudo -u postgres psql -d nst_station -c '\dp crew' -c '\dp ships' -c '\du tadmin'
```

## 8. Test `tadmin` privileges

SELECT and INSERT must succeed; DELETE must fail with `permission denied`:

```sh {"name":"pg-test-tadmin"}
export PGPASSWORD='<tadmin-password>'
{
  echo "--- SELECT (expected: OK)";
  psql -h localhost -U tadmin -d nst_station -c "SELECT COUNT(*) FROM crew;"
  echo "--- INSERT (expected: OK)";
  psql -h localhost -U tadmin -d nst_station -c "INSERT INTO crew (full_name, rank, ship_id) VALUES ('Test User','Cadet',1);"
  echo "--- DELETE (expected: permission denied)";
  psql -h localhost -U tadmin -d nst_station -c "DELETE FROM crew WHERE full_name='Test User';"
  echo "--- DROP TABLE (expected: must be owner)";
  psql -h localhost -U tadmin -d nst_station -c "DROP TABLE crew;"
} 2>&1 | tee logs/pg_tadmin_test.log
unset PGPASSWORD
```

## 9. Test on a corrupted database

First take a fresh backup, then simulate corruption (data damage and a dropped table), run queries against the "broken" database, and restore.

Fresh backup before the incident:

```sh {"name":"pg-corrupt-backup"}
sudo -u postgres pg_dump -Fc nst_station > backups/pg_before_corruption.dump
```

Simulate corruption:

```sh {"name":"pg-corrupt"}
{
  sudo -u postgres psql -d nst_station -c "UPDATE crew SET full_name = 'CORRUPTED', rank = '???';"
  sudo -u postgres psql -d nst_station -c "DROP TABLE ships CASCADE;"
} 2>&1 | tee logs/pg_corruption.log
```

Queries against the corrupted database (expect garbage data and the error `relation "ships" does not exist`):

```sh {"name":"pg-corrupt-queries"}
{
  sudo -u postgres psql -d nst_station -c "SELECT * FROM crew LIMIT 3;"
  sudo -u postgres psql -d nst_station -c "SELECT c.full_name, s.name FROM crew c JOIN ships s ON s.id = c.ship_id;"
} 2>&1 | tee logs/pg_corrupt_queries.log
```

Restore over the corrupted database (`--clean --if-exists`) and verify:

```sh {"name":"pg-recover"}
{
  sudo -u postgres pg_restore -v --clean --if-exists -d nst_station < backups/pg_before_corruption.dump
  sudo -u postgres psql -d nst_station < sql/pg_03_select_join.sql
} 2>&1 | tee logs/pg_recover.log
```

## 10. Cleanup (optional)

Drop the test restore databases:

```sh {"name":"cleanup"}
sudo -u postgres dropdb --if-exists nst_station_restore
sudo -u postgres dropdb --if-exists nst_station_restore_sql
```

## 11. Shutdown and removal

Stop PostgreSQL completely and disable autostart:

```sh {"name":"pg-stop"}
sudo systemctl stop postgresql
sudo systemctl disable postgresql
systemctl status postgresql --no-pager || true
```

Optional: uninstall PostgreSQL. **Destructive** — `purge` also deletes all databases, configs and data (`/var/lib/postgresql`, `/etc/postgresql`). Make sure the backups in `backups/` are kept (or copied to the host) first:

```sh {"name":"pg-purge"}
sudo apt purge -y 'postgresql*'
sudo apt autoremove -y
sudo rm -rf /var/lib/postgresql /etc/postgresql
dpkg -l | grep postgresql || echo "PostgreSQL removed"
```
