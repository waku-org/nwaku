
import
  std/strutils,
  stew/results,
  regex

proc parseMsgSize*(input: string): Result[int, string] =
  ## Parses size strings such as "1.2 KiB" or "3Kb" and returns the equivalent number of bytes
  ## if the parse task goes well. If not, it returns an error describing the problem.

  const RegexDef = """\s*(\d+([\,\.]\d*)?)\s*([Kk]{0,1}[i]?[Bb]{1})"""
  const RegexParseSize = re2(RegexDef)

  var m: RegexMatch2
  if input.match(RegexParseSize, m) == false:
    return err("error in parseSize. regex is not matching: " & RegexDef)

  var value: float

  try:
    value = parseFloat(input[m.captures[0]].replace(",", "."))
  except ValueError:
    return err("invalid size in parseSize: " & getCurrentExceptionMsg() &
               " error parsing: " & input[m.captures[0]] & " KKK : " & $m)

  let units = input[m.captures[2]].toLowerAscii() # units is "kib", or "kb", or "b".

  var multiplier: float
  case units:
  of "kb":
    multiplier = 1000
  of "kib":
    multiplier = 1024
  of "ib":
    return err("wrong units. ib or iB aren't allowed.")
  else: ## bytes
    multiplier = 1

  value = value * multiplier

  return ok(int(value))
