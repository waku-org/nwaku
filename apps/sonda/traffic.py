import requests
import time
import json
import os
import base64
import sys
import urllib.parse
import requests
import argparse

def send_waku_msg(node_address, kbytes, pubsub_topic, content_topic):
    # TODO dirty trick .replace("=", "")
    base64_payload = (base64.b64encode(os.urandom(kbytes*1000)).decode('ascii')).replace("=", "")
    print("size message kBytes", len(base64_payload) *(3/4)/1000, "KBytes")
    body = {
        "payload": base64_payload,
        "contentTopic": content_topic,
        "version": 1,  # You can adjust the version as needed
        #"timestamp": int(time.time())
    }

    encoded_pubsub_topic = urllib.parse.quote(pubsub_topic, safe='')

    url = f"{node_address}/relay/v1/messages/{encoded_pubsub_topic}"
    headers = {'content-type': 'application/json'}

    print('Waku REST API: %s PubSubTopic: %s, ContentTopic: %s' % (url, pubsub_topic, content_topic))
    s_time = time.time()
    
    response = None

    try:
      print("Sending request")
      response = requests.post(url, json=body, headers=headers)
    except Exception as e:
      print(f"Error sending request: {e}")

    if(response != None):
      elapsed_ms = (time.time() - s_time) * 1000
      print('Response from %s: status:%s content:%s [%.4f ms.]' % (node_address, \
        response.status_code, response.text, elapsed_ms))

parser = argparse.ArgumentParser(description='')



parser.add_argument('-p', '--pubsub-topic', type=str, help='pubsub topic', default="/waku/2/rs/1/0")
parser.add_argument('-s', '--msg-size-kbytes', type=int, help='message size in kBytes', default=10)
parser.add_argument('-d', '--delay-seconds', type=int, help='delay in second between messages', default=60)
parser.add_argument('-n', '--store-nodes', type=str, help='comma separated list of store nodes to query', required=True)
args = parser.parse_args()

print(args)

nodes = []
if args.store_nodes is not None:
    nodes = [s.strip() for s in args.store_nodes.split(",")]
print(nodes)

while True:
    # calls are blocking
    # limited by the time it takes the REST API to reply

    send_waku_msg('http://nwaku:8645', args.msg_size_kbytes, args.pubsub_topic, "random_content_topic")

    print("sleeping: ", args.delay_seconds, " seconds")
    time.sleep(args.delay_seconds)