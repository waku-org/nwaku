proc toString*(bytes: seq[byte]): string =
  cast[string](bytes)

proc toBytes*(str: string): seq[byte] =
  cast[seq[byte]](str)
