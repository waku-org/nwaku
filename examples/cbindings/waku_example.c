#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <argp.h>
#include <signal.h>
#include <unistd.h>
#include <stdint.h>

#include "libwaku.h"

// Keep a global string to store the waku call responses
static NimStringDesc wakuString;
NimStringDesc* mResp = &wakuString;

// Arguments parsing
static char doc[] = "C implementation of waku node v2.";
static char args_doc[] = "[CFG_FILE_PATH] Path to the configuration file.";

static struct argp_option options[] = {
    { "config-file", 'c', "CFG_FILE_PATH", 0, "Path to the configuration file."},
    { 0 }
};

struct arguments {
    char* configFilePath;
};

static error_t parse_opt(int key, char *arg, struct argp_state *state) {

    struct arguments *arguments = state->input;
    switch (key) {
        case 'c':
            arguments->configFilePath = arg;
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

void show_help_and_exit() {
    printf("Wrong parameters\n");
    exit(1);
}

void event_handler(char* msg) {
    printf("Receiving message [%s]\n", msg);
}

void handle_signal(int signo) {
    if (signo == SIGUSR1) {
        char* pubsubTopic = "another_pubsub_topic";

        char jsonWakuMsg[1024];
        char *msg = "Hello World!";
        char *msgPayload = b64_encode(msg, strlen(msg));

        waku_content_topic("appName",
                            1,
                            "contentTopicName",
                            "encoding",
                            &mResp);

        snprintf(jsonWakuMsg, 1024, "{\"payload\":\"%s\",\"content_topic\":\"%s\"}", msgPayload, mResp->data);
        free(msgPayload);

        printf("SIGUSR1 received \n");
        waku_relay_publish(pubsubTopic, jsonWakuMsg, 10000 /*timeout ms*/, &mResp);
        printf("waku relay response [%s]\n", mResp->data);
    }
}

int main(int argc, char** argv) {
    if (argc > 2) {
        show_help_and_exit();
    }

    struct arguments args;
    if (argp_parse(&argp, argc, argv, 0, 0, &args)
                    == ARGP_ERR_UNKNOWN) {
        show_help_and_exit();
    }

    if (signal(SIGUSR1, handle_signal) == SIG_ERR) {
        printf("Can't catch signal\n");
        exit(-1);
    }

    NimMain(); // initialize the Nim runtime

    waku_default_pubsub_topic(&mResp);

    printf("Default pubsub topic: [%s]\n", mResp->data);
    printf("Git Version: [%s]\n", waku_version());
    printf("Config file: [%s]\n", args.configFilePath);

    waku_new(args.configFilePath);
    waku_set_event_callback(event_handler);
    waku_relay_subscribe("another_pubsub_topic", &mResp);
    // waku_relay_unsubscribe("another_pubsub_topic", &mResp);

    printf("Waku Relay subscription response: [%s]\n", mResp->data);

    waku_start();
}
