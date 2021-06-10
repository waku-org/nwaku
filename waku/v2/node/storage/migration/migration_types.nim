import tables

type
  MigrationScripts* = ref object of RootObj
    migrationUp*:OrderedTable[string, string]
    migrationDown*:OrderedTable[string, string]