#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <argp.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>

#include <sys/types.h>
#include <unistd.h>
#include <sys/syscall.h>

#include "waku.h"

// Keep a global string to store the waku call responses
static NimStringDesc wakuString;
NimStringDesc* mResp = &wakuString;

struct ConfigNode {
    NCSTRING host;
    NU       port;
    NCSTRING key;
    NIM_BOOL relay;
    NCSTRING peers;
};

static ConfigNode cfgNode;

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
            cfgNode->host = arg;
            break;
        case 'p':
            cfgNode->port = atoi(arg);
            break;
        case 'k':
            cfgNode->key = arg;
            break;
        case 'r':
            cfgNode->relay = atoi(arg);
            break;
        case 'a':
            cfgNode->peers = arg;
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

// Base64 encoding
// source: https://nachtimwald.com/2017/11/18/base64-encode-and-decode-in-c/
size_t b64_encoded_size(size_t inlen)
{
	size_t ret;

	ret = inlen;
	if (inlen % 3 != 0)
		ret += 3 - (inlen % 3);
	ret /= 3;
	ret *= 4;

	return ret;
}

const char b64chars[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

char *b64_encode(const unsigned char *in, size_t len)
{
	char   *out;
	size_t  elen;
	size_t  i;
	size_t  j;
	size_t  v;

	if (in == NULL || len == 0)
		return NULL;

	elen = b64_encoded_size(len);
	out  = malloc(elen+1);
	out[elen] = '\0';

	for (i=0, j=0; i<len; i+=3, j+=4) {
		v = in[i];
		v = i+1 < len ? v << 8 | in[i+1] : v << 8;
		v = i+2 < len ? v << 8 | in[i+2] : v << 8;

		out[j]   = b64chars[(v >> 18) & 0x3F];
		out[j+1] = b64chars[(v >> 12) & 0x3F];
		if (i+1 < len) {
			out[j+2] = b64chars[(v >> 6) & 0x3F];
		} else {
			out[j+2] = '=';
		}
		if (i+2 < len) {
			out[j+3] = b64chars[v & 0x3F];
		} else {
			out[j+3] = '=';
		}
	}

	return out;
}

// End of Base64 encoding

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
        if (!waku_relay_subscribe(pubsubTopic, &mResp)) {
            printf("Error subscribing to PubsubTopic: %s\n", mResp->data);
        }
        printf("Waku Relay subscription response: %s\n", mResp->data);

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
        if (!waku_connect(peerAddr, 10000 /* timeoutMs */, &mResp)) {
            printf("Couldn't connect to the remote peer: %s\n", mResp->data);
        }
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

        char jsonWakuMsg[1024];
        char *msgPayload = b64_encode(msg, strlen(msg));

        waku_content_topic("appName",
                            1,
                            "contentTopicName",
                            "encoding",
                            &mResp);

        snprintf(jsonWakuMsg, 1024, "{\"payload\":\"%s\",\"content_topic\":\"%s\"}", msgPayload, mResp->data);
        free(msgPayload);

        waku_relay_publish(pubsubTopic, jsonWakuMsg, 10000 /*timeout ms*/, &mResp);
        printf("waku relay response [%s]\n", mResp->data);
        set_scanf_to_not_block();
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

void event_handler(char* msg) {
    printf("Receiving message [%s]\n", msg);
}

int main(int argc, char** argv) {
    // default values
    cfgNode.host = "0.0.0.0";
    cfgNode.port = 60000;
    cfgNode.relay = 1;
    cfgNode.peers = NULL;

    if (argp_parse(&argp, argc, argv, 0, 0, &cfgNode)
                    == ARGP_ERR_UNKNOWN) {
        show_help_and_exit();
    }

    // To allow non-blocking 'reads' from stdin
    fcntl(0, F_SETFL, fcntl(0, F_GETFL) ^ O_NONBLOCK);

    NimMain(); // initialize the Nim runtime

    waku_default_pubsub_topic(&mResp);
    printf("Default pubsub topic: %s\n", mResp->data);
    printf("Git Version: %s\n", waku_version());
    printf("Bind addr: %s:%u\n", cfgNode.host, cfgNode.port);
    printf("Waku Relay enabled: %s\n", cfgNode.relay == 1 ? "YES": "NO");

    if (!waku_new(&cfgNode, &mResp)) {
        printf("Error creating WakuNode: %s\n", mResp->data);
        exit(-1);
    }

    waku_set_event_callback(event_handler);
    waku_start();

    printf("Establishing connection with: %s\n", cfgNode.peers);
    if (!waku_connect(cfgNode.peers, 10000 /* timeoutMs */, &mResp)) {
        printf("Couldn't connect to the remote peer: %s\n", mResp->data);
    }

    show_main_menu();
    while(1) {
        handle_user_input();
        waku_poll();
    }
}
