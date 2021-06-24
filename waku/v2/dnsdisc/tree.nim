{.push raises: [Defect]}

import
  std/[strscans, strutils],
  secp256k1,
  stew/[base32, base64, results],
  libp2p/multiaddress

## A collection of utilities for interacting with a list of libp2p peers
## encoded as a Merkle Tree conisting of DNS TXT records.
## 
## This forms part of an implementation of 25/LIBP2P-DNS-DISCOVERY 
## available at https://rfc.vac.dev/spec/25/
## 
## Libp2p peer discovery via DNS is based on https://eips.ethereum.org/EIPS/eip-1459
## 
## This implementation is based on the Go implementation of EIP-1459
## at https://github.com/ethereum/go-ethereum/blob/master/p2p/dnsdisc

const
  RootPrefix = "matree-root:v1"
  BranchPrefix = "matree-branch:"
  MultiaddrPrefix = "ma:"
  LinkPrefix = "matree://"

type
  EntryParseResult*[T] = Result[T, string]

  # Entry types

  RootEntry* = object
    mroot*: string # Root of subtree containing multiaddrs
    lroot*: string # Root of subtree containing links to other trees
    seqNo*: uint32 # Sequence number, increased with every update
    signature*: seq[byte] # Root entry signature
  
  BranchEntry* = object
    children*: seq[string] # Hashes pointing to the subdomains of other subtree entries
  
  MultiaddrEntry* = object
    multiaddr*: MultiAddress
  
  LinkEntry* = object
    pubkey*: string
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
  ## 'matree-root:v1 m=<ma-root> l=<link-root> seq=<sequence number> sig=<signature>'
  
  var
    mroot, lroot, sigstr: string
    seqNo: int
    signature: seq[byte]

  try:
    if not scanf(entry, RootPrefix & " m=$+ l=$+ seq=$i sig=$+", mroot, lroot, seqNo, sigstr):
      # @TODO better error handling
      return err("Invalid syntax")
  except ValueError:
    return err("Invalid syntax")

  if (not isValidHash(mroot)) or (not isValidHash(lroot)):
    return err("Invalid child")
  
  try:
    signature = Base64Url.decode(sigstr)
  except Base64Error:
    return err("Invalid signature")

  if signature.len() != SkRawPublicKeySize:
    return err("Invalid signature")

  ok(RootEntry(mroot: mroot, lroot: lroot, seqNo: uint32(seqNo), signature: signature))

proc parseBranchEntry*(entry: string): EntryParseResult[BranchEntry] =
  ## Parses a branch entry in the format
  ## 'matree-branch:<h₁>,<h₂>,...,<hₙ>'
  
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

# proc parseMultiaddrEntry*(entry: string): ParseResult[MultiaddrEntry] 

# proc parseLinkEntry*(entry: string): ParseResult[LinkEntry] 