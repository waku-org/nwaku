when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import ./sqlite_driver/sqlite_driver

export sqlite_driver
