when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  ./queue_store/index,
  ./queue_store/queue_store

export 
  queue_store,
  index
