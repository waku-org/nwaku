{.used.}

import
  std/[unittest, tables, strutils, os],
  chronicles,
  stew/results,
  ../../waku/v2/node/storage/migration/[migration_types, migration_utils]

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