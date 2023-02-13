import
  std/options,
  stew/byteutils,
  libp2p/switch,
  libp2p/builders
import
  ../../../waku/v2/protocol/waku_message,
  ./common

export switch


# Switch

proc generateEcdsaKey*(): PrivateKey =
  PrivateKey.random(ECDSA, rng[]).get()

proc generateEcdsaKeyPair*(): KeyPair =
  KeyPair.random(ECDSA, rng[]).get()

proc generateSecp256k1Key*(): PrivateKey =
  PrivateKey.random(Secp256k1, rng[]).get()


proc newTestSwitch*(key=none(PrivateKey), address=none(MultiAddress)): Switch =
  let peerKey = key.get(generateSecp256k1Key())
  let peerAddr = address.get(MultiAddress.init("/ip4/127.0.0.1/tcp/0").get())
  return newStandardSwitch(some(peerKey), addrs=peerAddr)


# Waku message

export
  waku_message.DefaultPubsubTopic,
  waku_message.DefaultContentTopic


proc fakeWakuMessage*(
  payload: string|seq[byte] = "TEST-PAYLOAD",
  contentTopic = DefaultContentTopic,
  ts = now(),
  ephemeral = false
): WakuMessage =
  var payloadBytes: seq[byte]
  when payload is string:
    payloadBytes = toBytes(payload)
  else:
    payloadBytes = payload

  WakuMessage(
    payload: payloadBytes,
    contentTopic: contentTopic,
    version: 2,
    timestamp: ts,
    ephemeral: ephemeral
  )
