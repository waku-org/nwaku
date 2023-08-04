{.used.}

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  testutils/unittests,
  stew/results
import
  ../../../waku/v2/waku_rln_relay/contract_interface

suite "Waku Rln Contract Interface":
    test "Should fetch the address of a deployed contract":
        let addressRes = getContractAddressForChain(Chains.Sepolia, Contracts.PoseidonHasher)
        assert addressRes.isOk(), addressRes.error()

        let address = addressRes.get()
        check:
            address != ""

    test "Should fetch the bytecode of a deployed contract":
        let bytecodeRes = getContractBytecodeForChain(Chains.Sepolia, Contracts.PoseidonHasher)
        assert bytecodeRes.isOk(), bytecodeRes.error()

        let bytecode = bytecodeRes.get()
        check:
            bytecode != ""
    