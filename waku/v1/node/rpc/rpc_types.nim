import
  hexstrings, options, eth/keys,
  ../../protocol/waku_protocol

#[
  Notes:
    * Some of the types suppose 'null' when there is no appropriate value.
      To allow for this, you can use Option[T] or use refs so the JSON transform can convert to `JNull`.
    * Parameter objects from users must have their data verified so will use EthAddressStr instead of EthAddres, for example
    * Objects returned to the user can use native Waku types, where hexstrings provides converters to hex strings.
      This is because returned arrays in JSON is
      a) not an efficient use of space
      b) not the format the user expects (for example addresses are expected to be hex strings prefixed by "0x")
]#

type
  WakuInfo* = object
    # Returned to user
    minPow*: float64        # Current minimum PoW requirement.
    # TODO: may be uint32
    maxMessageSize*: uint64 # Current message size limit in bytes.
    memory*: int            # Memory size of the floating messages in bytes.
    messages*: int          # Number of floating messages.

  WakuFilterOptions* = object
    # Parameter from user
    symKeyID*: Option[Identifier]         # ID of symmetric key for message decryption.
    privateKeyID*: Option[Identifier]     # ID of private (asymmetric) key for message decryption.
    sig*: Option[PublicKey]               # (Optional) Public key of the signature.
    minPow*: Option[float64]              # (Optional) Minimal PoW requirement for incoming messages.
    topics*: Option[seq[waku_protocol.Topic]] # (Optional when asym key): Array of possible topics (or partial topics).
    allowP2P*: Option[bool]               # (Optional) Indicates if this filter allows processing of direct peer-to-peer messages.

  WakuFilterMessage* = object
    # Returned to user
    sig*: Option[PublicKey]                 # Public key who signed this message.
    recipientPublicKey*: Option[PublicKey]  # The recipients public key.
    ttl*: uint64                            # Time-to-live in seconds.
    timestamp*: uint64                      # Unix timestamp of the message generation.
    topic*: waku_protocol.Topic          # 4 Bytes: Message topic.
    payload*: seq[byte]                     # Decrypted payload.
    padding*: seq[byte]                     # (Optional) Padding (byte array of arbitrary length).
    pow*: float64                           # Proof of work value.
    hash*: Hash                             # Hash of the enveloped message.

  WakuPostMessage* = object
    # Parameter from user
    symKeyID*: Option[Identifier]     # ID of symmetric key for message encryption.
    pubKey*: Option[PublicKey]        # Public key for message encryption.
    sig*: Option[Identifier]          # (Optional) ID of the signing key.
    ttl*: uint64                      # Time-to-live in seconds.
    topic*: Option[waku_protocol.Topic] # Message topic (mandatory when key is symmetric).
    payload*: HexDataStr              # Payload to be encrypted.
    padding*: Option[HexDataStr]      # (Optional) Padding (byte array of arbitrary length).
    powTime*: float64                 # Maximal time in seconds to be spent on proof of work.
    powTarget*: float64               # Minimal PoW target required for this message.
    # TODO: EnodeStr
    targetPeer*: Option[string]       # (Optional) Peer ID (for peer-to-peer message only).
