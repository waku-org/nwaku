import stew/results

type DatabaseResult*[T] = Result[T, string]
