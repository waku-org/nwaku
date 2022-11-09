import
  # Waku v2 tests
  ./v2/test_wakunode


when defined(rln):
  import 
    ./v2/test_waku_rln_relay,
    ./v2/test_wakunode_rln_relay
  when defined(onchain_rln):
    import ./v2/test_waku_rln_relay_onchain


# TODO Only enable this once swap module is integrated more nicely as a dependency, i.e. as submodule with CI etc
# For PoC execute it manually and run separate module here: https://github.com/vacp2p/swap-contracts-module
#  ./v2/test_waku_swap_contracts
