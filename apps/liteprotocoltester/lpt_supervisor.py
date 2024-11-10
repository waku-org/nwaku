#!/usr/bin/env python3

import os
import time
from subprocess import Popen
import sys

def load_env(file_path):
  env_vars = {}
  with open(file_path) as f:
    for line in f:
      if line.strip() and not line.startswith('#'):
        key, value = line.strip().split('=', 1)
        env_vars[key] = value
  return env_vars

def start_tester_node():
  role = sys.argv[1]
  env = os.environ.copy()
  for key, value in env_vars.items():
    if key not in env:
      env[key] = value
  script_cmd = ['sh', '/usr/bin/run_tester_node_at_infra.sh', '/usr/bin/liteprotocoltester', role]
  process = Popen(script_cmd, env=env)
  return process

if __name__ == "__main__":
  if len(sys.argv) < 2 or sys.argv[1] not in ["RECEIVER", "SENDER"]:
    print("Error: First argument must be either 'RECEIVER' or 'SENDER'")
    sys.exit(1)

  env_file = '/usr/bin/infra.env'
  env_vars = load_env(env_file)

  test_interval_minutes = int(env_vars.get('TEST_INTERVAL_MINUTES', 60))  # Default to 60 minutes if not set

  while True:
    start_time = time.time()
    print(f"supervisor: Tester node started at {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(start_time))}")
    print(f"supervisor: with arguments: {env_vars}")

    process = start_tester_node()
    process.wait()

    end_time = time.time()
    run_time = end_time - start_time
    sleep_time = max(5, (test_interval_minutes * 60) - run_time)

    print(f"supervisor: Tester node finished at {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(end_time))}")
    print(f"supervisor: Runtime was {run_time:.2f} seconds")
    print(f"supervisor: Next run scheduled in {sleep_time // 60:.2f} minutes")

    time.sleep(sleep_time)
