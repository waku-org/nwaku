## SWAP implements Accounting for Waku. See
## https://github.com/vacp2p/specs/issues/24 for more.
##
## This is based on the SWAP based approach researched by the Swarm team, and
## can be thought of as an economic extension to Bittorrent's tit-for-tat
## economics.
##
## It is quite suitable for accounting for imbalances between peers, and
## specifically for something like the Store protocol.
##
## It is structured as follows:
##
## 1) First a handshake is made, where terms are agreed upon
##
## 2) Then operation occurs as normal with HistoryRequest, HistoryResponse etc
## through store protocol (or otherwise)
##
## 3) When payment threshhold is met, a cheque is sent. This acts as promise to
## pay. Right now it is best thought of as karma points.
##
## Things like settlement is for future work.
##

## TODO Basic protobufs
