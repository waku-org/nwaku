import chronos

template assertResultOk*[T, E](result: Result[T, E]) =
  assert result.isOk(), $result.error()

template assertResultOk*(result: Result[void, string]) =
  assert result.isOk(), $result.error()

template typeEq*(t: typedesc, u: typedesc): bool =
  # <a is b> is also true if a is subtype of b
  t is u and u is t # Only true if actually equal types

template typeEq*(t: auto, u: typedesc): bool =
  typeEq(type(t), u)
