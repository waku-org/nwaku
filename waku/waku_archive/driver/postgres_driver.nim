when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  ./postgres_driver/postgres_driver,
  ./postgres_driver/postgres_driver_legacy,
  ./postgres_driver/partitions_manager,
  ./postgres_driver/postgres_healthcheck

export postgres_driver, postgres_driver_legacy, partitions_manager, postgres_healthcheck
