when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/typetraits,
  stew/results,
  chronicles,
  presto/common
import
  ./serdes


const MIMETYPE_JSON* = MediaType.init("application/json")
const MIMETYPE_TEXT* = MediaType.init("text/plain")


proc ok*(t: typedesc[RestApiResponse]): RestApiResponse =
  RestApiResponse.response("OK", Http200, $MIMETYPE_TEXT)

proc internalServerError*(t: typedesc[RestApiResponse]): RestApiResponse =
  RestApiResponse.error(Http500)

proc badRequest*(t: typedesc[RestApiResponse]): RestApiResponse =
  RestApiResponse.error(Http400)

proc notFound*(t: typedesc[RestApiResponse]): RestApiResponse =
  RestApiResponse.error(Http404)


proc jsonResponse*(t: typedesc[RestApiResponse], data: auto, status: HttpCode = Http200): SerdesResult[RestApiResponse] =
  let encoded = ?encodeIntoJsonBytes(data)
  ok(RestApiResponse.response(encoded, status, $MIMETYPE_JSON))

proc textResponse*(t: typedesc[RestApiResponse], data: string, status: HttpCode = Http200): RestApiResponse =
  RestApiResponse.response(data, status, $MIMETYPE_TEXT)
