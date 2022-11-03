when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/typetraits
import 
  chronicles,
  stew/results,
  presto/common
import "."/serdes


const MIMETYPE_JSON* = MediaType.init("application/json")
const MIMETYPE_TEXT* = MediaType.init("text/plain")

proc jsonResponse*(t: typedesc[RestApiResponse], data: auto, status: HttpCode = Http200): SerdesResult[RestApiResponse] =
  let encoded = ?encodeIntoJsonBytes(data)
  ok(RestApiResponse.response(encoded, status, $MIMETYPE_JSON))

proc internalServerError*(t: typedesc[RestApiResponse]): RestApiResponse =
  RestApiResponse.error(Http500)

proc ok*(t: typedesc[RestApiResponse]): RestApiResponse =
  RestApiResponse.response("OK", status=Http200, contentType="text/plain")

proc badRequest*(t: typedesc[RestApiResponse]): RestApiResponse =
  RestApiResponse.error(Http400)


proc notFound*(t: typedesc[RestApiResponse]): RestApiResponse =
  RestApiResponse.error(Http404)