when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
    os, 
    std/json

import ./protocol_types

export
    json,
    protocol_types

# Update these when we have more contracts, chains
type 
    Contracts* = enum
        PoseidonHasher = "PoseidonHasher", WakuRln = "WakuRln"
    Chains* = enum
        Sepolia = "sepolia"
    ArtifactKeys = enum
        Address = "address", Bytecode = "bytecode"

proc getContractForChain(chain: Chains, contract: Contracts): RlnRelayResult[JsonNode] =
    let path = "vendor/waku-rln-contract/deployments/" & $chain & "/" & $contract & ".json"
    # check if file exists
    if not fileExists(path):
        return err("Contract artifact not found: " & path)
    # read file
    var data: string
    try:
        data = path.readFile()
    except IOError:
        return err("Could not read contract artifact: " & getCurrentExceptionMsg())
    # parse json
    var jsonNode: JsonNode
    try:
        jsonNode = parseJson(data)
    except IOError, ValueError, Exception:
        return err("Could not parse contract artifact: " & getCurrentExceptionMsg())
    return ok(jsonNode)

proc getKeyInContractArtifact(chain: Chains, contract: Contracts, key: ArtifactKeys): RlnRelayResult[string] =
    let jsonNodeRes = getContractForChain(chain, contract)
    if jsonNodeRes.isErr():
        return err(jsonNodeRes.error())
    var retVal: string
    try:
        retVal = jsonNodeRes.get()[$key].getStr()
    except KeyError:
        return err("Could not find key in contract artifact: " & getCurrentExceptionMsg())
    return ok(retVal)

proc getContractAddressForChain*(chain: Chains, contract: Contracts): RlnRelayResult[string] =
    return getKeyInContractArtifact(chain, contract, ArtifactKeys.Address)

proc getContractBytecodeForChain*(chain: Chains, contract: Contracts): RlnRelayResult[string] =
    return getKeyInContractArtifact(chain, contract, ArtifactKeys.Bytecode)