
{.used.}

import
  stew/[results, byteutils],
  testutils/unittests
import
  ../../waku/common/base64


suite "Waku Common - stew base64 wrapper":

  test "encode into base64 (with padding)":
    ## Given
    # From RFC 4648 test vectors: https://www.rfc-editor.org/rfc/rfc4648#page-12
    let data  = "fooba"

    ## When
    let encoded = base64.encode(data)

    ## Then
    check:
      encoded == Base64String("Zm9vYmE=")


  test "decode from base64 (with padding)":
    ## Given
    # From RFC 4648 test vectors: https://www.rfc-editor.org/rfc/rfc4648#page-12
    let data = Base64String("Zm9vYg==")

    ## When
    let decodedRes = base64.decode(data)

    ## Then
    check:
      decodedRes.isOk()

    let decoded = decodedRes.tryGet()
    check:
      decoded == toBytes("foob")
