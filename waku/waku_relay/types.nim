import secp256k1

type ProtectedTopic* = object
    topic*: string
    key*: secp256k1.SkPublicKey
