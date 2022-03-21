## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/[oids, strformat, options, math]
import chronos
import chronicles
import bearssl
import stew/[endians2, byteutils]
import nimcrypto/[utils, sha2, hmac]

import libp2p/stream/[connection, streamseq]
import libp2p/peerid
import libp2p/peerinfo
import libp2p/protobuf/minprotobuf
import libp2p/utility
import libp2p/errors
import libp2p/crypto/[crypto, chacha20poly1305, curve25519, hkdf]
import libp2p/protocols/secure/secure


when defined(libp2p_dump):
  import libp2p/debugutils

logScope:
  topics = "libp2p noise"

const
  # https://godoc.org/github.com/libp2p/go-libp2p-noise#pkg-constants
  NoiseCodec* = "/noise"

  PayloadString = "noise-libp2p-static-key:"

  ProtocolXXName = "Noise_XX_25519_ChaChaPoly_SHA256"

  # Empty is a special value which indicates k has not yet been initialized.
  EmptyKey = default(ChaChaPolyKey)
  NonceMax = uint64.high - 1 # max is reserved
  NoiseSize = 32
  MaxPlainSize = int(uint16.high - NoiseSize - ChaChaPolyTag.len)

  HandshakeTimeout = 1.minutes

type
  KeyPair* = object
    privateKey: Curve25519Key
    publicKey: Curve25519Key

  NoisePublicKey* = object
    flag: uint8
    pk*: seq[byte]
    pk_auth: ChaChaPolyTag

  ChaChaPolyCiphertext* = object
    data: seq[byte]
    tag: ChaChaPolyTag

  ChaChaPolyCipherState* = object
    k*: ChaChaPolyKey
    nonce*: ChaChaPolyNonce
    ad*: seq[byte]

  #Noise  

  # https://noiseprotocol.org/noise.html#the-cipherstate-object
  CipherState* = object
    k: ChaChaPolyKey
    n: uint64

  # https://noiseprotocol.org/noise.html#the-symmetricstate-object
  SymmetricState* = object
    cs: CipherState
    ck: ChaChaPolyKey
    h: MDigest[256]

  # https://noiseprotocol.org/noise.html#the-handshakestate-object
  HandshakeState = object
    ss: SymmetricState
    s: KeyPair
    e: KeyPair
    rs: Curve25519Key
    re: Curve25519Key

  HandshakeResult = object
    cs1: CipherState
    cs2: CipherState
    remoteP2psecret: seq[byte]
    rs: Curve25519Key

  NoiseState* = object
    hs: HandshakeState
    hr: HandshakeResult

  IntermediateHS* = object
    msg*: StreamSeq
    hsr*: HandshakeResult

  Noise* = ref object of Secure
    rng: ref BrHmacDrbgContext
    staticKeyPair: KeyPair
    commonPrologue: seq[byte]
    outgoing: bool

  NoiseConnection* = ref object of SecureConn
    readCs: CipherState
    writeCs: CipherState

  NoiseError* = object of LPError
  NoiseHandshakeError* = object of NoiseError
  NoiseDecryptTagError* = object of NoiseError
  NoiseOversizedPayloadError* = object of NoiseError
  NoiseNonceMaxError* = object of NoiseError # drop connection on purpose
  NoisePublicKeyError* = object of NoiseError

# Utility

func shortLog*(conn: NoiseConnection): auto =
  try:
    if conn.isNil: "NoiseConnection(nil)"
    else: &"{shortLog(conn.peerId)}:{conn.oid}"
  except ValueError as exc:
    raise newException(Defect, exc.msg)

chronicles.formatIt(NoiseConnection): shortLog(it)

proc genKeyPair(rng: var BrHmacDrbgContext): KeyPair =
  result.privateKey = Curve25519Key.random(rng)
  result.publicKey = result.privateKey.public()

proc hashProtocol(name: string): MDigest[256] =
  # If protocol_name is less than or equal to HASHLEN bytes in length,
  # sets h equal to protocol_name with zero bytes appended to make HASHLEN bytes.
  # Otherwise sets h = HASH(protocol_name).

  if name.len <= 32:
    result.data[0..name.high] = name.toBytes
  else:
    result = sha256.digest(name)

proc dh(priv: Curve25519Key, pub: Curve25519Key): Curve25519Key =
  result = pub
  Curve25519.mul(result, priv)

# Cipherstate

proc hasKey(cs: CipherState): bool =
  cs.k != EmptyKey

proc encrypt(
    state: var CipherState,
    data: var openArray[byte],
    ad: openArray[byte]): ChaChaPolyTag
    {.noinit, raises: [Defect, NoiseNonceMaxError].} =

  var nonce: ChaChaPolyNonce
  nonce[4..<12] = toBytesLE(state.n)

  ChaChaPoly.encrypt(state.k, nonce, result, data, ad)

  inc state.n
  if state.n > NonceMax:
    raise newException(NoiseNonceMaxError, "Noise max nonce value reached")

proc encryptWithAd(state: var CipherState, ad, data: openArray[byte]): seq[byte]
  {.raises: [Defect, NoiseNonceMaxError].} =
  result = newSeqOfCap[byte](data.len + sizeof(ChaChaPolyTag))
  result.add(data)

  let tag = encrypt(state, result, ad)

  result.add(tag)

  trace "encryptWithAd",
    tag = byteutils.toHex(tag), data = result.shortLog, nonce = state.n - 1

proc decryptWithAd(state: var CipherState, ad, data: openArray[byte]): seq[byte]
  {.raises: [Defect, NoiseDecryptTagError, NoiseNonceMaxError].} =
  var
    tagIn = data.toOpenArray(data.len - ChaChaPolyTag.len, data.high).intoChaChaPolyTag
    tagOut: ChaChaPolyTag
    nonce: ChaChaPolyNonce
  nonce[4..<12] = toBytesLE(state.n)
  result = data[0..(data.high - ChaChaPolyTag.len)]
  ChaChaPoly.decrypt(state.k, nonce, tagOut, result, ad)
  trace "decryptWithAd", tagIn = tagIn.shortLog, tagOut = tagOut.shortLog, nonce = state.n
  if tagIn != tagOut:
    debug "decryptWithAd failed", data = shortLog(data)
    raise newException(NoiseDecryptTagError, "decryptWithAd failed tag authentication.")
  inc state.n
  if state.n > NonceMax:
    raise newException(NoiseNonceMaxError, "Noise max nonce value reached")

# Symmetricstate

proc init*(_: type[SymmetricState]): SymmetricState =
  result.h = ProtocolXXName.hashProtocol
  result.ck = result.h.data.intoChaChaPolyKey
  result.cs = CipherState(k: EmptyKey)

proc mixKey(ss: var SymmetricState, ikm: ChaChaPolyKey) =
  var
    temp_keys: array[2, ChaChaPolyKey]
  sha256.hkdf(ss.ck, ikm, [], temp_keys)
  ss.ck = temp_keys[0]
  ss.cs = CipherState(k: temp_keys[1])
  trace "mixKey", key = ss.cs.k.shortLog

proc mixHash(ss: var SymmetricState, data: openArray[byte]) =
  var ctx: sha256
  ctx.init()
  ctx.update(ss.h.data)
  ctx.update(data)
  ss.h = ctx.finish()
  trace "mixHash", hash = ss.h.data.shortLog

# We might use this for other handshake patterns/tokens
proc mixKeyAndHash(ss: var SymmetricState, ikm: openArray[byte]) {.used.} =
  var
    temp_keys: array[3, ChaChaPolyKey]
  sha256.hkdf(ss.ck, ikm, [], temp_keys)
  ss.ck = temp_keys[0]
  ss.mixHash(temp_keys[1])
  ss.cs = CipherState(k: temp_keys[2])

proc encryptAndHash(ss: var SymmetricState, data: openArray[byte]): seq[byte]
  {.raises: [Defect, NoiseNonceMaxError].} =
  # according to spec if key is empty leave plaintext
  if ss.cs.hasKey:
    result = ss.cs.encryptWithAd(ss.h.data, data)
  else:
    result = @data
  ss.mixHash(result)

proc decryptAndHash(ss: var SymmetricState, data: openArray[byte]): seq[byte]
  {.raises: [Defect, NoiseDecryptTagError, NoiseNonceMaxError].} =
  # according to spec if key is empty leave plaintext
  if ss.cs.hasKey and data.len > ChaChaPolyTag.len:
    result = ss.cs.decryptWithAd(ss.h.data, data)
  else:
    result = @data
  ss.mixHash(data)

proc split(ss: var SymmetricState): tuple[cs1, cs2: CipherState] =
  var
    temp_keys: array[2, ChaChaPolyKey]
  sha256.hkdf(ss.ck, [], [], temp_keys)
  return (CipherState(k: temp_keys[0]), CipherState(k: temp_keys[1]))

proc init*(_: type[HandshakeState]): HandshakeState =
  result.ss = SymmetricState.init()

template write_e: untyped =
  trace "noise write e"
  # Sets e (which must be empty) to GENERATE_KEYPAIR(). Appends e.public_key to the buffer. Calls MixHash(e.public_key).
  hs.e = genKeyPair(p.rng[])
  msg.add hs.e.publicKey
  hs.ss.mixHash(hs.e.publicKey)

template write_s: untyped =
  trace "noise write s"
  # Appends EncryptAndHash(s.public_key) to the buffer.
  msg.add hs.ss.encryptAndHash(hs.s.publicKey)

template dh_ee: untyped =
  trace "noise dh ee"
  # Calls MixKey(DH(e, re)).
  hs.ss.mixKey(dh(hs.e.privateKey, hs.re))

template dh_es: untyped =
  trace "noise dh es"
  # Calls MixKey(DH(e, rs)) if initiator, MixKey(DH(s, re)) if responder.
  when initiator:
    hs.ss.mixKey(dh(hs.e.privateKey, hs.rs))
  else:
    hs.ss.mixKey(dh(hs.s.privateKey, hs.re))

template dh_se: untyped =
  trace "noise dh se"
  # Calls MixKey(DH(s, re)) if initiator, MixKey(DH(e, rs)) if responder.
  when initiator:
    hs.ss.mixKey(dh(hs.s.privateKey, hs.re))
  else:
    hs.ss.mixKey(dh(hs.e.privateKey, hs.rs))

# might be used for other token/handshakes
template dh_ss: untyped {.used.} =
  trace "noise dh ss"
  # Calls MixKey(DH(s, rs)).
  hs.ss.mixKey(dh(hs.s.privateKey, hs.rs))

template read_e: untyped =
  trace "noise read e", size = msg.len

  if msg.len < Curve25519Key.len:
    raise newException(NoiseHandshakeError, "Noise E, expected more data")

  # Sets re (which must be empty) to the next DHLEN bytes from the message. Calls MixHash(re.public_key).
  hs.re[0..Curve25519Key.high] = msg.toOpenArray(0, Curve25519Key.high)
  msg.consume(Curve25519Key.len)
  hs.ss.mixHash(hs.re)

template read_s: untyped =
  trace "noise read s", size = msg.len
  # Sets temp to the next DHLEN + 16 bytes of the message if HasKey() == True, or to the next DHLEN bytes otherwise.
  # Sets rs (which must be empty) to DecryptAndHash(temp).
  let
    rsLen =
      if hs.ss.cs.hasKey:
        if msg.len < Curve25519Key.len + ChaChaPolyTag.len:
          raise newException(NoiseHandshakeError, "Noise S, expected more data")
        Curve25519Key.len + ChaChaPolyTag.len
      else:
        if msg.len < Curve25519Key.len:
          raise newException(NoiseHandshakeError, "Noise S, expected more data")
        Curve25519Key.len
  hs.rs[0..Curve25519Key.high] =
    hs.ss.decryptAndHash(msg.toOpenArray(0, rsLen - 1))

  msg.consume(rsLen)

proc readFrame(sconn: Connection): Future[seq[byte]] {.async.} =
  var besize {.noinit.}: array[2, byte]
  await sconn.readExactly(addr besize[0], besize.len)
  let size = uint16.fromBytesBE(besize).int
  trace "readFrame", sconn, size
  if size == 0:
    return

  var buffer = newSeqUninitialized[byte](size)
  await sconn.readExactly(addr buffer[0], buffer.len)
  return buffer

proc writeFrame(sconn: Connection, buf: openArray[byte]): Future[void] =
  doAssert buf.len <= uint16.high.int
  var
    lesize = buf.len.uint16
    besize = lesize.toBytesBE
    outbuf = newSeqOfCap[byte](besize.len + buf.len)
  trace "writeFrame", sconn, size = lesize, data = shortLog(buf)
  outbuf &= besize
  outbuf &= buf
  sconn.write(outbuf)

proc receiveHSMessage(sconn: Connection): Future[seq[byte]] = readFrame(sconn)
proc sendHSMessage(sconn: Connection, buf: openArray[byte]): Future[void] =
  writeFrame(sconn, buf)


proc HSFirstMessage*(p: Noise): IntermediateHS  =
  const initiator = true

  var
    hs = noise.HandshakeState.init()

  var ihs: IntermediateHS

  try:

    hs.ss.mixHash(p.commonPrologue)
    hs.s = p.staticKeyPair

    # -> e
    var msg: StreamSeq

    write_e()

    # IK might use this btw!
    msg.add hs.ss.encryptAndHash([])

    let (cs1, cs2) = hs.ss.split()

    ihs.msg = msg
    ihs.hsr = HandshakeResult(cs1: cs1, cs2: cs2, remoteP2psecret: @[], rs: hs.rs)
    return ihs

  except NoiseNonceMaxError as exc:
      debug "Noise nonce exceeded"
      return ihs
  finally:
    burnMem(hs)


proc handshakeXXOutbound(
    p: Noise, conn: Connection,
    p2pSecret: seq[byte]): Future[HandshakeResult] {.async.} =
  const initiator = true
  var
    hs = HandshakeState.init()

  try:

    hs.ss.mixHash(p.commonPrologue)
    hs.s = p.staticKeyPair

    # -> e
    var msg: StreamSeq

    write_e()

    # IK might use this btw!
    msg.add hs.ss.encryptAndHash([])

    await conn.sendHSMessage(msg.data)

    # <- e, ee, s, es

    msg.assign(await conn.receiveHSMessage())

    read_e()
    dh_ee()
    read_s()
    dh_es()

    let remoteP2psecret = hs.ss.decryptAndHash(msg.data)
    msg.clear()

    # -> s, se

    write_s()
    dh_se()

    # last payload must follow the encrypted way of sending
    msg.add hs.ss.encryptAndHash(p2pSecret)

    await conn.sendHSMessage(msg.data)

    let (cs1, cs2) = hs.ss.split()
    return HandshakeResult(cs1: cs1, cs2: cs2, remoteP2psecret: remoteP2psecret, rs: hs.rs)
  finally:
    burnMem(hs)

proc handshakeXXInbound(
    p: Noise, conn: Connection,
    p2pSecret: seq[byte]): Future[HandshakeResult] {.async.} =
  const initiator = false

  var
    hs = HandshakeState.init()

  try:
    hs.ss.mixHash(p.commonPrologue)
    hs.s = p.staticKeyPair

    # -> e

    var msg: StreamSeq
    msg.add(await conn.receiveHSMessage())

    read_e()

    # we might use this early data one day, keeping it here for clarity
    let earlyData {.used.} = hs.ss.decryptAndHash(msg.data)

    # <- e, ee, s, es

    msg.consume(msg.len)

    write_e()
    dh_ee()
    write_s()
    dh_es()

    msg.add hs.ss.encryptAndHash(p2pSecret)

    await conn.sendHSMessage(msg.data)
    msg.clear()

    # -> s, se

    msg.add(await conn.receiveHSMessage())

    read_s()
    dh_se()

    let
      remoteP2psecret = hs.ss.decryptAndHash(msg.data)
      (cs1, cs2) = hs.ss.split()
    return HandshakeResult(cs1: cs1, cs2: cs2, remoteP2psecret: remoteP2psecret, rs: hs.rs)
  finally:
    burnMem(hs)

method readMessage*(sconn: NoiseConnection): Future[seq[byte]] {.async.} =
  while true: # Discard 0-length payloads
    let frame = await sconn.stream.readFrame()
    sconn.activity = true
    if frame.len > ChaChaPolyTag.len:
      let res = sconn.readCs.decryptWithAd([], frame)
      if res.len > 0:
        when defined(libp2p_dump):
          dumpMessage(sconn, FlowDirection.Incoming, res)
        return res

    when defined(libp2p_dump):
      dumpMessage(sconn, FlowDirection.Incoming, [])
    trace "Received 0-length message", sconn


proc encryptFrame(
    sconn: NoiseConnection,
    cipherFrame: var openArray[byte],
    src: openArray[byte])
    {.raises: [Defect, NoiseNonceMaxError].} =
  # Frame consists of length + cipher data + tag
  doAssert src.len <= MaxPlainSize
  doAssert cipherFrame.len == 2 + src.len + sizeof(ChaChaPolyTag)

  cipherFrame[0..<2] = toBytesBE(uint16(src.len + sizeof(ChaChaPolyTag)))
  cipherFrame[2..<2 + src.len()] = src

  let tag = encrypt(
    sconn.writeCs, cipherFrame.toOpenArray(2, 2 + src.len() - 1), [])

  cipherFrame[2 + src.len()..<cipherFrame.len] = tag

method write*(sconn: NoiseConnection, message: seq[byte]): Future[void] =
  # Fast path: `{.async.}` would introduce a copy of `message`
  const FramingSize = 2 + sizeof(ChaChaPolyTag)

  let
    frames = (message.len + MaxPlainSize - 1) div MaxPlainSize

  var
    cipherFrames = newSeqUninitialized[byte](message.len + frames * FramingSize)
    left = message.len
    offset = 0
    woffset = 0

  while left > 0:
    let
      chunkSize = min(MaxPlainSize, left)

    try:
      encryptFrame(
        sconn,
        cipherFrames.toOpenArray(woffset, woffset + chunkSize + FramingSize - 1),
        message.toOpenArray(offset, offset + chunkSize - 1))
    except NoiseNonceMaxError as exc:
      debug "Noise nonce exceeded"
      let fut = newFuture[void]("noise.write.nonce")
      fut.fail(exc)
      return fut

    when defined(libp2p_dump):
      dumpMessage(
        sconn, FlowDirection.Outgoing,
        message.toOpenArray(offset, offset + chunkSize - 1))

    left = left - chunkSize
    offset += chunkSize
    woffset += chunkSize + FramingSize

  sconn.activity = true

  # Write all `cipherFrames` in a single write, to avoid interleaving /
  # sequencing issues
  sconn.stream.write(cipherFrames)


method init*(p: Noise) {.gcsafe.} =
  procCall Secure(p).init()
  p.codec = NoiseCodec

proc new*(
  T: typedesc[Noise],
  rng: ref BrHmacDrbgContext,
  outgoing: bool = true,
  commonPrologue: seq[byte] = @[]): T =

  var noise = Noise(
    rng: rng,
    outgoing: outgoing,
    staticKeyPair: genKeyPair(rng[]),
    commonPrologue: commonPrologue,
  )

  noise.init()
  echo "pubkey:", byteutils.toHex(getBytes(noise.staticKeyPair.publicKey))
  echo "privkey:", byteutils.toHex(getBytes(noise.staticKeyPair.privateKey))
  noise








# Vanilla ChaChaPoly encryption
proc encrypt*(
    state: ChaChaPolyCipherState,
    plaintext: openArray[byte]): ChaChaPolyCiphertext
    {.noinit, raises: [Defect].} =
  #TODO: add padding
  result.data.add plaintext
  ChaChaPoly.encrypt(state.k, state.nonce, result.tag, result.data, state.ad)

proc decrypt*(
    state: ChaChaPolyCipherState, 
    ciphertext: ChaChaPolyCiphertext): seq[byte]
    {.raises: [Defect, NoiseDecryptTagError].} =
  var
    tagIn = ciphertext.tag
    tagOut: ChaChaPolyTag
  result = ciphertext.data
  ChaChaPoly.decrypt(state.k, state.nonce, tagOut, result, state.ad)
  #TODO: add unpadding
  trace "decrypt", tagIn = tagIn.shortLog, tagOut = tagOut.shortLog, nonce = state.nonce
  if tagIn != tagOut:
    debug "decrypt failed", result = shortLog(result)
    raise newException(NoiseDecryptTagError, "decrypt tag authentication failed.")


proc randomChaChaPolyCipherState*(rng: var BrHmacDrbgContext): ChaChaPolyCipherState =
  brHmacDrbgGenerate(rng, result.k)
  brHmacDrbgGenerate(rng, result.nonce)
  result.ad = newSeq[byte](32)
  brHmacDrbgGenerate(rng, result.ad)





# Public keys serializations/encryption

proc `==`(k1, k2: NoisePublicKey): bool =
  result = (k1.flag == k2.flag) and (k1.pk == k2.pk) and (k1.pk_auth == k2.pk_auth)
  

proc genNoisePublicKey*(rng: var BrHmacDrbgContext): NoisePublicKey =
  let keyPair: KeyPair = genKeyPair(rng)
  result.flag = 0
  result.pk = getBytes(keyPair.publicKey)

proc serializeNoisePublicKey*(noisePublicKey: NoisePublicKey): seq[byte] =
  result.add noisePublicKey.flag
  result.add noisePublicKey.pk
  result.add noisePublicKey.pk_auth

#TODO: strip pk_auth if pk not encrypted
proc intoNoisePublicKey*(serializedNoisePublicKey: seq[byte]): NoisePublicKey =
  let pk_len = serializedNoisePublicKey.len - 1 - ChaChaPolyTag.len
  #Only Curve25519 is supported
  #if pk_len != Curve25519Key.len:
  #  raise newException(NoisePublicKeyError, "Serialized public key byte length is not correct")
  result.flag = serializedNoisePublicKey[0]
  result.pk = serializedNoisePublicKey[1..pk_len]
  result.pk_auth = intoChaChaPolyTag(serializedNoisePublicKey[pk_len+1..pk_len+ChaChaPolyTag.len])



# Public keys encryption/decryption

proc encryptNoisePublicKey*(cs: ChaChaPolyCipherState, noisePublicKey: NoisePublicKey): NoisePublicKey
  {.raises: [Defect, NoiseNonceMaxError].} =
  if cs.k != EmptyKey and noisePublicKey.flag == 0:
    let enc_pk = encrypt(cs, noisePublicKey.pk)
    result.flag = 1
    result.pk = enc_pk.data
    result.pk_auth = enc_pk.tag
  else:
    result = noisePublicKey


proc decryptNoisePublicKey*(cs: ChaChaPolyCipherState, noisePublicKey: NoisePublicKey): NoisePublicKey
  {.raises: [Defect, NoiseDecryptTagError].} =
  if cs.k != EmptyKey and noisePublicKey.flag == 1:
    let ciphertext = ChaChaPolyCiphertext(data: noisePublicKey.pk, tag: noisePublicKey.pk_auth)
    result.pk = decrypt(cs, ciphertext)
    result.flag = 0
  else:
    if cs.k == EmptyKey:
      debug "No key in cipher state."
    if noisePublicKey.flag == 0:
      debug "Public key is not encrypted."
    debug "Public key is left unchanged"
    result = noisePublicKey






# Payload functions
type
  PayloadV2* = object
    protocol_id: uint8
    handshake_message: seq[NoisePublicKey]
    transport_message: seq[byte]
    transport_message_auth: ChaChaPolyTag


proc `==`(p1, p2: PayloadV2): bool =
  result = (p1.protocol_id == p2.protocol_id) and (p1.handshake_message == p2.handshake_message) and (p1.transport_message == p2.transport_message) and (p1.transport_message_auth == p2.transport_message_auth)
  


proc randomPayloadV2*(rng: var BrHmacDrbgContext): PayloadV2 =
  var protocol_id = newSeq[byte](1)
  brHmacDrbgGenerate(rng, protocol_id)
  result.protocol_id = protocol_id[0].uint8
  result.handshake_message = @[genNoisePublicKey(rng), genNoisePublicKey(rng), genNoisePublicKey(rng)]
  result.transport_message = newSeq[byte](128)
  brHmacDrbgGenerate(rng, result.transport_message)
  echo result.protocol_id
  echo result.handshake_message
  echo result.transport_message
  echo result.transport_message_auth


proc encodeV2*(self: PayloadV2): Option[seq[byte]] =

  #We collect public keys contained in the handshake message
  var
    ser_handshake_message_len: int = 0
    ser_handshake_message = newSeqOfCap[byte](256)
    ser_pk: seq[byte]
  for pk in self.handshake_message:
    ser_pk = serializeNoisePublicKey(pk)
    ser_handshake_message_len +=  ser_pk.len
    ser_handshake_message.add ser_pk


  #RFC: handshake-message-len is 1 byte
  if ser_handshake_message_len > 256:
    debug "Payload malformed: too many public keys contained in the handshake message"
    return some(newSeqOfCap[byte](0))

  let transport_message_len = self.transport_message.len
  #let transport_message_len_len = ceil(log(transport_message_len, 8)).int

  var payload = newSeqOfCap[byte](1 + #self.protocol_id.len +              
                                  1 + #ser_handshake_message_len 
                                  ser_handshake_message_len +        
                                  8 + #transport_message_len
                                  transport_message_len + #self.transport_message
                                  self.transport_message_auth.len)
  
  
  payload.add self.protocol_id.byte
  payload.add ser_handshake_message_len.byte
  payload.add ser_handshake_message
  payload.add toBytesLE(transport_message_len.uint64)
  payload.add self.transport_message
  payload.add self.transport_message_auth

  echo payload

  return some(payload)



#Decode Noise handshake payload
proc decodeV2*(payload: seq[byte]): Option[PayloadV2] =
  var res: PayloadV2

  var i: uint64 = 0
  res.protocol_id = payload[i].uint8
  i+=1

  echo "ID", res.protocol_id

  let handshake_message_len = payload[i].uint64
  i+=1

  echo "hmlen", handshake_message_len


  let pk_len: uint64 = 1 + Curve25519Key.len + ChaChaPolyTag.len
  let no_of_pks = handshake_message_len div pk_len

  echo pk_len, " ", no_of_pks

  res.handshake_message = newSeqOfCap[NoisePublicKey](no_of_pks)

  for j in 0..<no_of_pks:
    echo payload[i..(i+pk_len-1)]
    res.handshake_message.add intoNoisePublicKey(payload[i..(i+pk_len-1)])
    i += pk_len

  echo "HSM", res.handshake_message


  let transport_message_len = fromBytesLE(uint64, payload[i..(i+8-1)])
  i+=8
  echo "len", transport_message_len

  res.transport_message = payload[i..i+transport_message_len-1]
  i+=transport_message_len

  echo "tsm", res.transport_message

  res.transport_message_auth = intoChaChaPolyTag(payload[i..i+ChaChaPolyTag.len-1])

  echo "tsmAUTH", res.transport_message_auth

  return some(res)