{.used.}

import
  std/unittest, tables,strutils, os,
  chronicles,
  stew/results,
  ../../waku/v2/node/storage/migration/[migration_types, migration_utils]

template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]
const MIGRATION_PATH = sourceDir / "../../waku/v2/node/storage/migration/migrations_scripts/message"

suite "Migration utils":
  test "read migration scripts":
    let migrationScriptsRes = getMigrationScripts(MIGRATION_PATH)
    check:
      migrationScriptsRes.isErr == false
      len((migrationScriptsRes.value).migrationUp) == 1
  test "filter migration scripts":
    let migrationScripts = getMigrationScripts(MIGRATION_PATH)
    let scripts = filterMigrationScripts(migrationScripts.value, 0)
    check:
      scripts.len == 1
  test "split scripts with multiple queries":
    let script = "; ;"
    let queries = splitScript(script)
    check queries.len == 0
  test "split scripts with no queries":
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