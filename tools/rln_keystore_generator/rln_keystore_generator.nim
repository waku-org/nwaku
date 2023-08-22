when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  chronicles,
  stew/[results]

import
    ./external_config

logScope:
  topics = "rln_keystore_generator"

when isMainModule:
  {.pop.}
  let confRes = RlnKeystoreGeneratorConf.loadConfig()
  if confRes.isErr():
    error "failure while loading the configuration", error=confRes.error()
    quit(1)

  let conf = confRes.get()
  
  debug "configuration", conf = $conf

  # initialize keystore
  


