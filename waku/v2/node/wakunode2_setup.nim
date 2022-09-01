{.push raises: [Defect].}

import stew/results

type SetupResult*[T] = Result[T, cstring]
