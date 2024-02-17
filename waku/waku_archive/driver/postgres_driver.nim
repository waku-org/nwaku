when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  ./postgres_driver/postgres_driver,
  ./postgres_driver/partitions_manager

export
  postgres_driver,
  partitions_manager
