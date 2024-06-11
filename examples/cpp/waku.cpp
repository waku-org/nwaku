#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <argp.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <vector>
#include <iostream>

#include <sys/types.h>
#include <unistd.h>
#include <sys/syscall.h>

#include "base64.h"
#include "../../library/libwaku.h"

#define WAKU_CALL(call)                                                        \
do {                                                                           \
  int ret = call;                                                              \
  if (ret != 0) {                                                              \
    std::cout << "Failed the call to: " << #call << ". Code: " << ret << "\n"; \
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

    struct ConfigNode *cfgNode = (ConfigNode *) state->input;
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
        // if (!waku_relay_subscribe(pubsubTopic, &mResp)) {
        //     printf("Error subscribing to PubsubTopic: %s\n", mResp->data);
        // }
        // printf("Waku Relay subscription response: %s\n", mResp->data);

        show_main_menu();
    }
    break;

    case CONNECT_TO_OTHER_NODE_MENU:
        printf("Connecting to a node. Please indicate the peer Multiaddress:\n");
        printf("e.g.: /ip4/127.0.0.1/tcp/60001/p2p/16Uiu2HAmVFXtAfSj4EiR7mL2KvL4EE2wztuQgUSBoj2Jx2KeXFLN\n");
        char peerAddr[512];
        scanf("%511s", peerAddr);
        // if (!waku_connect(peerAddr, 10000 /* timeoutMs */, &mResp)) {
        //     printf("Couldn't connect to the remote peer: %s\n", mResp->data);
        // }
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

        char jsonWakuMsg[1024];
        std::vector<char> msgPayload;
        b64_encode(msg, strlen(msg), msgPayload);

        // waku_content_topic("appName",
        //                     1,
        //                     "contentTopicName",
        //                     "encoding",
        //                     &mResp);

        // snprintf(jsonWakuMsg,
        //          1024,
        //          "{\"payload\":\"%s\",\"content_topic\":\"%s\"}",
        //          msgPayload, mResp->data);

        // free(msgPayload);

        // waku_relay_publish(pubsubTopic, jsonWakuMsg, 10000 /*timeout ms*/, &mResp);
        // printf("waku relay response [%s]\n", mResp->data);
        show_main_menu();
    }
    break;

    case MAIN_MENU:
        break;
    }
}

// End of UI program logic

void show_help_and_exit() {
    printf("Wrong parameters\n");
    exit(1);
}

void event_handler(const char* msg, size_t len) {
    printf("Receiving message %s\n", msg);
}

void handle_error(const char* msg, size_t len) {
    printf("Error: %s\n", msg);
    exit(1);
}

template <class F>
auto cify(F&& f) {
  static F fn = std::forward<F>(f);
  return [](const char* msg, size_t len) {
    return fn(msg, len);
  };
}

int main(int argc, char** argv) {
    waku_setup();

    struct ConfigNode cfgNode;
    // default values
    snprintf(cfgNode.host, 128, "0.0.0.0");
    snprintf(cfgNode.key, 128,
             "364d111d729a6eb6d2e6113e163f017b5ef03a6f94c9b5b7bb1bb36fa5cb07a9");
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
                                    \"relay\": %s,      \
                                    \"logLevel\": \"DEBUG\" \
                                }", cfgNode.host,
                                    cfgNode.port,
                                    cfgNode.key,
                                    cfgNode.relay ? "true":"false");

    WAKU_CALL(waku_new(jsonConfig, cify([](const char* msg, size_t len) {
        std::cout << "Error: " << msg << std::endl;
        exit(1);
    })));

    // example on how to retrieve a value from the `libwaku` callback.
    std::string defaultPubsubTopic;
    WAKU_CALL(waku_default_pubsub_topic(cify([&defaultPubsubTopic](const char* msg, size_t len) {
        defaultPubsubTopic = msg;
    })));

    std::cout << "Default pubsub topic: " << defaultPubsubTopic << std::endl;

    WAKU_CALL(waku_version(cify([&](const char* msg, size_t len) {
        std::cout << "Git Version: " << msg << std::endl;
    })));

    printf("Bind addr: %s:%u\n", cfgNode.host, cfgNode.port);
    printf("Waku Relay enabled: %s\n", cfgNode.relay == 1 ? "YES": "NO");

    std::string pubsubTopic;
    WAKU_CALL(waku_pubsub_topic("example", cify([&](const char* msg, size_t len) {
        pubsubTopic = msg;
    })));

    std::cout << "Custom pubsub topic: " << pubsubTopic << std::endl;

    waku_set_event_callback(event_handler);
    waku_start();

    WAKU_CALL( waku_connect(cfgNode.peers,
                        10000 /* timeoutMs */,
                        handle_error) );

    WAKU_CALL( waku_relay_subscribe(defaultPubsubTopic.c_str(),
                                    handle_error) );

    std::cout << "Establishing connection with: " << cfgNode.peers << std::endl;
    WAKU_CALL(waku_connect(cfgNode.peers, 10000 /* timeoutMs */, handle_error));

    show_main_menu();
    while(1) {
        handle_user_input();
    }
}
