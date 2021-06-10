import tables, stew/results

type MigrationScriptsResult*[T] = Result[T, string]
type
  MigrationScripts* = ref object of RootObj
    migrationUp*:OrderedTable[string, string]
    migrationDown*:OrderedTable[string, string]