#!/usr/bin/env bash

# optional argument to specgify the ip address
ip_address=$1
plain_text_out=false

# Parse command line arguments
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    -p|--plain)
      plain_text_out=true
      shift # past argument
      ;;
    -*|--*)
      echo "Unknown option $1"
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift # past argument
      ;;
  esac
done

set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

# Check if an IP address is provided as an argument
if [[ -n "$1" ]]; then
  ip_address="$1"
else
  ip_address="localhost:8645"
fi

# check if curl is available
if ! command -v curl &> /dev/null
then
    echo "curl could not be found"
    exit 1
fi

response=$(curl -s GET http://${ip_address}/health)

if [[ -z "${response}" ]]; then
  echo -e "$(date +'%H:%M:%S')\tnode health status is: unknown\n"
  exit 1
fi

if ! command -v jq &> /dev/null || [[ "$plain_text_out" = true ]]; then
  echo -e "$(date +'%H:%M:%S')\tnode health status is: ${response}\n"
else
  echo -e "$(date +'%H:%M:%S')\tnode health status is:\n"
  echo "${response}" | jq .
fi
