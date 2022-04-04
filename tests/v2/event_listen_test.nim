import pkg/unittest2
import web3
import chronos, nimcrypto, options, json, stint
import test_utils
import ./depositcontract
from ./test_waku_rln_relay_onchain import uploadContract 
import
  std/options, sequtils, times,
  testutils/unittests, chronos, chronicles, stint, web3, json,
  stew/byteutils, stew/shims/net as stewNet,
  libp2p/crypto/crypto,
  ../../waku/v2/protocol/waku_rln_relay/[rln, waku_rln_relay_utils, waku_rln_relay_types],
  ../../waku/v2/node/wakunode2,
  ../test_helpers,
  ./test_utils
contract(DepositContract):
  proc deposit(pubkey: DynamicBytes[0, 48], withdrawalCredentials: DynamicBytes[0, 32], signature: DynamicBytes[0, 96], deposit_data_root: FixedBytes[32])
  proc get_deposit_root(): FixedBytes[32]
  proc DepositEvent(pubkey: DynamicBytes[0, 48], withdrawalCredentials: DynamicBytes[0, 32], amount: DynamicBytes[0, 8], signature: DynamicBytes[0, 96], merkleTreeIndex: DynamicBytes[0, 8]) {.event.}

contract(MembershipContract):
  proc register(pubkey: Uint256) # external payable
  # proc registerBatch(pubkeys: seq[Uint256]) # external payable
  # TODO will add withdraw function after integrating the keyGeneration function (required to compute public keys from secret keys)
  # proc withdraw(secret: Uint256, pubkeyIndex: Uint256, receiver: Address)
  # proc withdrawBatch( secrets: seq[Uint256], pubkeyIndex: seq[Uint256], receiver: seq[Address])
  proc MemberRegistered(pubkey: Uint256, index: Uint256) {.event.}

suite "Deposit contract":

  # test "deposits":
  #   proc test() {.async.} =
  #     # web3 client
  #     let web3 = await newWeb3("ws://127.0.0.1:8540/")
  #     let accounts = await web3.provider.eth_accounts()
  #     let gasPrice = int(await web3.provider.eth_gasPrice())
  #     web3.defaultAccount = accounts[0]

  #     let receipt = await web3.deployContract(DepositContractCode, gasPrice=gasPrice)
  #     let contractAddress = receipt.contractAddress.get
  #     echo "Deployed Deposit contract: ", contractAddress

  #     var contractObj = web3.contractSender(DepositContract, contractAddress)

  #     let notifFut = newFuture[void]()
  #     var notificationsReceived = 0

  #     var pk = DynamicBytes[0, 48].fromHex("0xa20469ec49fdfdcaaa68c470642feb9d7d0e612026c6243928772a7277bde77d081e63cc9034cee9eb5abee66ea12861")
  #     var cr = DynamicBytes[0, 32].fromHex("0x0012c7b99594801d513ae92396379e5ffcf60e23127cbcabb166db28586f01aa")
  #     var sig = DynamicBytes[0, 96].fromHex("0x81c7536816ff1e4ca6a52b5e853c19e9def14c01b07f0e1ac9b1e8a198bf78c98e98e74465d13e2978ae720dcab0a7da10fa56221477773ad7c3f82317c3e0f12a76f47332b9b5350b655ae196db33221f64183d1da3784f608001489ff523d5")
  #     var dataRoot = FixedBytes[32].fromHex("0x2ed19a8a1a22a2ff61fbd3862d4ff9f9bd45836efe313e6ecad6dd907f1b6078")

  #     var fut = newFuture[void]()

  #     let s = await contractObj.subscribe(DepositEvent, %*{"fromBlock": "0x0"}) do (
  #         pubkey: DynamicBytes[0, 48], withdrawalCredentials: DynamicBytes[0, 32], amount: DynamicBytes[0, 8], signature: DynamicBytes[0, 96], merkleTreeIndex: DynamicBytes[0, 8])
  #         {.raises: [Defect], gcsafe.}:
  #       try:
  #         echo "onDeposit"
  #         echo "pubkey: ", pubkey
  #         echo "withdrawalCredentials: ", withdrawalCredentials
  #         echo "amount: ", amount
  #         echo "signature: ", signature
  #         echo "merkleTreeIndex: ", merkleTreeIndex
  #         assert(pubkey == pk)
  #         fut.complete()
  #       except Exception as err:
  #         # chronos still raises exceptions which inherit directly from Exception
  #         doAssert false, err.msg
  #     do (err: CatchableError):
  #       echo "Error from DepositEvent subscription: ", err.msg

  #     discard await contractObj.deposit(pk, cr, sig, dataRoot).send(value = 32.u256.ethToWei, gasPrice=gasPrice)
    

  #     await fut
  #     echo "hash_tree_root: ", await contractObj.get_deposit_root().call()
  #     await web3.close()

  #   waitFor test()

  test "rln relay": 
    proc rlntest() {.async.} =
        debug "ethereum client address", ETH_CLIENT
        let contractAddress = await uploadContract(ETH_CLIENT)
        # connect to the eth client
        let web3 = await newWeb3(ETH_CLIENT)
        debug "web3 connected to", ETH_CLIENT 

        # fetch the list of registered accounts
        let accounts = await web3.provider.eth_accounts()
        web3.defaultAccount = accounts[1]
        debug "contract deployer account address ", defaultAccount=web3.defaultAccount 

        # prepare a contract sender to interact with it
        var contractObj = web3.contractSender(MembershipContract, contractAddress) # creates a Sender object with a web3 field and contract address of type Address

        # let notifFut = newFuture[void]()
        # var notificationsReceived = 0
        var fut = newFuture[int]()

        let s = await contractObj.subscribe(MemberRegistered, %*{"fromBlock": "0x0"}) do(
          pubkey: Uint256, index: Uint256){.raises: [Defect], gcsafe.}:
          try:
            echo "onDeposit"
            echo "public key", pubkey
            echo "index", index
            fut.complete(1)
          except Exception as err:
            # chronos still raises exceptions which inherit directly from Exception
            doAssert false, err.msg
        do (err: CatchableError):
            echo "Error from DepositEvent subscription: ", err.msg

        discard await contractObj.register(20.u256).send(value = MembershipFee)

        # await fut
        # await sleepAsync(20000)
        await web3.close()
    waitFor rlntest()
      
    
    