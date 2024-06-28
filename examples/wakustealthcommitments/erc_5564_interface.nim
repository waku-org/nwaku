## Nim wrappers for the functions defined in librln
{.push raises: [].}

import stew/results

######################################################################
## ERC-5564-BN254 module APIs
######################################################################

type CErrorCode* = uint8

type CG1Projective* = object
  x0: array[32, uint8]

type CReturn*[T] = object
  value: T
  err_code: CErrorCode

type CFr* = object
  x0: array[32, uint8]

type CStealthCommitment* = object
  stealth_commitment: CG1Projective
  view_tag: uint64

type CKeyPair* = object
  private_key: CFr
  public_key: CG1Projective

proc drop_ffi_derive_public_key*(
  ptrx: ptr CReturn[CG1Projective]
) {.importc: "drop_ffi_derive_public_key".}

proc drop_ffi_generate_random_fr*(
  ptrx: ptr CReturn[CFr]
) {.importc: "drop_ffi_generate_random_fr".}

proc drop_ffi_generate_stealth_commitment*(
  ptrx: ptr CReturn[CStealthCommitment]
) {.importc: "drop_ffi_generate_stealth_commitment".}

proc drop_ffi_generate_stealth_private_key*(
  ptrx: ptr CReturn[CFr]
) {.importc: "drop_ffi_generate_stealth_private_key".}

proc drop_ffi_random_keypair*(
  ptrx: ptr CReturn[CKeyPair]
) {.importc: "drop_ffi_random_keypair".}

proc ffi_derive_public_key*(
  private_key: ptr CFr
): (ptr CReturn[CG1Projective]) {.importc: "ffi_derive_public_key".}

proc ffi_generate_random_fr*(): (ptr CReturn[CFr]) {.importc: "ffi_generate_random_fr".}

proc ffi_generate_stealth_commitment*(
  viewing_public_key: ptr CG1Projective,
  spending_public_key: ptr CG1Projective,
  ephemeral_private_key: ptr CFr,
): (ptr CReturn[CStealthCommitment]) {.importc: "ffi_generate_stealth_commitment".}

proc ffi_generate_stealth_private_key*(
  ephemeral_public_key: ptr CG1Projective,
  spending_key: ptr CFr,
  viewing_key: ptr CFr,
  view_tag: ptr uint64,
): (ptr CReturn[CFr]) {.importc: "ffi_generate_stealth_private_key".}

proc ffi_random_keypair*(): (ptr CReturn[CKeyPair]) {.importc: "ffi_random_keypair".}

## Nim wrappers and types for the ERC-5564-BN254 module

type FFIResult[T] = Result[T, string]
type Fr = array[32, uint8]
type G1Projective = array[32, uint8]
type KeyPair* = object
  private_key*: Fr
  public_key*: G1Projective

type StealthCommitment* = object
  stealth_commitment*: G1Projective
  view_tag*: uint64

type PrivateKey* = Fr
type PublicKey* = G1Projective

proc generateRandomFr*(): FFIResult[Fr] =
  let res_ptr = (ffi_generate_random_fr())
  let res_value = res_ptr[]
  if res_value.err_code != 0:
    drop_ffi_generate_random_fr(res_ptr)
    return err("Error generating random field element: " & $res_value.err_code)

  let ret = res_value.value.x0
  drop_ffi_generate_random_fr(res_ptr)
  return ok(ret)

proc generateKeypair*(): FFIResult[KeyPair] =
  let res_ptr = (ffi_random_keypair())
  let res_value = res_ptr[]
  if res_value.err_code != 0:
    drop_ffi_random_keypair(res_ptr)
    return err("Error generating random keypair: " & $res_value.err_code)

  let ret = KeyPair(
    private_key: res_value.value.private_key.x0,
    public_key: res_value.value.public_key.x0,
  )
  drop_ffi_random_keypair(res_ptr)
  return ok(ret)

proc generateStealthCommitment*(
    viewing_public_key: G1Projective,
    spending_public_key: G1Projective,
    ephemeral_private_key: Fr,
): FFIResult[StealthCommitment] =
  let viewing_public_key = CG1Projective(x0: viewing_public_key)
  let viewing_public_key_ptr = unsafeAddr(viewing_public_key)
  let spending_public_key = CG1Projective(x0: spending_public_key)
  let spending_public_key_ptr = unsafeAddr(spending_public_key)
  let ephemeral_private_key = CFr(x0: ephemeral_private_key)
  let ephemeral_private_key_ptr = unsafeAddr(ephemeral_private_key)

  let res_ptr = (
    ffi_generate_stealth_commitment(
      viewing_public_key_ptr, spending_public_key_ptr, ephemeral_private_key_ptr
    )
  )
  let res_value = res_ptr[]
  if res_value.err_code != 0:
    drop_ffi_generate_stealth_commitment(res_ptr)
    return err("Error generating stealth commitment: " & $res_value.err_code)

  let ret = StealthCommitment(
    stealth_commitment: res_value.value.stealth_commitment.x0,
    view_tag: res_value.value.view_tag,
  )
  drop_ffi_generate_stealth_commitment(res_ptr)
  return ok(ret)

proc generateStealthPrivateKey*(
    ephemeral_public_key: G1Projective,
    spending_key: Fr,
    viewing_key: Fr,
    view_tag: uint64,
): FFIResult[Fr] =
  let ephemeral_public_key = CG1Projective(x0: ephemeral_public_key)
  let ephemeral_public_key_ptr = unsafeAddr(ephemeral_public_key)
  let spending_key = CFr(x0: spending_key)
  let spending_key_ptr = unsafeAddr(spending_key)
  let viewing_key = CFr(x0: viewing_key)
  let viewing_key_ptr = unsafeAddr(viewing_key)
  let view_tag_ptr = unsafeAddr(view_tag)

  let res_ptr = (
    ffi_generate_stealth_private_key(
      ephemeral_public_key_ptr, spending_key_ptr, viewing_key_ptr, view_tag_ptr
    )
  )
  let res_value = res_ptr[]
  if res_value.err_code != 0:
    drop_ffi_generate_stealth_private_key(res_ptr)
    return err("Error generating stealth private key: " & $res_value.err_code)

  let ret = res_value.value.x0
  drop_ffi_generate_stealth_private_key(res_ptr)
  return ok(ret)
