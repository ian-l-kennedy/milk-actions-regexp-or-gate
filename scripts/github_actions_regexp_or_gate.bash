#!/usr/bin/env bash

# MIT License
#
# Copyright (c) 2024 Ian Lindsay Kennedy
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

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

REQUIRE_COMMAND jq

INFO "Processing the command line parameters..."

# Default values
regexp=""
base_url=""
owner=""
repo=""
workflow_id=""
outer_retry_limit=60
outer_retry_delay=300
github_token=""

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --regexp) regexp="$2"; shift 2 ;;
    --base-url) base_url="$2"; shift 2 ;;
    --owner) owner="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --workflow-id) workflow_id="$2"; shift 2 ;;
    --outer-retry-limit) outer_retry_limit="$2"; shift 2 ;;
    --outer-retry-delay) outer_retry_delay="$2"; shift 2 ;;
    --github-token) github_token="$2"; shift 2 ;;
    *) echo "Unknown option $1"; exit 1 ;;
  esac
done

desc_regexp="The regular expression to gather job names (--regexp)"
desc_base_url="The base URL of the GitHub repository (e.g., https://api.github.com) (--base-url)"
desc_owner="The owner of the GitHub repository (e.g., username or organization name) (--owner)"
desc_repo="The name of the GitHub repository (--repo)"
desc_workflow_id="The ID of the workflow where this action is invoked (--workflow-id)"
desc_outer_retry_limit="The maximum number of iterations for the outer loop (--outer-retry-limit)"
desc_outer_retry_delay="The delay in seconds for each outer loop iteration (--outer-retry-delay)"

# Validate required parameters
if [[ -z "$github_token" ]]; then
  ERROR "Missing required parameter: --github-token. A GitHub personal access token is needed."
  exit 1
fi

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

if ! [[ "$outer_retry_limit" =~ ^[0-9]+$ ]] || ! [[ "$outer_retry_delay" =~ ^[0-9]+$ ]]; then
  ERROR "Parameters outer_retry_limit and outer_retry_delay must be positive integers."
  exit 1
fi

INFO "Running with:"
INFO "  Regexp: $regexp"
INFO "  Base URL: $base_url"
INFO "  Owner: $owner"
INFO "  Repo: $repo"
INFO "  Workflow ID: $workflow_id"
INFO "  Outer Retry Limit: $outer_retry_limit"
INFO "  Outer Retry Delay: $outer_retry_delay"

# Setup a unique log file
LOG_FILE="/tmp/action_log_milk_actions_regexp_or_gate_${workflow_run_id}_$$.txt"

if ! touch "$LOG_FILE"; then
    echo "LOG ERROR: Failed to create log file: $LOG_FILE"
    exit 1
fi

if [[ ! -w "$LOG_FILE" ]]; then
    echo "LOG ERROR: Log file is not writable: $LOG_FILE"
    exit 1
fi

INFO "Log file created: $LOG_FILE"

INFO "Defining functions..."

# Redirect logging functions to the log file
LOGGER_NOTICE() {
  if [[ -w "$LOG_FILE" || ! -e "$LOG_FILE" && -w "$(dirname "$LOG_FILE")" ]]; then
    NOTICE "$*" >> "$LOG_FILE"
  else
    echo "LOG ERROR: Cannot write to log file: $LOG_FILE"
  fi
}

LOGGER_INFO() {
  if [[ -w "$LOG_FILE" || ! -e "$LOG_FILE" && -w "$(dirname "$LOG_FILE")" ]]; then
    INFO "$*" >> "$LOG_FILE"
  else
    echo "LOG ERROR: Cannot write to log file: $LOG_FILE"
  fi
}

LOGGER_WARN() {
  if [[ -w "$LOG_FILE" || ! -e "$LOG_FILE" && -w "$(dirname "$LOG_FILE")" ]]; then
    WARN "$*" >> "$LOG_FILE"
  else
    echo "LOG ERROR: Cannot write to log file: $LOG_FILE"
  fi
}

LOGGER_ERROR() {
  if [[ -w "$LOG_FILE" || ! -e "$LOG_FILE" && -w "$(dirname "$LOG_FILE")" ]]; then
    ERROR "$*" >> "$LOG_FILE"
  else
    echo "LOG ERROR: Cannot write to log file: $LOG_FILE"
  fi
}

# Function to display logs after each function call
display_log() {
  cat "$LOG_FILE"
}


clear_log() {
    if [[ -w "$LOG_FILE" ]]; then
        > "$LOG_FILE"
    else
        echo "LOG ERROR: Cannot clear log file: $LOG_FILE"
    fi
}


# Function to fetch all workflow jobs with pagination using file-based aggregation
get_all_workflow_jobs() {
  local workflow_id="$1"
  local base_url="$2"
  local owner="$3"
  local repo="$4"
  local output_file="/tmp/workflow_jobs.json"

  LOGGER_INFO "Initializing job fetching for workflow_id: $workflow_id, base_url: $base_url, owner: $owner, repo: $repo"
  LOGGER_INFO "Output file: $output_file"

  # Ensure the output file is empty
  > "$output_file"
  LOGGER_INFO "Output file cleared: $output_file"

  local page=1
  local per_page=100

  while :; do
    LOGGER_INFO "Fetching jobs for page $page with per_page: $per_page"
    LOGGER_INFO "curl --silent --fail -H 'Accept: application/vnd.github+json' -H 'Authorization: Bearer $github_token' '${base_url}/repos/${owner}/${repo}/actions/runs/${workflow_id}/jobs?per_page=${per_page}&page=${page}'"
    curl --silent --fail -H "Accept: application/vnd.github+json" -H "Authorization: Bearer $github_token" \
      "${base_url}/repos/${owner}/${repo}/actions/runs/${workflow_id}/jobs?per_page=${per_page}&page=${page}" | jq '.' | while IFS= read -r line; do
        LOGGER_INFO "$line"
    done
    LOGGER_INFO "curl -H 'Accept: application/vnd.github+json' -H 'Authorization: Bearer $github_token' '${base_url}/repos/${owner}/${repo}/actions/runs/${workflow_id}/jobs?per_page=${per_page}&page=${page}'"
    curl -H "Accept: application/vnd.github+json" -H "Authorization: Bearer $github_token" \
      "${base_url}/repos/${owner}/${repo}/actions/runs/${workflow_id}/jobs?per_page=${per_page}&page=${page}" | jq '.' | while IFS= read -r line; do
        LOGGER_INFO "$line"
    done
    local response
    response=$(curl --silent --fail \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $github_token" \
      "${base_url}/repos/${owner}/${repo}/actions/runs/${workflow_id}/jobs?per_page=${per_page}&page=${page}")

    if [[ -z "$response" ]]; then
      LOGGER_ERROR "Empty response from GitHub API for page $page. Ensure the API is reachable and credentials are correct."
      return 1
    fi

    DEBUG "Raw response from GitHub API (page $page): $response"

    # Validate the response JSON
    if ! echo "$response" | jq -e . > /dev/null 2>&1; then
      LOGGER_ERROR "Invalid JSON response from GitHub API for page $page. Response: $response"
      return 1
    fi

    # Extract jobs from the response
    local page_jobs
    page_jobs=$(echo "$response" | jq '.jobs')
    if [[ -z "$page_jobs" || "$page_jobs" == "null" ]]; then
      LOGGER_WARN "No jobs found on page $page. Ending pagination."
      break
    fi

    LOGGER_DEBUG "Jobs extracted from page $page: $(echo "$page_jobs" | jq -c)"

    # Append jobs to the file
    echo "$page_jobs" | jq -c '.[]' >> "$output_file"
    LOGGER_INFO "Appended jobs from page $page to output file: $output_file"

    # Check if there are more pages
    local total_jobs_on_page
    total_jobs_on_page=$(echo "$page_jobs" | jq 'length')
    LOGGER_INFO "Page $page contains $total_jobs_on_page jobs."

    if (( total_jobs_on_page < per_page )); then
      LOGGER_INFO "No more jobs to fetch. Ending pagination after page $page."
      break
    fi

    ((page++))
  done

  # Combine all jobs into a single JSON array
  LOGGER_INFO "Combining all jobs into a single JSON array."
  if ! jq -s '.' "$output_file" > "${output_file}.combined"; then
    LOGGER_ERROR "Failed to combine job results into a JSON array."
    return 1
  fi

  LOGGER_INFO "Jobs successfully combined into: ${output_file}.combined"

  # Log the first job to confirm indexing
  local first_job
  first_job=$(jq '.[0]' "${output_file}.combined")
  if [[ -n "$first_job" && "$first_job" != "null" ]]; then
    LOGGER_INFO "First job in the combined array: $first_job"
  else
    LOGGER_WARN "No jobs in the combined array. Ensure data was fetched correctly."
  fi

  cat "${output_file}.combined"
}


# Function to filter job names matching a regexp
filter_jobs_by_name() {
  local jobs="$1"
  local regexp="$2"

  LOGGER_INFO "Starting job filtering with regexp: $regexp"

  # Validate input jobs
  if [[ -z "$jobs" || "$jobs" == "[]" ]]; then
    LOGGER_ERROR "No jobs provided for filtering. Ensure jobs were fetched successfully."
    return 1
  fi
  LOGGER_INFO "Received jobs for filtering: $(echo "$jobs" | jq 'length') total jobs."

  if ! echo "$jobs" | jq -e . > /dev/null 2>&1; then
    LOGGER_ERROR "Invalid jobs JSON passed to filtering. Jobs: $jobs"
    return 1
  fi
  LOGGER_INFO "Validated jobs JSON structure."

  # Debug the first few jobs
  local first_few_jobs
  first_few_jobs=$(echo "$jobs" | jq -c '.[0:3]')
  if [[ -n "$first_few_jobs" && "$first_few_jobs" != "[]" ]]; then
    LOGGER_INFO "First few jobs for inspection:"
    echo "$first_few_jobs" | jq -r '.[] | "\(.name) - Status: \(.status), Conclusion: \(.conclusion)"' | while IFS= read -r line; do
      LOGGER_INFO "$line"
    done
  else
    LOGGER_WARN "No jobs to inspect in the provided array."
  fi

  # Perform the filtering
  local filtered_jobs
  filtered_jobs=$(echo "$jobs" | jq -c --arg regexp "$regexp" '[.[] | select(.name | test($regexp)) | {name, status, conclusion}]')
  
  # Log the filtered jobs count and details
  local filtered_count
  filtered_count=$(echo "$filtered_jobs" | jq 'length')
  LOGGER_INFO "Filtered jobs count: $filtered_count"

  if [[ "$filtered_count" -gt 0 ]]; then
    LOGGER_INFO "Filtered job names and statuses:"
    echo "$filtered_jobs" | jq -r '.[0:3] | .[] | "\(.name) - Status: \(.status), Conclusion: \(.conclusion)"' | while IFS= read -r line; do
      LOGGER_INFO "$line"
    done
  else
    LOGGER_WARN "No jobs matched the regexp: $regexp"
    filtered_jobs="[]"  # Ensure filtered_jobs is set to an empty JSON array
  fi

  # Output the filtered jobs as JSON
  echo "$filtered_jobs"
}



# Function to check job statuses
check_job_statuses() {
  local jobs="$1"

  LOGGER_INFO "Starting job status check..."

  local in_progress=0
  local failed=0
  local succeeded=0
  local queued=0

  # Validate input jobs
  if [[ -z "$jobs" || "$jobs" == "[]" ]]; then
    LOGGER_ERROR "No jobs provided for status check. Ensure jobs were fetched successfully."
    return 1
  fi
  LOGGER_INFO "Received jobs for status check: $(echo "$jobs" | jq 'length') total jobs."

  if ! echo "$jobs" | jq -e . > /dev/null 2>&1; then
    LOGGER_ERROR "Invalid jobs JSON passed to status check. Jobs: $jobs"
    return 1
  fi
  LOGGER_INFO "Validated jobs JSON structure."

  # Iterate through each job and count statuses
  while IFS= read -r job; do
    local job_name
    local status
    local conclusion

    job_name=$(echo "$job" | jq -r '.name')
    status=$(echo "$job" | jq -r '.status')
    conclusion=$(echo "$job" | jq -r '.conclusion // "null"')

    LOGGER_INFO "Checking job: $job_name"
    LOGGER_INFO "  Status: $status, Conclusion: $conclusion"

    case "$status" in
      "in_progress"|"queued")
        ((in_progress++))
        if [[ "$status" == "queued" ]]; then
          ((queued++))
        fi
        LOGGER_INFO "  Job is in progress or queued. Incrementing in_progress count: $in_progress"
        ;;
      "completed")
        if [[ "$conclusion" == "success" ]]; then
          ((succeeded++))
          LOGGER_INFO "  Job completed successfully. Incrementing succeeded count: $succeeded"
        else
          ((failed++))
          LOGGER_INFO "  Job completed with failure. Incrementing failed count: $failed"
        fi
        ;;
      *)
        LOGGER_WARN "  Unknown or unsupported job status: $status"
        ;;
    esac
  done <<< "$(echo "$jobs" | jq -c '.[]')"

  # Log final counts
  LOGGER_INFO "Job status check complete."
  LOGGER_INFO "  In Progress (includes queued): $in_progress"
  LOGGER_INFO "  Queued: $queued"
  LOGGER_INFO "  Succeeded: $succeeded"
  LOGGER_INFO "  Failed: $failed"
  LOGGER_INFO "      \"$in_progress,$failed,$succeeded\""

  # Return counts as CSV
  echo "$in_progress,$failed,$succeeded"
}



# Function to wait if necessary
wait_for_jobs() {
  local delay="$1"
  LOGGER_INFO "Jobs are still in progress. Waiting for $delay seconds..."
  sleep "$delay"
}

evaluate_jobs() {
  local jobs="$1"

  LOGGER_INFO "Starting evaluation of job results..."

  # Log the incoming jobs
  local job_count
  job_count=$(echo "$jobs" | jq 'length')
  LOGGER_INFO "Evaluating a total of $job_count jobs."

  # Debug the first few jobs for context
  local first_few_jobs
  first_few_jobs=$(echo "$jobs" | jq -r '.[0:3]')
  if [[ -n "$first_few_jobs" && "$first_few_jobs" != "[]" ]]; then
    LOGGER_INFO "First few jobs for evaluation:"
    echo "$first_few_jobs" | jq -r '.[] | "\(.name) - Status: \(.status), Conclusion: \(.conclusion)"' | while IFS= read -r line; do
      LOGGER_INFO "$line"
    done
  else
    LOGGER_WARN "No jobs available to evaluate. Ensure job fetching and filtering were successful."
  fi

  # Check job statuses
  LOGGER_INFO "Calling check_job_statuses to categorize jobs..."
  local job_status_output
  job_status_output=$(check_job_statuses "$jobs" | sed -e 's/^"//' -e 's/"$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

  if [[ -z "$job_status_output" ]]; then
    LOGGER_ERROR "check_job_statuses returned an empty result!"
    return 1
  fi

  LOGGER_INFO "Raw job status output: $job_status_output"

  IFS=',' read -r in_progress failed succeeded <<< "$job_status_output"

  LOGGER_INFO "Job status evaluation complete:"
  LOGGER_INFO "  In Progress: $in_progress"
  LOGGER_INFO "  Failed: $failed"
  LOGGER_INFO "  Succeeded: $succeeded"

  # Decide next action based on statuses
  if ((succeeded > 0)); then
    LOGGER_INFO "At least one job succeeded. Returning success."
    return 0
  elif ((in_progress > 0)); then
    LOGGER_INFO "Some jobs are still in progress or queued. Returning status 2."
    return 2
  else
    LOGGER_INFO "All jobs have completed. None succeeded. Returning failure."
    return 1
  fi
}


clear_log

trap display_log EXIT

INFO "main..."

# Outer loop to retry evaluation for up to outer_retry_limit iterations
INFO "Outer loop initialized with limit: $outer_retry_limit and delay: $outer_retry_delay seconds"
outer_retry_count=0

while true; do
    INFO "Outer loop iteration: $outer_retry_count"

    # Inner loop to fetch and filter jobs
    INFO "Starting inner fetch-and-filter loop with limit: 12 and delay: 300 seconds"
    retry_limit=12
    retry_count=0
    retry_delay=300

    while true; do
        INFO "Inner loop iteration: $retry_count"

        # Fetch all workflow jobs
        INFO "Calling get_all_workflow_jobs with workflow_id: $workflow_id, base_url: $base_url, owner: $owner, repo: $repo"
        all_jobs=$(get_all_workflow_jobs "$workflow_id" "$base_url" "$owner" "$repo")
        fetch_status=$?
        display_log
        clear_log
        if [[ $fetch_status -ne 0 ]]; then
            ERROR "Failed to fetch workflow jobs. get_all_workflow_jobs returned status: $fetch_status"
            exit 1
        fi

        INFO "Validating fetched jobs..."
        if [[ -n "$all_jobs" && "$all_jobs" != "[]" ]]; then
            INFO "Successfully fetched workflow jobs: $(echo "$all_jobs" | jq 'length') jobs found"

            # Filter jobs with regexp
            INFO "Filtering jobs with regexp: $regexp"
            filtered_jobs=$(filter_jobs_by_name "$all_jobs" "$regexp")
            filter_status=$?
            display_log
            clear_log
            if [[ $filter_status -ne 0 ]]; then
                ERROR "Failed to filter jobs. filter_jobs_by_name returned status: $filter_status"
                exit 1
            fi

            INFO "Validating filtered jobs..."
            if [[ -n "$filtered_jobs" && "$filtered_jobs" != "[]" ]]; then
                INFO "Successfully filtered jobs matching the regexp: $(echo "$filtered_jobs" | jq 'length') jobs matched"
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
            display_log
            clear_log
            exit 1
        fi

        WARN "Retrying fetch-and-filter group operation in $retry_delay seconds... ($retry_count/$retry_limit)"
        sleep "$retry_delay"
    done

    # Evaluate job statuses
    INFO "Evaluating job statuses with evaluate_jobs"

    set +e  # Temporarily disable 'set -e' to handle evaluate_jobs return codes
    evaluate_jobs "$filtered_jobs"
    eval_status=$?
    set -e  # Re-enable 'set -e' after the function call

    INFO "evaluate_jobs returned status: $eval_status"
    display_log
    clear_log

    if [[ $eval_status -eq 0 ]]; then
        INFO "Workflow jobs evaluation succeeded. Exiting."
        exit 0
    elif [[ $eval_status -eq 1 ]]; then
        ERROR "Workflow jobs evaluation failed. Exiting."
        exit 1
    else
        INFO "Jobs are still in progress. Retrying outer loop after a delay."
    fi

    # Ensure outer_retry_count is initialized
    if [[ -z "${outer_retry_count:-}" || ! "$outer_retry_count" =~ ^[0-9]+$ ]]; then
        LOGGER_ERROR "outer_retry_count is not initialized or is not numeric. Initializing to 0."
        outer_retry_count=0
    fi

    outer_retry_count=$((outer_retry_count+1))

    LOGGER_INFO "Outer retry count after increment: $outer_retry_count"

    LOGGER_INFO "Checking if outer_retry_count ($outer_retry_count) exceeds outer_retry_limit ($outer_retry_limit)..."
    if ((outer_retry_count >= outer_retry_limit)); then
        ERROR "Jobs are still in progress after $outer_retry_limit attempts. Exiting workflow as failed."
        exit 1
    fi

    LOGGER_INFO "Outer retry count ($outer_retry_count) is within the limit ($outer_retry_limit). Proceeding with delay."

    LOGGER_INFO "Waiting for $outer_retry_delay seconds before retrying outer loop... (Retry $outer_retry_count/$outer_retry_limit)"
    if ! sleep "$outer_retry_delay"; then
        LOGGER_ERROR "Failed during sleep operation. outer_retry_delay: $outer_retry_delay"
        exit 1
    fi

    LOGGER_INFO "Wait complete. Proceeding to next retry loop iteration."
done
