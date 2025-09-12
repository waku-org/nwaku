## Main module for using nwaku as a Nimble library
## 
## This module re-exports the public API for creating and managing Waku nodes
## when using nwaku as a library dependency.

import waku/api/[api, api_conf]
export api, api_conf

import waku/factory/waku
export waku
