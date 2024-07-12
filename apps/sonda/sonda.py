import requests
import time
import json
import os
import base64
import sys
import urllib.parse
import requests
import argparse
from prometheus_client import Counter, Gauge, start_http_server

# Content topic where Sona messages are going to be sent
SONDA_CONTENT_TOPIC = '/sonda/2/polls/proto'

# Prometheus metrics
successful_sonda_msgs = Counter('successful_sonda_msgs', 'Number of successful Sonda messages sent')
failed_sonda_msgs = Counter('failed_sonda_msgs', 'Number of failed Sonda messages attempts')
successful_store_queries = Counter('successful_store_queries', 'Number of successful store queries', ['node'])
failed_store_queries = Counter('failed_store_queries', 'Number of failed store queries', ['node', 'error'])
empty_store_responses = Counter('empty_store_responses', "Number of store responses without the latest Sonda message", ['node'])
store_query_latency = Gauge('store_query_latency', 'Latency of the last store query in seconds', ['node'])
consecutive_successful_responses = Gauge('consecutive_successful_responses', 'Consecutive successful store responses', ['node'])
node_health = Gauge('node_health', "Binary indicator of a node's health. 1 is healthy, 0 is not", ['node'])


# Argparser configuration
parser = argparse.ArgumentParser(description='')
parser.add_argument('-p', '--pubsub-topic', type=str, help='pubsub topic', default='/waku/2/rs/1/0')
parser.add_argument('-d', '--delay-seconds', type=int, help='delay in second between messages', default=60)
parser.add_argument('-n', '--store-nodes', type=str, help='comma separated list of store nodes to query', required=True)
parser.add_argument('-t', '--health-threshold', type=int, help='consecutive successful store requests to consider a store node healthy', default=5)
args = parser.parse_args()


# Sends Sonda message. Returns True if successful, False otherwise
def send_sonda_msg(rest_address, pubsub_topic, content_topic, timestamp):
    message = "Hi, I'm Sonda"
    base64_message = base64.b64encode(message.encode('utf-8')).decode('ascii')
    body = {
        'payload': base64_message,
        'contentTopic': content_topic,
        'version': 1,
        'timestamp': timestamp
    }

    encoded_pubsub_topic = urllib.parse.quote(pubsub_topic, safe='')
    url = f'{rest_address}/relay/v1/messages/{encoded_pubsub_topic}'
    headers = {'content-type': 'application/json'}

    print(f'Waku REST API: {url} PubSubTopic: {pubsub_topic}, ContentTopic: {content_topic}')
    
    try:
        start_time = time.time()
        response = requests.post(url, json=body, headers=headers, timeout=10)
        elapsed_seconds = time.time() - start_time
        
        print(f'Response from {rest_address}: status:{response.status_code} content:{response.text} [{elapsed_seconds:.4f} s.]')
        
        if response.status_code == 200:
            successful_sonda_msgs.inc()
            return True
        else:
            response.raise_for_status()
    except requests.RequestException as e:
        print(f'Error sending request: {e}')
    
    failed_sonda_msgs.inc()
    return False


# We return true if both our node and the queried Store node returned a 200
# If our message isn't found but we did get a store 200 response, this function still returns true
def check_store_response(json_response, store_node, timestamp):
  # Check for the store node status code
  if json_response.get('statusCode') != 200:
    error = f"{json_response.get('statusCode')} {json_response.get('statusDesc')}"
    print(f'Failed performing store query {error}')
    failed_store_queries.labels(node=store_node, error=error).inc()
    consecutive_successful_responses.labels(node=store_node).set(0)
    
    return False
  
  messages = json_response.get('messages')
  # If there's no message in the response, increase counters and return
  if not messages:
    print("No messages in store response")
    empty_store_responses.labels(node=store_node).inc()
    consecutive_successful_responses.labels(node=store_node).set(0)
    return True

  # Search for the Sonda message in the returned messages
  for message in messages:
    # If message field is missing in current message, continue
    if not message.get("message"):
      print("Could not retrieve message")
      continue
    
    # If a message is found with the same timestamp as sonda message, increase counters and return
    if timestamp == message.get('message').get('timestamp'):
      print(f'Found Sonda message in store response node={store_node}')
      successful_store_queries.labels(node=store_node).inc()
      consecutive_successful_responses.labels(node=store_node).inc()
      return True

  # If our message wasn't found in the returned messages, increase counter and return
  empty_store_responses.labels(node=store_node).inc()
  consecutive_successful_responses.labels(node=store_node).set(0)
  return True


def send_store_query(rest_address, store_node, encoded_pubsub_topic, encoded_content_topic, timestamp):
    url = f'{rest_address}/store/v3/messages'
    params = {
        'peerAddr': urllib.parse.quote(store_node, safe=''), 
        'pubsubTopic': encoded_pubsub_topic,
        'contentTopics': encoded_content_topic, 
        'includeData': 'true', 
        'startTime': timestamp
    }
    
    s_time = time.time()
    
    try:
        print(f'Sending store request to {store_node}')
        response = requests.get(url, params=params)
    except Exception as e:
      print(f'Error sending request: {e}')
      failed_store_queries.labels(node=store_node, error=str(e)).inc()
      consecutive_successful_responses.labels(node=store_node).set(0)
      return False

    elapsed_seconds = time.time() - s_time
    print(f'Response from {rest_address}: status:{response.status_code} [{elapsed_seconds:.4f} s.]')

    if response.status_code != 200:
        failed_store_queries.labels(node=store_node, error=f'{response.status_code} {response.content}').inc()
        consecutive_successful_responses.labels(node=store_node).set(0)
        return False

    # Parse REST response into JSON
    try:
        json_response = response.json()
    except Exception as e:
        print(f'Error parsing response JSON: {e}')
        failed_store_queries.labels(node=store_node, error="JSON parse error").inc()
        consecutive_successful_responses.labels(node=store_node).set(0)
        return False

    # Analyze Store response. Return false if response is incorrect or has an error status
    if not check_store_response(json_response, store_node, timestamp):
        return False

    store_query_latency.labels(node=store_node).set(elapsed_seconds)
    return True


def send_store_queries(rest_address, store_nodes, pubsub_topic, content_topic, timestamp):
    print(f'Sending store queries. nodes = {store_nodes}')
    encoded_pubsub_topic = urllib.parse.quote(pubsub_topic, safe='')
    encoded_content_topic = urllib.parse.quote(content_topic, safe='')
    
    for node in store_nodes:
      send_store_query(rest_address, node, encoded_pubsub_topic, encoded_content_topic, timestamp)


def main():
  print(f'Running Sonda with args={args}')

  store_nodes = []
  if args.store_nodes is not None:
      store_nodes = [s.strip() for s in args.store_nodes.split(",")]
  print(f'Store nodes to query: {store_nodes}')

  # Start Prometheus HTTP server at port 8004
  start_http_server(8004)

  node_rest_address = 'http://nwaku:8645'
  while True:
    timestamp = time.time_ns()
      
    # Send Sonda message
    res = send_sonda_msg(node_rest_address, args.pubsub_topic, SONDA_CONTENT_TOPIC, timestamp)

    print(f'sleeping: {args.delay_seconds} seconds')
    time.sleep(args.delay_seconds)

    # Only send store query if message was successfully published
    if(res):
      send_store_queries(node_rest_address, store_nodes, args.pubsub_topic, SONDA_CONTENT_TOPIC, timestamp)
    
    # Update node health metrics
    for store_node in store_nodes:
      if consecutive_successful_responses.labels(node=store_node)._value.get() >= args.health_threshold:
        node_health.labels(node=store_node).set(1)
      else:
        node_health.labels(node=store_node).set(0)


main()
