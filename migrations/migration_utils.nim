import
  std/strutils

proc breakIntoStatements*(script: string): seq[string] =
  ## Given a full migration script, that can potentially contain a list
  ## of SQL statements, this proc splits it into the contained isolated statements
  ## that should be executed one after the other.
  var statements = newSeq[string]()

  let lines = script.split('\n')

  var simpleStmt: string
  var plSqlStatement: string
  var insidePlSqlScript = false
  for line in lines:
    if line.strip().len == 0:
      continue

    if insidePlSqlScript:
      if line.contains("END $$"):
        ## End of the Pl/SQL script
        plSqlStatement &= line
        statements.add(plSqlStatement)
        plSqlStatement = ""
        insidePlSqlScript = false
        continue

      else:
        plSqlStatement &= line & "\n"

    if line.contains("DO $$"):
      ## Beginning of the Pl/SQL script
      insidePlSqlScript = true
      plSqlStatement &= line & "\n"

    if not insidePlSqlScript:
      simpleStmt &= line & "\n"

      if line.contains(';'):
        ## End of simple statement
        statements.add(simpleStmt)
        simpleStmt = ""

  return statements

