when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import ./sqlite_store/sqlite_store

export sqlite_store