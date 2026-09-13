#!/usr/bin/env python3
"""Prove that an NPM SQLite database has no user or authentication rows."""
from __future__ import annotations

import os
import sqlite3
import stat
import sys
import urllib.parse


def main() -> int:
    if len(sys.argv) != 2:
        return 2
    path = os.path.abspath(sys.argv[1])
    try:
        info = os.lstat(path)
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            return 1
        uri = "file:" + urllib.parse.quote(path, safe="/") + "?mode=ro"
        connection = sqlite3.connect(uri, uri=True, timeout=5)
        try:
            connection.execute("PRAGMA query_only = ON")
            users = connection.execute('SELECT COUNT(*) FROM "user"').fetchone()
            auth = connection.execute('SELECT COUNT(*) FROM "auth"').fetchone()
        finally:
            connection.close()
    except (OSError, sqlite3.Error, TypeError):
        return 1
    if users != (0,) or auth != (0,):
        return 1
    print("EMPTY")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
