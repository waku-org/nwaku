## Main module for using nwaku as a Nimble library
## 
## This module re-exports the public API for creating and managing Waku nodes
## when using nwaku as a library dependency.

# Re-export the main types and functions
export libwaku_api, libwaku_conf

# Import the modules to make them available
import library/libwaku_api
import library/libwaku_conf

# Re-export essential types from waku factory
import waku/factory/waku
export Waku
