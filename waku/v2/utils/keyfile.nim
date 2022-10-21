# This implementation is taken from nim-eth keyfile module https://github.com/status-im/nim-eth/blob/master/eth/keyfile
# and adapted to create keyfiles for arbitrary-long byte data (rather than fixed-size private keys)

{.push raises: [Defect].}

import
  std/[strutils, json, sequtils],
  nimcrypto/[bcmode, hmac, rijndael, pbkdf2, sha2, sysrand, utils, keccak, scrypt],
  stew/results,
  eth/keys,
  eth/keyfile/uuid

export results

const
  # Version 3 constants
  SaltSize = 16
  DKLen = 32
  MaxDKLen = 128
  ScryptR = 1
  ScryptP = 8
  Pbkdf2WorkFactor = 1_000_000
  ScryptWorkFactor = 262_144

type
  KeyFileError* = enum
    RandomError           = "kf: Random generator error"
    UuidError             = "kf: UUID generator error"
    BufferOverrun         = "kf: Supplied buffer is too small"
    IncorrectDKLen        = "kf: `dklen` parameter is 0 or more then MaxDKLen"
    MalformedError        = "kf: JSON has incorrect structure"
    NotImplemented        = "kf: Feature is not implemented"
    NotSupported          = "kf: Feature is not supported"
    EmptyMac              = "kf: `mac` parameter is zero length or not in hexadecimal form"
    EmptyCiphertext       = "kf: `ciphertext` parameter is zero length or not in hexadecimal format"
    EmptySalt             = "kf: `salt` parameter is zero length or not in hexadecimal format"
    EmptyIV               = "kf: `cipherparams.iv` parameter is zero length or not in hexadecimal format"
    IncorrectIV           = "kf: Size of IV vector is not equal to cipher block size"
    PrfNotSupported       = "kf: PRF algorithm for PBKDF2 is not supported"
    KdfNotSupported       = "kf: KDF algorithm is not supported"
    CipherNotSupported    = "kf: `cipher` parameter is not supported"
    IncorrectMac          = "kf: `mac` verification failed"
    ScryptBadParam        = "kf: bad scrypt's parameters"
    OsError               = "kf: OS specific error"
    JsonError             = "kf: JSON encoder/decoder error"

  KdfKind* = enum
    PBKDF2,             ## PBKDF2
    SCRYPT              ## SCRYPT

  HashKind* = enum
    HashNoSupport, HashSHA2_224, HashSHA2_256, HashSHA2_384, HashSHA2_512,
    HashKECCAK224, HashKECCAK256, HashKECCAK384, HashKECCAK512,
    HashSHA3_224, HashSHA3_256, HashSHA3_384, HashSHA3_512

  CryptKind* = enum
    CipherNoSupport,    ## Cipher not supported
    AES128CTR           ## AES-128-CTR

  CipherParams = object
    iv: seq[byte]

  Cipher = object
    kind: CryptKind
    params: CipherParams
    text: seq[byte]

  Crypto = object
    kind: KdfKind
    cipher: Cipher
    kdfParams: JsonNode
    mac: seq[byte]

  ScryptParams* = object
    dklen: int
    n, p, r: int
    salt: string

  Pbkdf2Params* = object
    dklen: int
    c: int
    prf: HashKind
    salt: string

  DKey = array[DKLen, byte]
  KfResult*[T] = Result[T, KeyFileError]

const
  SupportedHashes = [
    "sha224", "sha256", "sha384", "sha512",
    "keccak224", "keccak256", "keccak384", "keccak512",
    "sha3_224", "sha3_256", "sha3_384", "sha3_512"
  ]

  SupportedHashesKinds = [
    HashSHA2_224, HashSHA2_256, HashSHA2_384, HashSHA2_512,
    HashKECCAK224, HashKECCAK256, HashKECCAK384, HashKECCAK512,
    HashSHA3_224, HashSHA3_256, HashSHA3_384, HashSHA3_512
  ]

  # When true, the keyfile json will contain "version" and "id" fields, respectively. Default to false.
  VersionInKeyfile: bool = false
  IdInKeyfile: bool = false

proc mapErrTo[T, E](r: Result[T, E], v: static KeyFileError): KfResult[T] =
  r.mapErr(proc (e: E): KeyFileError = v)

proc `$`(k: KdfKind): string =
  case k
    of SCRYPT:
      result = "scrypt"
    else:
      result = "pbkdf2"

proc `$`(k: CryptKind): string =
  case k
    of AES128CTR:
      result = "aes-128-ctr"
    else:
      result = "aes-128-ctr"

proc getPrfHash(prf: string): HashKind =
  result = HashNoSupport
  let p = prf.toLowerAscii()
  if p.startsWith("hmac-"):
    var hash = p[5..^1]
    var res = SupportedHashes.find(hash)
    if res >= 0:
      result = SupportedHashesKinds[res]
    else:
      result = HashNoSupport

proc getCipher(c: string): CryptKind =
  var cl = c.toLowerAscii()
  if cl == "aes-128-ctr":
    result = AES128CTR
  else:
    result = CipherNoSupport

proc deriveKey(password: string,
               salt: string,
               kdfkind: KdfKind,
               hashkind: HashKind,
               workfactor: int): KfResult[DKey] =
  if kdfkind == PBKDF2:
    var output: DKey
    var c = if workfactor == 0: Pbkdf2WorkFactor else: workfactor
    case hashkind
    of HashSHA2_224:
      var ctx: HMAC[sha224]
      discard ctx.pbkdf2(password, salt, c, output)
      ok(output)
    of HashSHA2_256:
      var ctx: HMAC[sha256]
      discard ctx.pbkdf2(password, salt, c, output)
      ok(output)
    of HashSHA2_384:
      var ctx: HMAC[sha384]
      discard ctx.pbkdf2(password, salt, c, output)
      ok(output)
    of HashSHA2_512:
      var ctx: HMAC[sha512]
      discard ctx.pbkdf2(password, salt, c, output)
      ok(output)
    of HashKECCAK224:
      var ctx: HMAC[keccak224]
      discard ctx.pbkdf2(password, salt, c, output)
      ok(output)
    of HashKECCAK256:
      var ctx: HMAC[keccak256]
      discard ctx.pbkdf2(password, salt, c, output)
      ok(output)
    of HashKECCAK384:
      var ctx: HMAC[keccak384]
      discard ctx.pbkdf2(password, salt, c, output)
      ok(output)
    of HashKECCAK512:
      var ctx: HMAC[keccak512]
      discard ctx.pbkdf2(password, salt, c, output)
      ok(output)
    of HashSHA3_224:
      var ctx: HMAC[sha3_224]
      discard ctx.pbkdf2(password, salt, c, output)
      ok(output)
    of HashSHA3_256:
      var ctx: HMAC[sha3_256]
      discard ctx.pbkdf2(password, salt, c, output)
      ok(output)
    of HashSHA3_384:
      var ctx: HMAC[sha3_384]
      discard ctx.pbkdf2(password, salt, c, output)
      ok(output)
    of HashSHA3_512:
      var ctx: HMAC[sha3_512]
      discard ctx.pbkdf2(password, salt, c, output)
      ok(output)
    else:
      err(PrfNotSupported)
  else:
    err(NotImplemented)

func scrypt[T, M](password: openArray[T], salt: openArray[M],
                   N, r, p: int, output: var openArray[byte]): int =
  let (xyvLen, bLen) = scryptCalc(N, r, p)
  var xyv = newSeq[uint32](xyvLen)
  var b = newSeq[byte](bLen)
  scrypt(password, salt, N, r, p, xyv, b, output)

proc deriveKey(password: string, salt: string,
               workFactor, r, p: int): KfResult[DKey] =

  let wf = if workFactor == 0: ScryptWorkFactor else: workFactor
  var output: DKey
  if scrypt(password, salt, wf, r, p, output) == 0:
    return err(ScryptBadParam)

  result = ok(output)

proc encryptData(secret: openArray[byte],
                cryptkind: CryptKind,
                key: openArray[byte],
                iv: openArray[byte]): KfResult[seq[byte]] =
  if cryptkind == AES128CTR:
    var crypttext = newSeqWith(secret.len, 0.byte) 
    var ctx: CTR[aes128]
    ctx.init(toOpenArray(key, 0, 15), iv)
    ctx.encrypt(secret, crypttext)
    ctx.clear()
    ok(crypttext)
  else:
    err(NotImplemented)

proc decryptData(ciphertext: openArray[byte],
                cryptkind: CryptKind,
                key: openArray[byte],
                iv: openArray[byte]): KfResult[seq[byte]] =
  if cryptkind == AES128CTR:
    if len(iv) != aes128.sizeBlock:
      return err(IncorrectIV)
    var plaintext = newSeqWith(ciphertext.len, 0.byte)  
    var ctx: CTR[aes128]
    ctx.init(toOpenArray(key, 0, 15), iv)
    ctx.decrypt(ciphertext, plaintext)
    ctx.clear()
    ok(plaintext)
  else:
    err(NotImplemented)

proc kdfParams(kdfkind: KdfKind, salt: string, workfactor: int): KfResult[JsonNode] =
  if kdfkind == SCRYPT:
    let wf = if workfactor == 0: ScryptWorkFactor else: workfactor
    ok(%*
      {
        "dklen": DKLen,
        "n": wf,
        "r": ScryptR,
        "p": ScryptP,
        "salt": salt
      }
    )
  elif kdfkind == PBKDF2:
    let wf = if workfactor == 0: Pbkdf2WorkFactor else: workfactor
    ok(%*
      {
        "dklen": DKLen,
        "c": wf,
        "prf": "hmac-sha256",
        "salt": salt
      }
    )
  else:
    err(NotImplemented)

proc decodeHex(m: string): seq[byte] =
  if len(m) > 0:
    try:
      result = utils.fromHex(m)
    except CatchableError:
      result = newSeq[byte]()
  else:
    result = newSeq[byte]()

proc decodeSalt(m: string): string =
  var sarr: seq[byte]
  if len(m) > 0:
    try:
      sarr = utils.fromHex(m)
      result = newString(len(sarr))
      copyMem(addr result[0], addr sarr[0], len(sarr))
    except CatchableError:
      result = ""
  else:
    result = ""

proc compareMac(m1: openArray[byte], m2: openArray[byte]): bool =
  if len(m1) == len(m2) and len(m1) > 0:
    result = equalMem(unsafeAddr m1[0], unsafeAddr m2[0], len(m1))

proc createKeyFileJson*(secret: openArray[byte],
                        password: string,
                        version: int = 3,
                        cryptkind: CryptKind = AES128CTR,
                        kdfkind: KdfKind = PBKDF2,
                        workfactor: int = 0): KfResult[JsonNode] =
  ## Create JSON object with keyfile structure.
  ##
  ## ``seckey`` - private key, which will be stored
  ## ``password`` - encryption password
  ## ``outjson`` - result JSON object
  ## ``version`` - version of keyfile format (default is 3)
  ## ``cryptkind`` - algorithm for private key encryption
  ## (default is AES128-CTR)
  ## ``kdfkind`` - algorithm for key deriviation function (default is PBKDF2)
  ## ``workfactor`` - Key deriviation function work factor, 0 is to use
  ## default workfactor.
  var iv: array[aes128.sizeBlock, byte]
  var salt: array[SaltSize, byte]
  var saltstr = newString(SaltSize)
  if randomBytes(iv) != aes128.sizeBlock:
    return err(RandomError)
  if randomBytes(salt) != SaltSize:
    return err(RandomError)
  copyMem(addr saltstr[0], addr salt[0], SaltSize)

  let u = ? uuidGenerate().mapErrTo(UuidError)

  let
    dkey = case kdfkind
           of PBKDF2: ? deriveKey(password, saltstr, kdfkind, HashSHA2_256, workfactor)
           of SCRYPT: ? deriveKey(password, saltstr, workfactor, ScryptR, ScryptP)

    ciphertext = ? encryptData(secret, cryptkind, dkey, iv)

  var ctx: keccak256
  ctx.init()
  ctx.update(toOpenArray(dkey, 16, 31))
  ctx.update(ciphertext)
  var mac = ctx.finish()
  ctx.clear()

  let params = ? kdfParams(kdfkind, toHex(salt, true), workfactor)

  let json = %*
    {
      "crypto": {
        "cipher": $cryptkind,
        "cipherparams": {
          "iv": toHex(iv, true)
        },
        "ciphertext": toHex(ciphertext, true),
        "kdf": $kdfkind,
        "kdfparams": params,
        "mac": toHex(mac.data, true),
      },
    }

  if IdInKeyfile:
    json.add("id", %($u))
  if VersionInKeyfile:
    json.add("version", %version)

  echo json

  ok(json)

proc decodeCrypto(n: JsonNode): KfResult[Crypto] =
  var crypto = n.getOrDefault("crypto")
  if isNil(crypto):
    return err(MalformedError)

  var kdf = crypto.getOrDefault("kdf")
  if isNil(kdf):
    return err(MalformedError)

  var c: Crypto
  case kdf.getStr()
  of "pbkdf2": c.kind = PBKDF2
  of "scrypt": c.kind = SCRYPT
  else: return err(KdfNotSupported)

  var cipherparams = crypto.getOrDefault("cipherparams")
  if isNil(cipherparams):
    return err(MalformedError)

  c.cipher.kind = getCipher(crypto.getOrDefault("cipher").getStr())
  c.cipher.params.iv = decodeHex(cipherparams.getOrDefault("iv").getStr())
  c.cipher.text = decodeHex(crypto.getOrDefault("ciphertext").getStr())
  c.mac = decodeHex(crypto.getOrDefault("mac").getStr())
  c.kdfParams = crypto.getOrDefault("kdfparams")

  if c.cipher.kind == CipherNoSupport:
    return err(CipherNotSupported)
  if len(c.cipher.text) == 0:
    return err(EmptyCiphertext)
  if len(c.mac) == 0:
    return err(EmptyMac)
  if isNil(c.kdfParams):
    return err(MalformedError)

  result = ok(c)

proc decodePbkdf2Params(params: JsonNode): KfResult[Pbkdf2Params] =
  var p: Pbkdf2Params
  p.salt = decodeSalt(params.getOrDefault("salt").getStr())
  if len(p.salt) == 0:
    return err(EmptySalt)

  p.dklen = params.getOrDefault("dklen").getInt()
  p.c = params.getOrDefault("c").getInt()
  p.prf = getPrfHash(params.getOrDefault("prf").getStr())

  if p.prf == HashNoSupport:
    return err(PrfNotSupported)
  if p.dklen == 0 or p.dklen > MaxDKLen:
    return err(IncorrectDKLen)
  result = ok(p)

proc decodeScryptParams(params: JsonNode): KfResult[ScryptParams] =
  var p: ScryptParams
  p.salt = decodeSalt(params.getOrDefault("salt").getStr())
  if len(p.salt) == 0:
    return err(EmptySalt)

  p.dklen = params.getOrDefault("dklen").getInt()
  p.n = params.getOrDefault("n").getInt()
  p.p = params.getOrDefault("p").getInt()
  p.r = params.getOrDefault("r").getInt()

  if p.dklen == 0 or p.dklen > MaxDKLen:
    return err(IncorrectDKLen)

  result = ok(p)

func decryptSecret(crypto: Crypto, dkey: DKey): KfResult[seq[byte]] =
  var ctx: keccak256
  ctx.init()
  ctx.update(toOpenArray(dkey, 16, 31))
  ctx.update(crypto.cipher.text)
  var mac = ctx.finish()
  if not compareMac(mac.data, crypto.mac):
    return err(IncorrectMac)

  let plaintext = ? decryptData(crypto.cipher.text, crypto.cipher.kind, dkey, crypto.cipher.params.iv)
  
  ok(plaintext)

proc decodeKeyFileJson*(j: JsonNode,
                        password: string): KfResult[seq[byte]] =
  ## Decode private key into ``seckey`` from keyfile json object ``j`` using
  ## password string ``password``.
  let res = decodeCrypto(j)
  if res.isErr:
    return err(res.error)
  let crypto = res.get()

  case crypto.kind
  of PBKDF2:
    let res = decodePbkdf2Params(crypto.kdfParams)
    if res.isErr:
      return err(res.error)

    let params = res.get()
    let dkey = ? deriveKey(password, params.salt, PBKDF2, params.prf, params.c)
    result = decryptSecret(crypto, dkey)

  of SCRYPT:
    let res = decodeScryptParams(crypto.kdfParams)
    if res.isErr:
      return err(res.error)

    let params = res.get()
    let dkey = ? deriveKey(password, params.salt, params.n, params.r, params.p)
    result = decryptSecret(crypto, dkey)

proc loadKeyFile*(pathname: string,
                  password: string): KfResult[seq[byte]] =
  ## Load and decode private key ``seckey`` from file with pathname
  ## ``pathname``, using password string ``password``.
  var data: JsonNode
  try:
    data = json.parseFile(pathname)
  except JsonParsingError:
    return err(JsonError)
  except Exception: # json raises Exception
    return err(OsError)

  decodeKeyFileJson(data, password)

proc saveKeyFile*(pathname: string,
                  jobject: JsonNode): KfResult[void] =
  ## Save JSON object ``jobject`` to file with pathname ``pathname``.
  var
    f: File
  if not f.open(pathname, fmWrite):
    return err(OsError)
  try:
    f.write($jobject)
    ok()
  except CatchableError:
    err(OsError)
  finally:
    f.close()

