#!/bin/bash

# Default values
regexp=""
base_url=""
owner=""
repo=""
workflow_id=""

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --regexp) regexp="$2"; shift 2 ;;
    --base-url) base_url="$2"; shift 2 ;;
    --owner) owner="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --workflow-id) workflow_id="$2"; shift 2 ;;
    *) echo "Unknown option $1"; exit 1 ;;
  esac
done

# Validate required parameters
if [[ -z "$regexp" || -z "$base_url" || -z "$owner" || -z "$repo" || -z "$workflow_id" ]]; then
  echo "Missing required parameters. Usage:"
  echo "--regexp REGEXP --base-url URL --owner OWNER --repo REPO --workflow-id ID"
  exit 1
fi

# Example logic
echo "Running with:"
echo "  Regexp: $regexp"
echo "  Base URL: $base_url"
echo "  Owner: $owner"
echo "  Repo: $repo"
echo "  Workflow ID: $workflow_id"
