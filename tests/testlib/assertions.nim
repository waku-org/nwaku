import chronos

template assertResultOk*[T, E](result: Result[T, E]) =
  assert result.isOk(), $result.error()

template assertResultOk*(result: Result[void, string]) =
  assert result.isOk(), $result.error()
