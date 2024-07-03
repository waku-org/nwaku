{.push raises: [].}

import confutils/defs as confutilsDefs
import ../../envvar_serialization

export envvar_serialization, confutilsDefs

template readConfutilsType(T: type) =
  template readValue*(r: var EnvvarReader, value: var T) =
    value = T r.readValue(string)

readConfutilsType InputFile
readConfutilsType InputDir
readConfutilsType OutPath
readConfutilsType OutDir
readConfutilsType OutFile
