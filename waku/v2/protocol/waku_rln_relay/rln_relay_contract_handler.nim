import rln_relay_contract

type MerkleTreeUpdater  = proc():void {.gcsafe, closure, raises: [Defect].}
proc subscribe(handler: MerkleTreeUpdater) {.async, gcsafe.} = 
  let s = await contractObj.subscribe(MemberRegistered, %*{"fromBlock": "0x0",
        "address": contractAddress}) do(
      pubkey: Uint256, index: Uint256){.raises: [Defect], gcsafe.}:
      try:
        debug "onRegister", pubkey = pubkey, index = index
        # check:
        #   pubkey == pk
        # fut.complete()
      except Exception as err:
        # chronos still raises exceptions which inherit directly from Exception
        doAssert false, err.msg
    do (err: CatchableError):
      echo "Error from subscription: ", err.msg