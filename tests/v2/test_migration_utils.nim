{.used.}

import
  std/[unittest, tables, strutils, os, sequtils],
  chronicles,
  stew/results,
  ../../waku/v2/node/storage/migration/migration_utils

template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]
const MIGRATION_PATH = sourceDir / "../../waku/v2/node/storage/migration/migrations_scripts/message"

suite "Migration utils":
  test "read migration scripts":
    let migrationScriptsRes = getScripts(MIGRATION_PATH)
    check:
      migrationScriptsRes.isErr == false

  test "filter migration scripts":
    let migrationUp = [("0001_init", "script1"), ("0001_add", "script1"), ("0002_init", "script2"), ("0003_init", "script3")].toOrderedTable()
    let migrationScripts = MigrationScripts(migrationUp: migrationUp)
    let scriptsRes = filterScripts(migrationScripts, 1, 3)
    check:
      scriptsRes.isErr == false
      scriptsRes.value.len == 2
      scriptsRes.value[0] == "script2"
      scriptsRes.value[1] == "script3"

  test "filter migration scripts with varying zero-prefixed user versions":
    let migrationUp = [("0001_init", "script1"), ("1_add", "script1"), ("000002_init", "script2"), ("003_init", "script3")].toOrderedTable()
    let migrationScripts = MigrationScripts(migrationUp: migrationUp)
    let scriptsRes = filterScripts(migrationScripts, 1, 3)
    check:
      scriptsRes.isErr == false
      scriptsRes.value.len == 2
      scriptsRes.value[0] == "script2"
      scriptsRes.value[1] == "script3"

  test "split scripts with no queries":
    let script = "; ;"
    let queries = splitScript(script)
    check queries.len == 0

  test "split scripts with multiple queries":
    let q1 = """CREATE TABLE contacts2 (
                contact_id INTEGER PRIMARY KEY,
                first_name TEXT NOT NULL,
                last_name TEXT NOT NULL,
                email TEXT NOT NULL UNIQUE,
                phone TEXT NOT NULL UNIQUE
                );"""
    let q2 = """CREATE TABLE contacts2 (
                contact_id INTEGER PRIMARY KEY,
                first_name TEXT NOT NULL,
                last_name TEXT NOT NULL,
                email TEXT NOT NULL UNIQUE,
                phone TEXT NOT NULL UNIQUE
                );"""
    let script = q1 & q2
    let queries = splitScript(script)
    check:
      queries.len == 2
      queries[0] == q1
      queries[1] == q2