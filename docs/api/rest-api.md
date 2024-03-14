## HTTP REST API

The HTTP REST API consists of a set of methods operating on the Waku Node remotely over HTTP.

This API is divided in different _namespaces_ which group a set of resources:

| Namespace | Description |
------------|--------------
| `/debug` | Information about a Waku v2 node. |
| `/relay` | Control of the relaying of messages. See [11/WAKU2-RELAY](https://rfc.vac.dev/spec/11/) RFC |
| `/store` | Retrieve the message history. See [13/WAKU2-STORE](https://rfc.vac.dev/spec/13/) RFC |
| `/filter` | Control of the content filtering. See [12/WAKU2-FILTER](https://rfc.vac.dev/spec/12/) RFC |
| `/admin` | Privileged access to the internal operations of the node. |
| `/private` | Provides functionality to encrypt/decrypt `WakuMessage` payloads using either symmetric or asymmetric cryptography. This allows backwards compatibility with Waku v1 nodes. |


### API Specification

The HTTP REST API has been designed following the OpenAPI 3.0.3 standard specification format.
The OpenAPI specification files can be found here:

| Namespace | OpenAPI file |
------------|--------------
| `/debug` | [openapi.yaml](https://github.com/waku-org/nwaku/blob/master/waku/v2/node/rest/debug/openapi.yaml) |
| `/relay` | [openapi.yaml](https://github.com/waku-org/nwaku/blob/master/waku/v2/node/rest/relay/openapi.yaml) |
| `/store` | [openapi.yaml](https://github.com/waku-org/nwaku/blob/master/waku/v2/node/rest/store/openapi.yaml) |
| `/filter` | [openapi.yaml](https://github.com/waku-org/nwaku/blob/master/waku/v2/node/rest/filter/openapi.yaml) |

The OpenAPI files can be analysed online with [Redocly](https://redocly.github.io/redoc/)

Check the [OpenAPI Tools](https://openapi.tools/) site for the right tool for you (e.g. REST API client generator)

A particular OpenAPI spec can be easily imported into [Postman](https://www.postman.com/downloads/)
  1. Open Postman.
  2. Click on File -> Import...
  2. Load the openapi.yaml of interest, stored in your computer.
  3. Then, requests can be made from within the 'Collections' section.


### Usage example

#### [`get_waku_v2_debug_v1_info`](https://rfc.vac.dev/spec/16/#get_waku_v2_debug_v1_info)

```bash
curl http://localhost:8645/debug/v1/info -s | jq
```


### Node configuration
Find details [here](https://github.com/waku-org/nwaku/tree/master/docs/operators/how-to/configure-rest-api.md)
