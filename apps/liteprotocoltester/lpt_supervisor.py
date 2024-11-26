#!/usr/bin/env python3

import os
import time
from subprocess import Popen
import sys

def load_env(file_path):
  predefined_test_env = {}
  with open(file_path) as f:
    for line in f:
      if line.strip() and not line.startswith('#'):
        key, value = line.strip().split('=', 1)
        predefined_test_env[key] = value
  return predefined_test_env

def run_tester_node(predefined_test_env):
  role = sys.argv[1]
  # override incoming environment variables with the ones from the file to prefer predefined testing environment.
  for key, value in predefined_test_env.items():
      os.environ[key] = value

  script_cmd = "/usr/bin/run_tester_node_at_infra.sh /usr/bin/liteprotocoltester {role}".format(role=role)
  return os.system(script_cmd)

if __name__ == "__main__":
  if len(sys.argv) < 2 or sys.argv[1] not in ["RECEIVER", "SENDER"]:
    print("Error: First argument must be either 'RECEIVER' or 'SENDER'")
    sys.exit(1)

  predefined_test_env_file = '/usr/bin/infra.env'
  predefined_test_env = load_env(predefined_test_env_file)

  test_interval_minutes = int(predefined_test_env.get('TEST_INTERVAL_MINUTES', 60))  # Default to 60 minutes if not set
  print(f"supervisor: Start testing loop. Interval is {test_interval_minutes} minutes")
  counter = 0

  while True:
    counter += 1
    start_time = time.time()
    print(f"supervisor: Run #{counter} started at {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(start_time))}")
    print(f"supervisor: with arguments: {predefined_test_env}")

    exit_code = run_tester_node(predefined_test_env)

    end_time = time.time()
    run_time = end_time - start_time
    sleep_time = max(5 * 60, (test_interval_minutes * 60) - run_time)

    print(f"supervisor: Tester node finished at {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(end_time))}")
    print(f"supervisor: Runtime was {run_time:.2f} seconds")
    print(f"supervisor: Next run scheduled in {sleep_time // 60:.2f} minutes")

    time.sleep(sleep_time)
