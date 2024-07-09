import requests
import time
import json
import os
import base64
import sys
import urllib.parse
import requests
import argparse
from prometheus_client import Counter, start_http_server

# Initialize Prometheus metrics
successful_sonda_msgs = Counter('successful_sonda_msgs', 'Number of successful Sonda messages sent')
successful_store_queries = Counter('successful_store_queries', 'Number of successful store queries')

def send_sonda_msg(rest_address, pubsub_topic, content_topic, timestamp):
    
    message = "Hi, I'm Sonda"
    base64_message = base64.b64encode(message.encode('utf-8')).decode('ascii')
    body = {
        'payload': base64_message,
        'contentTopic': content_topic,
        'version': 1,  # You can adjust the version as needed
        'timestamp': timestamp
    }

    encoded_pubsub_topic = urllib.parse.quote(pubsub_topic, safe='')

    url = f'{rest_address}/relay/v1/messages/{encoded_pubsub_topic}'
    headers = {'content-type': 'application/json'}

    print('Waku REST API: %s PubSubTopic: %s, ContentTopic: %s' % (url, pubsub_topic, content_topic))
    s_time = time.time()
    
    response = None

    try:
      print('Sending request')
      response = requests.post(url, json=body, headers=headers)
    except Exception as e:
      print(f'Error sending request: {e}')

    if(response != None):
      elapsed_ms = (time.time() - s_time) * 1000
      print('Response from %s: status:%s content:%s [%.4f ms.]' % (rest_address, \
        response.status_code, response.text, elapsed_ms))
    
      if(response.status_code == 200):
        successful_sonda_msgs.inc()  # Increment the counter
        return True
    
    return False

parser = argparse.ArgumentParser(description='')

def send_store_query(rest_address, store_node, encoded_pubsub_topic, encoded_content_topic, timestamp):
    url = f'{rest_address}/store/v3/messages'
    params = {'peerAddr': urllib.parse.quote(store_node, safe=''), 'pubsubTopic': encoded_pubsub_topic, \
      'contentTopics': encoded_content_topic, 'includeData': 'true', 'startTime': timestamp}
    
    s_time = time.time()
    response = None
    
    try:
      print(f'Sending store request to {store_node}')
      response = requests.get(url, params=params)
    except Exception as e:
      print(f'Error sending request: {e}')
    
    if(response != None):
      elapsed_ms = (time.time() - s_time) * 1000
      print('Response from %s: status:%s content:%s [%.4f ms.]' % (rest_address, \
        response.status_code, response.text, elapsed_ms))
      
      if(response.status_code == 200):
        successful_store_queries.inc() # Increment the counter
        return True
    
    return False
    


def send_store_queries(rest_address, store_nodes, pubsub_topic, content_topic, timestamp):
    print(f'Sending store queries. nodes = {store_nodes}')
    encoded_pubsub_topic = urllib.parse.quote(pubsub_topic, safe='')
    encoded_content_topic = urllib.parse.quote(content_topic, safe='')
    
    for node in store_nodes:
      send_store_query(rest_address, node, encoded_pubsub_topic, encoded_content_topic, timestamp)


parser.add_argument('-p', '--pubsub-topic', type=str, help='pubsub topic', default='/waku/2/rs/1/0')
parser.add_argument('-s', '--msg-size-kbytes', type=int, help='message size in kBytes', default=10)
parser.add_argument('-d', '--delay-seconds', type=int, help='delay in second between messages', default=60)
parser.add_argument('-n', '--store-nodes', type=str, help='comma separated list of store nodes to query', required=True)
args = parser.parse_args()

print(args)

store_nodes = []
if args.store_nodes is not None:
    store_nodes = [s.strip() for s in args.store_nodes.split(",")]
print(store_nodes)

# Start Prometheus HTTP server at port 8004
start_http_server(8004)

sonda_content_topic = '/sonda/2/polls/proto'
node_rest_address = 'http://nwaku:8645'
while True:
    # calls are blocking
    # limited by the time it takes the REST API to reply

    timestamp = time.time_ns()
    
    res = send_sonda_msg(node_rest_address, args.pubsub_topic, sonda_content_topic, timestamp)

    print(f'sleeping: {args.delay_seconds} seconds')
    time.sleep(args.delay_seconds)

    # Only send store query if message was successfully published
    if(res):
      send_store_queries(node_rest_address, store_nodes, args.pubsub_topic, sonda_content_topic, timestamp)
