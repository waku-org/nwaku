{.used.}

import
  std/unittest,
  chronicles,
  ../../waku/v2/node/storage/migration/[migration_types, migration_utils]
suite "Migration utils":
  test "read migration scripts":
    let migrationScripts = getMigrationScripts("/Users/sanaztaheri/GitHub/nim-waku-code/nim-waku/waku/v2/node/storage/migration/migrations_scripts/message")
    check:
      migrationScripts.migrationUp.len == 1
  test "filter migration scripts":
    let migrationScripts = getMigrationScripts("/Users/sanaztaheri/GitHub/nim-waku-code/nim-waku/waku/v2/node/storage/migration/migrations_scripts/message")
    let scripts = filterMigrationScripts(migrationScripts, 0)
    check:
      scripts.len == 1