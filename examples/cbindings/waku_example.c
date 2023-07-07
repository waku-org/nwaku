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
};

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

char* contentTopic = NULL;
void handle_content_topic(char* msg, size_t len) {
    if (contentTopic != NULL) {
        free(contentTopic);
    }

    contentTopic = malloc(len * sizeof(char) + 1);
    strcpy(contentTopic, msg);
}

char* publishResponse = NULL;
void handle_publish_ok(char* msg, size_t len) {
    printf("Publish Ok: %s %lu\n", msg, len);

    if (publishResponse != NULL) {
        free(publishResponse);
    }

    publishResponse = malloc(len * sizeof(char) + 1);
    strcpy(publishResponse, msg);
}

void handle_error(char* msg, size_t len) {
    printf("Error: %s\n", msg);
    exit(1);
}

#define MAX_MSG_SIZE 65535

void publish_message(char* pubsubTopic, char* msg) {
    char jsonWakuMsg[MAX_MSG_SIZE];
    char *msgPayload = b64_encode(msg, strlen(msg));

    WAKU_CALL( waku_content_topic("appName",
                                  1,
                                  "contentTopicName",
                                  "encoding",
                                  handle_content_topic) );

    snprintf(jsonWakuMsg,
             MAX_MSG_SIZE,
             "{\"payload\":\"%s\",\"content_topic\":\"%s\"}",
             msgPayload, contentTopic);

    free(msgPayload);

    WAKU_CALL( waku_relay_publish(pubsubTopic,
                                  jsonWakuMsg,
                                  10000 /*timeout ms*/,
                                  handle_publish_ok,
                                  handle_error) );

    printf("waku relay response [%s]\n", publishResponse);
}

void show_help_and_exit() {
    printf("Wrong parameters\n");
    exit(1);
}

void event_handler(char* msg, size_t len) {
    printf("Receiving message %s\n", msg);
}

void print_default_pubsub_topic(char* msg, size_t len) {
    printf("Default pubsub topic: %s\n", msg);
}

void print_waku_version(char* msg, size_t len) {
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

void set_scanf_to_not_block() {
    fcntl(0, F_SETFL, fcntl(0, F_GETFL) | O_NONBLOCK);
}

void set_scanf_to_block() {
    fcntl(0, F_SETFL, fcntl(0, F_GETFL) ^ O_NONBLOCK);
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
        set_scanf_to_block();
        char pubsubTopic[128];
        scanf("%127s", pubsubTopic);

        WAKU_CALL( waku_relay_subscribe(pubsubTopic,
                                        handle_error) );
        printf("The subscription went well\n");

        set_scanf_to_not_block();
        show_main_menu();
    }
    break;

    case CONNECT_TO_OTHER_NODE_MENU:
        printf("Connecting to a node. Please indicate the peer Multiaddress:\n");
        printf("e.g.: /ip4/127.0.0.1/tcp/60001/p2p/16Uiu2HAmVFXtAfSj4EiR7mL2KvL4EE2wztuQgUSBoj2Jx2KeXFLN\n");
        set_scanf_to_block();
        char peerAddr[512];
        scanf("%511s", peerAddr);
        WAKU_CALL(waku_connect(peerAddr, 10000 /* timeoutMs */, handle_error));
        set_scanf_to_not_block();
        show_main_menu();
    break;

    case PUBLISH_MESSAGE_MENU:
    {
        set_scanf_to_block();
        printf("Indicate the Pubsubtopic:\n");
        char pubsubTopic[128];
        scanf("%127s", pubsubTopic);

        printf("Type the message tp publish:\n");
        char msg[1024];
        scanf("%1023s", msg);

        publish_message(pubsubTopic, msg);

        set_scanf_to_not_block();
        show_main_menu();
    }
    break;

    case MAIN_MENU:
        break;
    }
}

// End of UI program logic

int main(int argc, char** argv) {

    waku_init_lib();

    struct ConfigNode cfgNode;
    // default values
    snprintf(cfgNode.host, 128, "0.0.0.0");
    cfgNode.port = 60000;
    cfgNode.relay = 1;

    if (argp_parse(&argp, argc, argv, 0, 0, &cfgNode)
                    == ARGP_ERR_UNKNOWN) {
        show_help_and_exit();
    }

    char jsonConfig[1024];
    snprintf(jsonConfig, 1024, "{ \
                                    \"host\": \"%s\",   \
                                    \"port\": %d,       \
                                    \"key\": \"%s\",    \
                                    \"relay\": %s       \
                                }", cfgNode.host,
                                    cfgNode.port,
                                    cfgNode.key,
                                    cfgNode.relay ? "true":"false");

    // To allow non-blocking 'reads' from stdin
    fcntl(0, F_SETFL, fcntl(0, F_GETFL) ^ O_NONBLOCK);

    WAKU_CALL( waku_default_pubsub_topic(print_default_pubsub_topic) );
    WAKU_CALL( waku_version(print_waku_version) );
    printf("Bind addr: %s:%u\n", cfgNode.host, cfgNode.port);
    printf("Waku Relay enabled: %s\n", cfgNode.relay == 1 ? "YES": "NO");

    WAKU_CALL( waku_new(jsonConfig, handle_error) );

    waku_set_relay_callback(event_handler);
    waku_start();

    printf("Establishing connection with: %s\n", cfgNode.peers);

    WAKU_CALL( waku_connect(cfgNode.peers,
                            10000 /* timeoutMs */,
                            handle_error) );

    WAKU_CALL( waku_relay_subscribe("/waku/2/default-waku/proto",
                                    handle_error) );
    show_main_menu();
    while(1) {
        handle_user_input();
        waku_poll();
    }
}
