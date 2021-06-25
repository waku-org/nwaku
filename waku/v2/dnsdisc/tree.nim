{.push raises: [Defect]}

import
  std/[strscans, strutils],
  stew/[base32, base64, results],
  eth/keys,
  eth/p2p/discoveryv5/enr

export keys, enr

## A collection of utilities for interacting with a list of ENR
## encoded as a Merkle Tree conisting of DNS TXT records.
## 
## Discovery via DNS is based on https://eips.ethereum.org/EIPS/eip-1459
## 
## This implementation is based on the Go implementation of EIP-1459
## at https://github.com/ethereum/go-ethereum/blob/master/p2p/dnsdisc

const
  RootPrefix = "enrtree-root:v1"
  BranchPrefix = "enrtree-branch:"
  EnrPrefix = "enr:"
  LinkPrefix = "enrtree://"

type
  EntryParseResult*[T] = Result[T, string]

  # Entry types

  RootEntry* = object
    eroot*: string # Root of subtree containing node records
    lroot*: string # Root of subtree containing links to other trees
    seqNo*: uint32 # Sequence number, increased with every update
    signature*: seq[byte] # Root entry signature
  
  BranchEntry* = object
    children*: seq[string] # Hashes pointing to the subdomains of other subtree entries
  
  EnrEntry* = object
    record*: enr.Record # Ethereum node record as per EIP-778
  
  LinkEntry* = object
    str*: string  # String representation of subdomain, i.e. <key>@<domain>
    pubKey*: PublicKey # Public key that signed the list at this link
    domain*: string

####################
# Helper functions #
####################

proc isValidHash(hashStr: string): bool =
  ## Checks if a hash is valid. It should be the base32
  ## encoding of an abbreviated keccak256 hash.
  let decodedLen = Base32.decodedLength(hashStr.len())

  if (decodedLen > 32) or (hashStr.contains("\n\r")):
    # @TODO: also check minimum hash size
    return false
  
  try:
    discard Base32.decode(hashStr)
  except Base32Error:
    return false

  return true

#################
# Entry parsers #
#################

proc parseRootEntry*(entry: string): EntryParseResult[RootEntry] =
  ## Parses a root entry in the format
  ## 'enrtree-root:v1 e=<enr-root> l=<link-root> seq=<sequence-number> sig=<signature>'
  
  var
    eroot, lroot, sigstr: string
    seqNo: int
    signature: seq[byte]

  try:
    if not scanf(entry, RootPrefix & " e=$+ l=$+ seq=$i sig=$+", eroot, lroot, seqNo, sigstr):
      # @TODO better error handling
      return err("Invalid syntax")
  except ValueError:
    return err("Invalid syntax")

  if (not isValidHash(eroot)) or (not isValidHash(lroot)):
    return err("Invalid child")
  
  try:
    signature = Base64Url.decode(sigstr)
  except Base64Error:
    return err("Invalid signature")

  if signature.len() != SkRawPublicKeySize:
    return err("Invalid signature")

  ok(RootEntry(eroot: eroot, lroot: lroot, seqNo: uint32(seqNo), signature: signature))

proc parseBranchEntry*(entry: string): EntryParseResult[BranchEntry] =
  ## Parses a branch entry in the format
  ## 'enrtree-branch:<h₁>,<h₂>,...,<hₙ>'
  
  var
    hashesSubstr: string
    hashes: seq[string]
  
  try:
    if not scanf(entry, BranchPrefix & "$+", hashesSubstr):
      # @TODO better error handling
      return err("Invalid syntax")
  except ValueError:
    return err("Invalid syntax")

  for hash in hashesSubstr.split(','):
    if (not isValidHash(hash)):
      return err("Invalid child")

    hashes.add(hash)
  
  ok(BranchEntry(children: hashes))

proc parseEnrEntry*(entry: string): EntryParseResult[EnrEntry] =
  ## Parses an enr entry in the format 'enr:<node-record>'.
  ## <node-record> is the EIP-1459 text encoding of the node record
  
  var
    nodeStr: string
    record: Record
  
  try:
    if not scanf(entry, EnrPrefix & "$+", nodeStr):
      # @TODO better error handling
      return err("Invalid syntax")
  except ValueError:
    return err("Invalid syntax")

  if (not record.fromBase64(nodeStr)):
    return err("Invalid signature")

  ok(EnrEntry(record: record))

proc parseLinkEntry*(entry: string): EntryParseResult[LinkEntry] =
  ## Parses a link entry in the format
  ## 'enrtree://<key>@<fqdn>'
  
  var
    keyStr, fqdnStr: string
    rawKey: seq[byte]
    key: PublicKey
  
  try:
    if not scanf(entry, LinkPrefix & "$+@$+", keyStr, fqdnStr):
      # @TODO better error handling
      return err("Invalid syntax")
  except ValueError:
    return err("Invalid syntax")

  try:
    rawKey = Base32.decode(keyStr)
  except Base32Error:
    return err("Invalid public key")

  try:
    key = PublicKey.fromRaw(rawKey).tryGet()
  except CatchableError as e:
    return err("Invalid public key: " & e.msg)

  ok(LinkEntry(str: keyStr & "@" & fqdnStr,
               domain: fqdnStr,
               pubKey: key))
