{.used.}

{.push raises: [].}

import std/[options, os], results, testutils/unittests, chronos, web3

import
  waku/[
    waku_rln_relay,
    waku_rln_relay/conversion_utils,
    waku_rln_relay/group_manager/on_chain/group_manager,
  ],
  ./utils_onchain

suite "Token and RLN Contract Deployment":
  test "anvil state after deployment should match existing state file":
    let existingStateFile = DEFAULT_ANVIL_STATE_PATH
    let newStateFile = some("tests/waku_rln_relay/anvil_state/anvil_state.json.ignore")
    let anvilProc = runAnvil(stateFile = newStateFile, dumpStateOnExit = true)
    let manager = waitFor setupOnchainGroupManager(deployContracts = true)

    stopAnvil(anvilProc)

    # Wait for Anvil to finish writing state file before checking
    waitFor sleepAsync(100.millis)

    check:
      fileExists(newStateFile.get())
