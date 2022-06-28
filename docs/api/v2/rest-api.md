## HTTP REST API

Similar to the JSON-RPC API, the HTTP REST API consists of a set of methods operating on the Waku Node remotely over HTTP.

This API is divided in different _namespaces_ which group a set of resources:

| Namespace | Description |
------------|--------------
| `/debug` | Information about a Waku v2 node. |
| `/relay` | Control of the relaying of messages. See [11/WAKU2-RELAY](https://rfc.vac.dev/spec/11/) RFC |
| `/store` | Retrieve the message history. See [13/WAKU2-STORE](https://rfc.vac.dev/spec/13/) RFC |
| `/filter` | Control of the content filtering. See [12/WAKU2-FILTER](https://rfc.vac.dev/spec/12/) RFC |
| `/admin` | Privileged access to the internal operations of the node. |
| `/private` | Provides functionality to encrypt/decrypt `WakuMessage` payloads using either symmetric or asymmetric cryptography. This allows backwards compatibility with Waku v1 nodes. |

The full HTTP REST API documentation can be found here: [TBD]() 

### API Specification

The HTTP REST API has been designed following the OpenAPI 3.0.3 standard specification format. The OpenAPI specification file can be found here: [TBD]()

Check the [OpenAPI Tools](https://openapi.tools/) site for the right tool for you (e.g. REST API client generator)


### Usage example

#### [`get_waku_v2_debug_v1_info`](https://rfc.vac.dev/spec/16/#get_waku_v2_debug_v1_info)

JSON-RPC call:

```bash
curl -d '{"jsonrpc":"2.0","method":"get_waku_v2_debug_v1_info","params":[],"id":1}' -H 'Content-Type: application/json' localhost:8645 -s | jq
```

Equivalent call for the REST API:

```bash
curl http://localhost:8645/debug/v1/info -s | jq
```


### Node configuration

A subset of the node configuration can be used to modify the behaviour of the HTTP REST API. These are the relevant command line options:

| CLI option | Description | Default value |
|------------|-------------|---------------|
|`--rest` | Enable Waku REST HTTP server. | `false` |
|`--rest-address` | Listening address of the REST HTTP server. | `127.0.0.1` |
|`--rest-port` | Listening port of the REST HTTP server. | `8645` |
|`--rest-relay-cache-capacity` | Capacity of the Relay REST API message cache. | `30` |
|`--rest-admin` | Enable access to REST HTTP Admin API. | `false` |
|`--rest-private` | Enable access to REST HTTP Private API. | `false` |

Note that these command line options have their counterpart option in the node configuration file.
