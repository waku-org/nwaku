# Running Swap Protocol

## How to

Build:

```
# make wakunode2 is run as part of scripts2 target
make scripts2
```

Run two nodes and connect them:

```
# Starts listening on 60000 with RPC server on 8545.
# Note the "listening on address" in logs.
./build/wakunode2 --ports-shift:0

# Run another node with staticnode argument
./build/wakunode2 --ports-shift:1 --staticnode:/ip4/0.0.0.0/tcp/60000/p2p/16Uiu2HAmF4tuht6fmna6uDqoSMgFqhUrdaVR6VQRyGr6sCpfS2jp --storenode:/ip4/0.0.0.0/tcp/60000/p2p/16Uiu2HAmF4tuht6fmna6uDqoSMgFqhUrdaVR6VQRyGr6sCpfS2jp --persist-messages:true


# Run the chat application
./build/chat2 --staticnode:/ip4/0.0.0.0/tcp/60000/p2p/16Uiu2HAmF4tuht6fmna6uDqoSMgFqhUrdaVR6VQRyGr6sCpfS2jp --storenode:/ip4/0.0.0.0/tcp/60000/p2p/16Uiu2HAmF4tuht6fmna6uDqoSMgFqhUrdaVR6VQRyGr6sCpfS2jp 

```
 You should be prompted to provide a nickname for the chat session.

```
Choose a nickname >>
```

After entering a nickname, the app will be connected to peer `16Uiu2HAmF4tuht6fmna6uDqoSMgFqhUrdaVR6VQRyGr6sCpfS2jp`

```

# Run another chat application
./build/chat2 --staticnode:/ip4/0.0.0.0/tcp/60000/p2p/16Uiu2HAmF4tuht6fmna6uDqoSMgFqhUrdaVR6VQRyGr6sCpfS2jp --storenode:/ip4/0.0.0.0/tcp/60000/p2p/16Uiu2HAmF4tuht6fmna6uDqoSMgFqhUrdaVR6VQRyGr6sCpfS2jp 
```
Connect with a different nickname. 
You should see a log saying:
```
Crediting Peer: peer=16U*CpfS2jp amount=1
```
 where amount is the number of Messages received. 


## To View the Account Metrics:
To view the account metrics on Grafana Dashboard locally, follow the steps [here](https://github.com/status-im/nim-waku/tree/master/waku/v2#using-metrics) to set up grafana and prometheus. 
The metrics on the live cluster can be accessed [here](https://grafana.infra.status.im/d/qrp_ZCTGz/nim-waku-v2?orgId=1&refresh=5m)