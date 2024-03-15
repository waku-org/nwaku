import results

template assertResultOk*[T, E](result: Result[T, E]) =
  assert result.isOk(), result.error()
