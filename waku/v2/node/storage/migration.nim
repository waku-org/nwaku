
import
  stew/results,
  chronicles
import
  ./sqlite,
  ./migration/migration_types,
  ./migration/migration_utils

export
  migration_types,
  migration_utils


logScope:
  topics = "storage.migration"


const USER_VERSION* = 7 # increase this when there is an update in the database schema


proc migrate*(db: SqliteDatabase, path: string, targetVersion: int64 = USER_VERSION): DatabaseResult[void] = 
  ## Compares the user_version of the db with the targetVersion 
  ## runs migration scripts if the user_version is outdated (does not support down migration)
  ## path points to the directory holding the migrations scripts
  ## once the db is updated, it sets the user_version to the tragetVersion
  
  # read database version
  let userVersionRes = db.getUserVersion()
  if userVersionRes.isErr():
    debug "failed to get user_version", error=userVersionRes.error

  let userVersion = userVersionRes.value

  debug "current database user_version", userVersion=userVersion, targetVersion=targetVersion

  if userVersion == targetVersion:
    info "database is up to date"
    return ok()

  info "database user_version outdated. migrating.", userVersion=userVersion, targetVersion=targetVersion

  # fetch migration scripts
  let migrationScriptsRes = getScripts(path)
  if migrationScriptsRes.isErr():
    return err("failed to load migration scripts")

  let migrationScripts = migrationScriptsRes.value

  # filter scripts based on their versions
  let scriptsRes = migrationScripts.filterScripts(userVersion, targetVersion)
  if scriptsRes.isErr():
    return err("failed to filter migration scripts")
  
  let scripts = scriptsRes.value
  if scripts.len == 0:
    return err("no suitable migration scripts")
  
  trace "migration scripts", scripts=scripts
  
  
  # Run the migration scripts
  for script in scripts:

    for query in script.splitScript():
      debug "executing migration statement", statement=query

      let execRes = db.query(query, NoopRowHandler)
      if execRes.isErr():
        error "failed to execute migration statement", statement=query, error=execRes.error
        return err("failed to execute migration statement")

      debug "migration statement executed succesfully", statement=query
    
  # Update user_version
  let res = db.setUserVersion(targetVersion)
  if res.isErr():
    return err("failed to set the new user_version")

  debug "database user_version updated", userVersion=targetVersion
  ok()