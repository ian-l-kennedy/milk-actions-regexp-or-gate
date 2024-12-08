#!/usr/bin/env bash

if ! command -v curl > /dev/null; then
    echo "FAILURE: 'curl' is not installed or not available in PATH. Please install curl to proceed."
    exit 1
fi

milk_url="https://raw.githubusercontent.com/ian-l-kennedy"
milk_bash="${milk_url}/milk-bash/refs/heads/main/src/milk.bash"
if ! curl --head --silent --fail "${milk_bash}" > /dev/null; then
    echo "FAILURE: Cannot connect to bash script source dependency: ${milk_bash}."
    exit 1
fi

source <(curl --silent "${milk_bash}")

set -e
set -o pipefail
set -u

NOTICE "Executing github_actions_regexp_or_gate.bash..."

INFO "Processing the command line parameters..."

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

desc_regexp="The regular expression to gather job names (--regexp)"
desc_base_url="The base URL of the GitHub repository (e.g., https://api.github.com) (--base-url)"
desc_owner="The owner of the GitHub repository (e.g., username or organization name) (--owner)"
desc_repo="The name of the GitHub repository (--repo)"
desc_workflow_id="The ID of the workflow where this action is invoked (--workflow-id)"

# Validate required parameters
if [[ -z "$regexp" ]]; then
  ERROR "Missing required parameter: $desc_regexp"
  exit 1
elif [[ "$regexp" == "" ]]; then
  ERROR "Required parameter is present but is blank: $desc_regexp"
  exit 1
fi

if [[ -z "$base_url" ]]; then
  ERROR "Missing required parameter: $desc_base_url"
  exit 1
elif [[ "$base_url" == "" ]]; then
  ERROR "Required parameter is present but is blank: $desc_base_url"
  exit 1
fi

if [[ -z "$owner" ]]; then
  ERROR "Missing required parameter: $desc_owner"
  exit 1
elif [[ "$owner" == "" ]]; then
  ERROR "Required parameter is present but is blank: $desc_owner"
  exit 1
fi

if [[ -z "$repo" ]]; then
  ERROR "Missing required parameter: $desc_repo"
  exit 1
elif [[ "$repo" == "" ]]; then
  ERROR "Required parameter is present but is blank: $desc_repo"
  exit 1
fi

if [[ -z "$workflow_id" ]]; then
  ERROR "Missing required parameter: $desc_workflow_id"
  exit 1
elif [[ "$workflow_id" == "" ]]; then
  ERROR "Required parameter is present but is blank: $desc_workflow_id"
  exit 1
fi

INFO "Running with:"
INFO "  Regexp: $regexp"
INFO "  Base URL: $base_url"
INFO "  Owner: $owner"
INFO "  Repo: $repo"
INFO "  Workflow ID: $workflow_id"

INFO "Defining functions..."

# Function to fetch all workflow jobs with pagination using file-based aggregation
get_all_workflow_jobs() {
  local workflow_id="$1"
  local base_url="$2"
  local owner="$3"
  local repo="$4"
  local output_file="/tmp/workflow_jobs.json"

  # Ensure the output file is empty
  > "$output_file"

  local page=1
  local per_page=100

  while :; do
    INFO "Fetching jobs for page $page..."
    local response
    response=$(curl --silent --fail \
      -H "Accept: application/vnd.github+json" \
      "${base_url}/repos/${owner}/${repo}/actions/runs/${workflow_id}/jobs?per_page=${per_page}&page=${page}")

    # Extract jobs from the response and append them to the file
    local page_jobs
    page_jobs=$(echo "$response" | jq '.jobs')
    echo "$page_jobs" | jq -c '.[]' >> "$output_file"

    # Check if there are more pages
    local total_jobs_on_page
    total_jobs_on_page=$(echo "$page_jobs" | jq 'length')
    if (( total_jobs_on_page < per_page )); then
      break
    fi

    ((page++))
  done

  # Combine all jobs into a single JSON array
  jq -s '.' "$output_file"
}

# Function to filter job names matching a regexp
filter_jobs_by_name() {
  local jobs="$1"
  local regexp="$2"

  echo "$jobs" | jq -r --arg regexp "$regexp" '.[] | select(.name | test($regexp)) | {name, status, conclusion}'
}

# Function to check job statuses
check_job_statuses() {
  local jobs="$1"

  local in_progress=0
  local failed=0
  local succeeded=0

  while IFS= read -r job; do
    local status
    status=$(echo "$job" | jq -r '.status')

    case "$status" in
      "in_progress")
        ((in_progress++))
        ;;
      "completed")
        local conclusion
        conclusion=$(echo "$job" | jq -r '.conclusion')
        if [[ "$conclusion" == "success" ]]; then
          ((succeeded++))
        else
          ((failed++))
        fi
        ;;
    esac
  done <<< "$(echo "$jobs" | jq -c '.[]')"

  echo "$in_progress,$failed,$succeeded"
}

# Function to wait if necessary
wait_for_jobs() {
  local delay="$1"
  INFO "Jobs are still in progress. Waiting for $delay seconds..."
  sleep "$delay"
}

# Function to evaluate job results and decide next action
evaluate_jobs() {
  local jobs="$1"
  local delay=300

  IFS=',' read -r in_progress failed succeeded <<< "$(check_job_statuses "$jobs")"

  if ((succeeded > 0)); then
    INFO "At least one job succeeded. Exiting with success."
    return 0
  elif ((in_progress > 0)); then
    INFO "Some jobs are still in progress. Retrying after a delay."
    wait_for_jobs "$delay"
    return 2
  else
    INFO "All jobs have completed. None succeeded. Exiting with failure."
    return 1
  fi
}

INFO "main..."

# Outer loop to retry evaluation for up to 5 hours
outer_retry_limit=60
outer_retry_count=0
outer_retry_delay=300

while true; do
    # Inner loop to fetch and filter jobs
    retry_limit=12
    retry_count=0
    retry_delay=300

    while true; do
        # Fetch all workflow jobs
        all_jobs=$(get_all_workflow_jobs "$workflow_id" "$base_url" "$owner" "$repo")

        if [[ -n "$all_jobs" && "$all_jobs" != "[]" ]]; then
            INFO "Successfully fetched workflow jobs."
            
            # Filter jobs with regexp
            INFO "Filtering jobs with regexp: $regexp"
            filtered_jobs=$(filter_jobs_by_name "$all_jobs" "$regexp")
            
            if [[ -n "$filtered_jobs" && "$filtered_jobs" != "[]" ]]; then
                INFO "Successfully filtered jobs matching the regexp."
              break
            else
                WARN "No jobs matching the regexp: $regexp. Retrying as part of the group operation."
            fi
        else
            WARN "No jobs found for the workflow run ID: $workflow_id. Retrying as part of the group operation."
        fi

        ((retry_count++))
        if ((retry_count >= retry_limit)); then
            ERROR "Failed to fetch and filter workflow jobs for the workflow run ID: $workflow_id after $retry_limit attempts."
            exit 1
        fi

        WARN "Retrying fetch-and-filter group operation in $retry_delay seconds... ($retry_count/$retry_limit)"
        sleep "$retry_delay"
    done

    # Evaluate job statuses
    INFO "Evaluating job statuses..."
    evaluate_jobs "$filtered_jobs"
    result=$?

    if [[ $result -eq 0 ]]; then
        INFO "Workflow jobs evaluation succeeded. Exiting."
        exit 0
    elif [[ $result -eq 1 ]]; then
        ERROR "Workflow jobs evaluation failed. Exiting."
        exit 1
    else
        INFO "Jobs are still in progress. Retrying outer loop after a delay."
    fi

    # Outer loop delay and retry logic
    ((outer_retry_count++))
    if ((outer_retry_count >= outer_retry_limit)); then
        ERROR "Jobs are still in progress after $outer_retry_limit attempts (6 hours). Exiting."
        exit 1
    fi

    INFO "Waiting $outer_retry_delay seconds before retrying outer loop... ($outer_retry_count/$outer_retry_limit)"
    sleep "$outer_retry_delay"
done
