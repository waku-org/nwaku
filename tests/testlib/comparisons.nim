template chainedComparison*(a: untyped, b: untyped, c: untyped): bool =
  a == b and b == c
