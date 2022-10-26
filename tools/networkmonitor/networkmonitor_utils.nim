proc flatten*[T](a: seq[seq[T]]): seq[T] =
  result = @[]
  for subseq in a:
    result &= subseq