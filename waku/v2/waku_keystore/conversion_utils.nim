when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import 
  json,
  stew/[results, byteutils],
  ./protocol_types

# Encodes a Membership credential to a byte sequence
proc encode*(credential: MembershipCredentials): seq[byte] =
  # TODO: use custom encoding, avoid wordy json
  var stringCredential: string
  # NOTE: toUgly appends to the string, doesn't replace its contents
  stringCredential.toUgly(%credential)
  return toBytes(stringCredential)

# Decodes a byte sequence to a Membership credential
proc decode*(encodedCredential: seq[byte]): KeystoreResult[MembershipCredentials] =
  # TODO: use custom decoding, avoid wordy json
  try:
    # we parse the json decrypted keystoreCredential
    let jsonObject = parseJson(string.fromBytes(encodedCredential))
    return ok(to(jsonObject, MembershipCredentials))
  except JsonParsingError:
    return err(KeystoreJsonError)
  except Exception: #parseJson raises Exception
    return err(KeystoreOsError)