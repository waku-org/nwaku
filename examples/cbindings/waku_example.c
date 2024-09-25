#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <argp.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>

#include <sys/types.h>
#include <unistd.h>
#include <sys/syscall.h>

#include "base64.h"
#include "../../library/libwaku.h"

#define WAKU_CALL(call)                                                        \
do {                                                                           \
  int ret = call;                                                              \
  if (ret != 0) {                                                              \
    printf("Failed the call to: %s. Returned code: %d\n", #call, ret);         \
    exit(1);                                                                   \
  }                                                                            \
} while (0)

struct ConfigNode {
    char    host[128];
    int          port;
    char     key[128];
    int         relay;
    char  peers[2048];
    int         store;
    char storeNode[2048];
    char storeRetentionPolicy[64];
    char storeDbUrl[256];
    int                 storeVacuum;
    int            storeDbMigration;
    int    storeMaxNumDbConnections;
};

// libwaku Context
void* ctx;

// For the case of C language we don't need to store a particular userData
void* userData = NULL;

// Arguments parsing
static char doc[] = "\nC example that shows how to use the waku library.";
static char args_doc[] = "";

static struct argp_option options[] = {
    { "host",  'h', "HOST",  0, "IP to listen for for LibP2P traffic. (default: \"0.0.0.0\")"},
    { "port",  'p', "PORT",  0, "TCP listening port. (default: \"60000\")"},
    { "key",   'k', "KEY",   0, "P2P node private key as 64 char hex string."},
    { "relay", 'r', "RELAY", 0, "Enable relay protocol: 1 or 0. (default: 1)"},
    { "peers", 'a', "PEERS", 0, "Comma-separated list of peer-multiaddress to connect\
 to. (default: \"\") e.g. \"/ip4/127.0.0.1/tcp/60001/p2p/16Uiu2HAmVFXtAfSj4EiR7mL2KvL4EE2wztuQgUSBoj2Jx2KeXFLN\""},
    { 0 }
};

static error_t parse_opt(int key, char *arg, struct argp_state *state) {

    struct ConfigNode *cfgNode = state->input;
    switch (key) {
        case 'h':
            snprintf(cfgNode->host, 128, "%s", arg);
            break;
        case 'p':
            cfgNode->port = atoi(arg);
            break;
        case 'k':
            snprintf(cfgNode->key, 128, "%s", arg);
            break;
        case 'r':
            cfgNode->relay = atoi(arg);
            break;
        case 'a':
            snprintf(cfgNode->peers, 2048, "%s", arg);
            break;
        case ARGP_KEY_ARG:
            if (state->arg_num >= 1) /* Too many arguments. */
            argp_usage(state);
            break;
        case ARGP_KEY_END:
            break;
        default:
            return ARGP_ERR_UNKNOWN;
        }

    return 0;
}

static struct argp argp = { options, parse_opt, args_doc, doc, 0, 0, 0 };

void event_handler(int callerRet, const char* msg, size_t len, void* userData) {
    if (callerRet == RET_ERR) {
        printf("Error: %s\n", msg);
        exit(1);
    }
    else if (callerRet == RET_OK) {
        printf("Receiving event: %s\n", msg);
    }
}

char* contentTopic = NULL;
void handle_content_topic(int callerRet, const char* msg, size_t len, void* userData) {
    if (contentTopic != NULL) {
        free(contentTopic);
    }

    contentTopic = malloc(len * sizeof(char) + 1);
    strcpy(contentTopic, msg);
}

char* publishResponse = NULL;
void handle_publish_ok(int callerRet, const char* msg, size_t len, void* userData) {
    printf("Publish Ok: %s %lu\n", msg, len);

    if (publishResponse != NULL) {
        free(publishResponse);
    }

    publishResponse = malloc(len * sizeof(char) + 1);
    strcpy(publishResponse, msg);
}

#define MAX_MSG_SIZE 65535

void publish_message(char* pubsubTopic, const char* msg) {
    char jsonWakuMsg[MAX_MSG_SIZE];
    char *msgPayload = b64_encode(msg, strlen(msg));

    WAKU_CALL( waku_content_topic(RET_OK,
                                  "appName",
                                  1,
                                  "contentTopicName",
                                  "encoding",
                                  handle_content_topic,
                                  userData) );

    snprintf(jsonWakuMsg,
             MAX_MSG_SIZE,
             "{\"payload\":\"%s\",\"content_topic\":\"%s\"}",
             msgPayload, contentTopic);

    free(msgPayload);

    WAKU_CALL( waku_relay_publish(&ctx,
                                  pubsubTopic,
                                  jsonWakuMsg,
                                  10000 /*timeout ms*/,
                                  event_handler,
                                  userData) );

    printf("waku relay response [%s]\n", publishResponse);
}

void show_help_and_exit() {
    printf("Wrong parameters\n");
    exit(1);
}

void print_default_pubsub_topic(int callerRet, const char* msg, size_t len, void* userData) {
    printf("Default pubsub topic: %s\n", msg);
}

void print_waku_version(int callerRet, const char* msg, size_t len, void* userData) {
    printf("Git Version: %s\n", msg);
}

// Beginning of UI program logic

enum PROGRAM_STATE {
    MAIN_MENU,
    SUBSCRIBE_TOPIC_MENU,
    CONNECT_TO_OTHER_NODE_MENU,
    PUBLISH_MESSAGE_MENU
};

enum PROGRAM_STATE current_state = MAIN_MENU;

void show_main_menu() {
    printf("\nPlease, select an option:\n");
    printf("\t1.) Subscribe to topic\n");
    printf("\t2.) Connect to other node\n");
    printf("\t3.) Publish a message\n");
}

void handle_user_input() {
    char cmd[1024];
    memset(cmd, 0, 1024);
    int numRead = read(0, cmd, 1024);
    if (numRead <= 0) {
        return;
    }

    int c;
    while ( (c = getchar()) != '\n' && c != EOF ) { }

    switch (atoi(cmd))
    {
    case SUBSCRIBE_TOPIC_MENU:
    {
        printf("Indicate the Pubsubtopic to subscribe:\n");
        char pubsubTopic[128];
        scanf("%127s", pubsubTopic);

        WAKU_CALL( waku_relay_subscribe(&ctx,
                                        pubsubTopic,
                                        event_handler,
                                        userData) );
        printf("The subscription went well\n");

        show_main_menu();
    }
    break;

    case CONNECT_TO_OTHER_NODE_MENU:
        printf("Connecting to a node. Please indicate the peer Multiaddress:\n");
        printf("e.g.: /ip4/127.0.0.1/tcp/60001/p2p/16Uiu2HAmVFXtAfSj4EiR7mL2KvL4EE2wztuQgUSBoj2Jx2KeXFLN\n");
        char peerAddr[512];
        scanf("%511s", peerAddr);
        WAKU_CALL(waku_connect(&ctx, peerAddr, 10000 /* timeoutMs */, event_handler, userData));
        show_main_menu();
    break;

    case PUBLISH_MESSAGE_MENU:
    {
        printf("Indicate the Pubsubtopic:\n");
        char pubsubTopic[128];
        scanf("%127s", pubsubTopic);

        printf("Type the message tp publish:\n");
        char msg[1024];
        scanf("%1023s", msg);

        publish_message(pubsubTopic, msg);

        show_main_menu();
    }
    break;

    case MAIN_MENU:
        break;
    }
}

// End of UI program logic

int main(int argc, char** argv) {
    waku_setup();

    struct ConfigNode cfgNode;
    // default values
    snprintf(cfgNode.host, 128, "0.0.0.0");
    cfgNode.port = 60000;
    cfgNode.relay = 1;

    cfgNode.store = 1;
    snprintf(cfgNode.storeNode, 2048, "");
    snprintf(cfgNode.storeRetentionPolicy, 64, "time:6000000");
    snprintf(cfgNode.storeDbUrl, 256, "postgres://postgres:test123@localhost:5432/postgres");
    cfgNode.storeVacuum = 0;
    cfgNode.storeDbMigration = 0;
    cfgNode.storeMaxNumDbConnections = 30;

    if (argp_parse(&argp, argc, argv, 0, 0, &cfgNode)
                    == ARGP_ERR_UNKNOWN) {
        show_help_and_exit();
    }

    char jsonConfig[5000];
    snprintf(jsonConfig, 5000, "{ \
                                    \"listenAddress\": \"%s\",    \
                                    \"tcpPort\": %d,        \
                                    \"nodekey\": \"%s\",     \
                                    \"relay\": %s,       \
                                    \"store\": %s,       \
                                    \"storeMessageDbUrl\": \"%s\",  \
                                    \"storeMessageRetentionPolicy\": \"%s\",  \
                                    \"storeMaxNumDbConnections\": %d , \
                                    \"logLevel\": \"DEBUG\", \
                                    \"discv5Discovery\": true, \
                                    \"discv5BootstrapNodes\": \
                                        [\"enr:-QESuEB4Dchgjn7gfAvwB00CxTA-nGiyk-aALI-H4dYSZD3rUk7bZHmP8d2U6xDiQ2vZffpo45Jp7zKNdnwDUx6g4o6XAYJpZIJ2NIJpcIRA4VDAim11bHRpYWRkcnO4XAArNiZub2RlLTAxLmRvLWFtczMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQZ2XwAtNiZub2RlLTAxLmRvLWFtczMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQOvD3S3jUNICsrOILlmhENiWAMmMVlAl6-Q8wRB7hidY4N0Y3CCdl-DdWRwgiMohXdha3UyDw\", \"enr:-QEkuEBIkb8q8_mrorHndoXH9t5N6ZfD-jehQCrYeoJDPHqT0l0wyaONa2-piRQsi3oVKAzDShDVeoQhy0uwN1xbZfPZAYJpZIJ2NIJpcIQiQlleim11bHRpYWRkcnO4bgA0Ni9ub2RlLTAxLmdjLXVzLWNlbnRyYWwxLWEud2FrdS5zYW5kYm94LnN0YXR1cy5pbQZ2XwA2Ni9ub2RlLTAxLmdjLXVzLWNlbnRyYWwxLWEud2FrdS5zYW5kYm94LnN0YXR1cy5pbQYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQKnGt-GSgqPSf3IAPM7bFgTlpczpMZZLF3geeoNNsxzSoN0Y3CCdl-DdWRwgiMohXdha3UyDw\"], \
                                    \"discv5UdpPort\": 9999, \
                                    \"dnsDiscovery\": true, \
                                    \"dnsDiscoveryUrl\": \"enrtree://AOGYWMBYOUIMOENHXCHILPKY3ZRFEULMFI4DOM442QSZ73TT2A7VI@test.waku.nodes.status.im\", \
                                    \"dnsDiscoveryNameServers\": [\"8.8.8.8\", \"1.0.0.1\"] \
                                }", cfgNode.host,
                                    cfgNode.port,
                                    cfgNode.key,
                                    cfgNode.relay ? "true":"false",
                                    cfgNode.store ? "true":"false",
                                    cfgNode.storeDbUrl,
                                    cfgNode.storeRetentionPolicy,
                                    cfgNode.storeMaxNumDbConnections);

    ctx = waku_new(jsonConfig, event_handler, userData);

    WAKU_CALL( waku_default_pubsub_topic(ctx, print_default_pubsub_topic, userData) );
    WAKU_CALL( waku_version(ctx, print_waku_version, userData) );

    printf("Bind addr: %s:%u\n", cfgNode.host, cfgNode.port);
    printf("Waku Relay enabled: %s\n", cfgNode.relay == 1 ? "YES": "NO");

    waku_set_event_callback(ctx, event_handler, userData);
    waku_start(ctx, event_handler, userData);

    waku_listen_addresses(ctx, event_handler, userData);

    printf("Establishing connection with: %s\n", cfgNode.peers);

    WAKU_CALL( waku_connect(ctx,
                            cfgNode.peers,
                            10000 /* timeoutMs */,
                            event_handler,
                            userData) );

    WAKU_CALL( waku_relay_subscribe(ctx,
                                    "/waku/2/rs/0/0",
                                    event_handler,
                                    userData) );

    WAKU_CALL( waku_discv5_update_bootnodes(ctx,
                                  "[\"enr:-QEkuEBIkb8q8_mrorHndoXH9t5N6ZfD-jehQCrYeoJDPHqT0l0wyaONa2-piRQsi3oVKAzDShDVeoQhy0uwN1xbZfPZAYJpZIJ2NIJpcIQiQlleim11bHRpYWRkcnO4bgA0Ni9ub2RlLTAxLmdjLXVzLWNlbnRyYWwxLWEud2FrdS5zYW5kYm94LnN0YXR1cy5pbQZ2XwA2Ni9ub2RlLTAxLmdjLXVzLWNlbnRyYWwxLWEud2FrdS5zYW5kYm94LnN0YXR1cy5pbQYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQKnGt-GSgqPSf3IAPM7bFgTlpczpMZZLF3geeoNNsxzSoN0Y3CCdl-DdWRwgiMohXdha3UyDw\",\"enr:-QEkuEB3WHNS-xA3RDpfu9A2Qycr3bN3u7VoArMEiDIFZJ66F1EB3d4wxZN1hcdcOX-RfuXB-MQauhJGQbpz3qUofOtLAYJpZIJ2NIJpcIQI2SVcim11bHRpYWRkcnO4bgA0Ni9ub2RlLTAxLmFjLWNuLWhvbmdrb25nLWMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQZ2XwA2Ni9ub2RlLTAxLmFjLWNuLWhvbmdrb25nLWMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQPK35Nnz0cWUtSAhBp7zvHEhyU_AqeQUlqzLiLxfP2L4oN0Y3CCdl-DdWRwgiMohXdha3UyDw\"]",
                                  event_handler,
                                  userData) );

    WAKU_CALL( waku_get_peerids_from_peerstore(ctx,
                                  event_handler,
                                  userData) );

    show_main_menu();
    while(1) {
        handle_user_input();
    }
}
