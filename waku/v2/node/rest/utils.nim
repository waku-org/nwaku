{.push raises: [Defect].}

import std/typetraits
import 
  chronicles,
  stew/results,
  presto/common
import "."/serdes


const MIMETYPE_JSON* = MediaType.init("application/json")

proc jsonResponse*(t: typedesc[RestApiResponse], data: auto, status: HttpCode = Http200): SerdesResult[RestApiResponse] =
  let encoded = ?encodeIntoJsonBytes(data)
  ok(RestApiResponse.response(encoded, status, $MIMETYPE_JSON))

proc internalServerError*(t: typedesc[RestApiResponse]): RestApiResponse =
  RestApiResponse.error(Http500)