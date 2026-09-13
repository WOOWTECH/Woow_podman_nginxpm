#!/usr/bin/env bash
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
source "$ROOT/tests/testlib.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
DB="$TMP/database.sqlite"
python3 - "$DB" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
c.execute('CREATE TABLE "user" (id INTEGER PRIMARY KEY)')
c.execute('CREATE TABLE "auth" (id INTEGER PRIMARY KEY)')
c.commit(); c.close()
PY
chmod 600 "$DB"
assert_success 'read-only checker proves zero user and auth rows' python3 "$ROOT/scripts/lib/check_empty_db.py" "$DB"
python3 - "$DB" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); c.execute('INSERT INTO "user" DEFAULT VALUES'); c.commit(); c.close()
PY
assert_failure 'read-only checker rejects a database containing a user' python3 "$ROOT/scripts/lib/check_empty_db.py" "$DB"
python3 - "$DB" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); c.execute('DELETE FROM "user"'); c.execute('INSERT INTO "auth" DEFAULT VALUES'); c.commit(); c.close()
PY
assert_failure 'read-only checker rejects a database containing auth' python3 "$ROOT/scripts/lib/check_empty_db.py" "$DB"
rm -f "$DB"; printf 'not sqlite' >"$DB"; chmod 600 "$DB"
assert_failure 'empty proof fails closed for an invalid database' python3 "$ROOT/scripts/lib/check_empty_db.py" "$DB"
rm -f "$DB"; assert_failure 'empty proof fails closed for a missing database' python3 "$ROOT/scripts/lib/check_empty_db.py" "$DB"
mkdir "$TMP/target"; ln -s target "$DB"
assert_failure 'empty proof rejects a symlink' python3 "$ROOT/scripts/lib/check_empty_db.py" "$DB"
finish
