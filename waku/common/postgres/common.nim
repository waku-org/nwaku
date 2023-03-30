when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}


import stew/results

type PgResult*[T] = Result[T, string]
