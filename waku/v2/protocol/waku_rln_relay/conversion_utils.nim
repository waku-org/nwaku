when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[sequtils],
  strutils,
  web3,
  chronicles, 
  stew/[arrayops, results, endians2],
  stint
import
    ./protocol_types
import
  ../../utils/keyfile

logScope:
    topics = "waku rln_relay conversion_utils"

proc toUInt256*(idCommitment: IDCommitment): UInt256 =
  let pk = UInt256.fromBytesLE(idCommitment)
  return pk

proc toIDCommitment*(idCommitmentUint: UInt256): IDCommitment =
  let pk = IDCommitment(idCommitmentUint.toBytesLE())
  return pk

proc inHex*(value: array[32, byte]): string =
  var valueHex = (UInt256.fromBytesLE(value)).toHex()
  # We pad leading zeroes
  while valueHex.len < value.len * 2:
    valueHex = "0" & valueHex
  return valueHex

proc toMembershipIndex*(v: UInt256): MembershipIndex =
  let membershipIndex: MembershipIndex = cast[MembershipIndex](v)
  return membershipIndex

proc appendLength*(input: openArray[byte]): seq[byte] =
  ## returns length prefixed version of the input
  ## with the following format [len<8>|input<var>]
  ## len: 8-byte value that represents the number of bytes in the `input`
  ## len is serialized in little-endian
  ## input: the supplied `input`
  let
    # the length should be serialized in little-endian
    len = toBytes(uint64(input.len), Endianness.littleEndian)
    output = concat(@len, @input)
  return output

proc serialize*(idSecretHash: IdentitySecretHash, memIndex: MembershipIndex, epoch: Epoch,
    msg: openArray[byte]): seq[byte] =
  ## a private proc to convert RateLimitProof and the data to a byte seq
  ## this conversion is used in the proofGen proc
  ## the serialization is done as instructed in  https://github.com/kilic/rln/blob/7ac74183f8b69b399e3bc96c1ae8ab61c026dc43/src/public.rs#L146
  ## [ id_key<32> | id_index<8> | epoch<32> | signal_len<8> | signal<var> ]
  let memIndexBytes = toBytes(uint64(memIndex), Endianness.littleEndian)
  let lenPrefMsg = appendLength(msg)
  let output = concat(@idSecretHash, @memIndexBytes, @epoch, lenPrefMsg)
  return output


proc serialize*(proof: RateLimitProof, data: openArray[byte]): seq[byte] =
  ## a private proc to convert RateLimitProof and data to a byte seq
  ## this conversion is used in the proof verification proc
  ## [ proof<128> | root<32> | epoch<32> | share_x<32> | share_y<32> | nullifier<32> | rln_identifier<32> | signal_len<8> | signal<var> ]
  let lenPrefMsg = appendLength(@data)
  var proofBytes = concat(@(proof.proof),
                          @(proof.merkleRoot),
                          @(proof.epoch),
                          @(proof.shareX),
                          @(proof.shareY),
                          @(proof.nullifier),
                          @(proof.rlnIdentifier),
                          lenPrefMsg)

  return proofBytes

# Serializes a sequence of MerkleNodes
proc serialize*(roots: seq[MerkleNode]): seq[byte] =
  var rootsBytes: seq[byte] = @[]
  for root in roots:
    rootsBytes = concat(rootsBytes, @root)
  return rootsBytes

proc serializeIdCommitments*(idComms: seq[IDCommitment]): seq[byte] =
  ## serializes a seq of IDCommitments to a byte seq
  ## the serialization is based on https://github.com/status-im/nwaku/blob/37bd29fbc37ce5cf636734e7dd410b1ed27b88c8/waku/v2/protocol/waku_rln_relay/rln.nim#L142
  ## the order of serialization is |id_commitment_len<8>|id_commitment<var>|
  var idCommsBytes = newSeq[byte]()

  # serialize the idComms, with its length prefixed
  let len = toBytes(uint64(idComms.len), Endianness.littleEndian)
  idCommsBytes.add(len)

  for idComm in idComms:
    idCommsBytes = concat(idCommsBytes, @idComm)

  return idCommsBytes

# Converts a sequence of tuples containing 4 string (i.e. identity trapdoor, nullifier, secret hash and commitment) to an IndentityCredential
proc toIdentityCredentials*(groupKeys: seq[(string, string, string, string)]): RlnRelayResult[seq[
    IdentityCredential]] =
  ## groupKeys is  sequence of membership key tuples in the form of (identity key, identity commitment) all in the hexadecimal format
  ## the toIdentityCredentials proc populates a sequence of IdentityCredentials using the supplied groupKeys
  ## Returns an error if the conversion fails

  var groupIdCredentials = newSeq[IdentityCredential]()

  for i in 0..groupKeys.len-1:
    try:
      let
        idTrapdoor = hexToUint[IdentityTrapdoor.len*8](groupKeys[i][0]).toBytesLE()
        idNullifier = hexToUint[IdentityNullifier.len*8](groupKeys[i][1]).toBytesLE()
        idSecretHash = hexToUint[IdentitySecretHash.len*8](groupKeys[i][2]).toBytesLE()
        idCommitment = hexToUint[IDCommitment.len*8](groupKeys[i][3]).toBytesLE()
      groupIdCredentials.add(IdentityCredential(idTrapdoor: idTrapdoor, idNullifier: idNullifier, idSecretHash: idSecretHash,
          idCommitment: idCommitment))
    except ValueError as err:
      warn "could not convert the group key to bytes", err = err.msg
      return err("could not convert the group key to bytes: " & err.msg)
  return ok(groupIdCredentials)

# Converts a sequence of tuples containing 2 string (i.e. identity secret hash and commitment) to an IndentityCredential
proc toIdentityCredentials*(groupKeys: seq[(string, string)]): RlnRelayResult[seq[
    IdentityCredential]] =
  ## groupKeys is  sequence of membership key tuples in the form of (identity key, identity commitment) all in the hexadecimal format
  ## the toIdentityCredentials proc populates a sequence of IdentityCredentials using the supplied groupKeys
  ## Returns an error if the conversion fails

  var groupIdCredentials = newSeq[IdentityCredential]()

  for i in 0..groupKeys.len-1:
    try:
      let
        idSecretHash = hexToUint[IdentitySecretHash.len*8](groupKeys[i][0]).toBytesLE()
        idCommitment = hexToUint[IDCommitment.len*8](groupKeys[i][1]).toBytesLE()
      groupIdCredentials.add(IdentityCredential(idSecretHash: idSecretHash,
          idCommitment: idCommitment))
    except ValueError as err:
      warn "could not convert the group key to bytes", err = err.msg
      return err("could not convert the group key to bytes: " & err.msg)
  return ok(groupIdCredentials)

proc toEpoch*(t: uint64): Epoch =
  ## converts `t` to `Epoch` in little-endian order
  let bytes = toBytes(t, Endianness.littleEndian)
  debug "bytes", bytes = bytes
  var epoch: Epoch
  discard epoch.copyFrom(bytes)
  return epoch

proc fromEpoch*(epoch: Epoch): uint64 =
  ## decodes bytes of `epoch` (in little-endian) to uint64
  let t = fromBytesLE(uint64, array[32, byte](epoch))
  return t
