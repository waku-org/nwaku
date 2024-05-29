when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import ./queue_driver/queue_driver, ./queue_driver/index

export queue_driver, index
