#!/bin/bash

# Script to sync a local directory to S3 and invalidate changed files in CloudFront.
# Usage: ./sync_to_s3_and_refresh_cloudfront.sh <local_source_path> <s3_target_uri> <cloudfront_alias_or_id> [aws_cli_options...]
#   <local_source_path> : Path to the local directory containing files to sync (e.g., ./build).
#   <s3_target_uri>     : Full S3 URI including bucket and optional path (e.g., s3://my-bucket/dashboard).
#   <cloudfront_alias_or_id>: CloudFront distribution alias (e.g., www.example.com) OR Distribution ID (e.g., E123ABCDEF4567).
#   Optional AWS CLI args (--profile, --region, etc.) can be passed at the end.

# Exit immediately if a command exits with a non-zero status.
set -e
# Use pipefail to catch errors in pipelines
set -o pipefail

# --- Helper Functions ---

# Print message to stderr
log_info() {
  printf "%s\n" "$@" >&2
}

log_error() {
  printf "Error: %s\n" "$@" >&2
}

# Check if a command exists
check_command() {
  local cmd="$1"
  if ! command -v "$cmd" &> /dev/null; then
    log_error "Required command '$cmd' not found."
    return 1
  fi
  return 0
}

# Attempt to install jq if it's missing
install_jq_if_missing() {
  if check_command "jq"; then return 0; fi
  log_info "Required command 'jq' not found. Attempting to install..."
  local sudo_cmd=""
  if [[ $EUID -ne 0 ]]; then
    sudo_cmd="sudo"
  fi

  # Attempt installation using common package managers
  if command -v apt-get &> /dev/null; then
    log_info "Trying: ${sudo_cmd} apt-get update && ${sudo_cmd} apt-get install -y jq"
    if ${sudo_cmd} apt-get update && ${sudo_cmd} apt-get install -y jq; then log_info "jq installed via apt."; else log_error "Failed via apt."; return 1; fi
  elif command -v yum &> /dev/null; then
    log_info "Trying: ${sudo_cmd} yum install -y jq"
    if ${sudo_cmd} yum install -y jq; then log_info "jq installed via yum."; else log_error "Failed via yum."; return 1; fi
  elif command -v dnf &> /dev/null; then
    log_info "Trying: ${sudo_cmd} dnf install -y jq"
    if ${sudo_cmd} dnf install -y jq; then log_info "jq installed via dnf."; else log_error "Failed via dnf."; return 1; fi
  elif command -v brew &> /dev/null; then
    log_info "Trying: brew install jq"
    if brew install jq; then log_info "jq installed via brew."; else log_error "Failed via brew."; return 1; fi
  elif command -v choco &> /dev/null; then
     log_info "Trying: choco install jq -y"
     if choco install jq -y; then log_info "jq installed via choco."; else log_error "Failed via choco."; return 1; fi
  else
    log_error "Could not detect known package manager. Please install 'jq' manually."; return 1
  fi
  # Verify installation
  if ! check_command "jq"; then log_error "Verification failed after install attempt. Install 'jq' manually."; return 1; fi
  return 0
}


# Function to get CloudFront Distribution ID by Alias (CNAME)
get_distribution_id_by_alias() {
  local alias_name="$1"
  local -a aws_cli_opts=("${@:2}") # Capture remaining args as array for AWS CLI options

  if ! install_jq_if_missing; then exit 1; fi

  log_info "Attempting to find CloudFront Distribution ID for Alias: ${alias_name}..."

  local aws_output_file
  aws_output_file=$(mktemp)
  # Ensure cleanup on exit, including errors or script termination
  trap 'rm -f "$aws_output_file"' EXIT

  # Run AWS CLI command, redirecting JSON output to temp file
  if ! aws cloudfront list-distributions "${aws_cli_opts[@]}" > "$aws_output_file"; then
      log_error "AWS CLI command 'list-distributions' failed!"
      cat "$aws_output_file" >&2
      exit 1
  fi

  # Process the JSON file with JQ
  local dist_id_output
  local jq_exit_status
  dist_id_output=$(jq -r --arg alias_name "$alias_name" \
    '.DistributionList.Items[] | select(.Aliases.Items[]? == $alias_name) | .Id' < "$aws_output_file" 2>&1)
  jq_exit_status=$?

  # Check JQ execution status first
  if [ "$jq_exit_status" -ne 0 ]; then
      log_error "jq command failed with exit status ${jq_exit_status}:"
      printf "%s\n" "$dist_id_output" >&2
      exit 1
  fi
  # Basic check for literal "error" in jq's output
  if [[ "$dist_id_output" == *"error"* ]]; then
      log_error "Potential error detected in jq output processing:"
      printf "%s\n" "$dist_id_output" >&2
      exit 1
  fi

  # --- CORRECTED COUNTING LOGIC ---
  local dist_id="$dist_id_output" # Store the raw output from jq
  local id_count
  # Count non-empty lines in the output. Handles 0, 1 (no newline), and multiple lines correctly.
  id_count=$(printf "%s" "$dist_id" | grep -c .)
  # --- END CORRECTION ---


  # Validate the number of IDs found using the accurate count
  if [ "$id_count" -eq 0 ]; then # Check if count is exactly zero
    log_error "No CloudFront distribution found matching Alias: ${alias_name}"
    exit 1
  elif [ "$id_count" -ne 1 ]; then # Check if count is not exactly one (i.e., > 1)
    log_error "Found multiple (${id_count}) distributions matching Alias: ${alias_name}. Aliases should be unique."
    log_info "Found IDs:"
    printf "%s\n" "$dist_id" >&2 # Print the multiple IDs found (which are in $dist_id)
    exit 1
  fi

  # Success: If we reach here, id_count is guaranteed to be 1
  log_info "Found Distribution ID: ${dist_id}"; # $dist_id contains the single ID

  # Use echo for the final output to stdout - this is the function's result.
  echo "$dist_id"
  return 0 # Indicate success
}

sync_and_invalidate() {
  local local_path="$1"
  local s3_target_uri="$2"
  local distribution_id="$3"
  local -a aws_cli_opts=("${@:4}") # Capture remaining args as array

  local bucket_name_from_uri
  bucket_name_from_uri=$(echo "$s3_target_uri" | sed -n 's#^s3://\([^/]*\).*#\1#p')
  if [ -z "$bucket_name_from_uri" ]; then
      log_error "Could not extract bucket name from S3 URI: $s3_target_uri"
      exit 1
  fi

  log_info ""
  log_info "Starting sync and invalidation..."
  log_info "  Local Path: ${local_path}"
  log_info "  S3 Target URI: ${s3_target_uri}"
  log_info "  CloudFront Distribution ID: ${distribution_id}"

  # Step 1: Sync files to S3
  log_info ""
  log_info "Syncing files to S3..."
  local SYNC_OUTPUT
  if ! SYNC_OUTPUT=$(aws s3 sync "${local_path}" "${s3_target_uri}" --acl private --delete --no-progress "${aws_cli_opts[@]}" 2>&1); then
    log_error "Error during S3 sync:"
    printf "%s\n" "$SYNC_OUTPUT" >&2
    exit 1
  fi
  log_info "S3 sync completed."

  # Step 2: Parse sync output to find changed/deleted files for invalidation
  log_info ""
  log_info "Parsing sync output for invalidation paths..."
  declare -a INVALIDATION_PATHS
  while IFS= read -r line; do
    if [[ "$line" =~ ^(upload|copy|delete): ]]; then
      local s3_path_full_uri
      if [[ "$line" =~ ^(upload|copy):.*[[:space:]]to[[:space:]](s3://.*) ]]; then
         s3_path_full_uri="${BASH_REMATCH[2]}"
      elif [[ "$line" =~ ^delete:[[:space:]](s3://.*) ]]; then
         s3_path_full_uri="${BASH_REMATCH[1]}"
      else
         continue
      fi

      local s3_object_key
      s3_object_key=$(echo "$s3_path_full_uri" | sed -e "s#^s3://${bucket_name_from_uri}/##")
      local cf_path="/${s3_object_key}"

      if [[ ! " ${INVALIDATION_PATHS[@]} " =~ " ${cf_path} " ]]; then
         INVALIDATION_PATHS+=("$cf_path")
      fi
    fi
  done < <(printf "%s\n" "$SYNC_OUTPUT")

  # Step 3: Create CloudFront invalidation if necessary
  if [ ${#INVALIDATION_PATHS[@]} -eq 0 ]; then
    log_info ""
    log_info "No file changes detected in S3 sync. Skipping CloudFront invalidation.";
  else
    log_info ""
    log_info "Found ${#INVALIDATION_PATHS[@]} unique path(s) requiring invalidation."

    if [ ${#INVALIDATION_PATHS[@]} -gt 1000 ]; then
      log_info "Warning: More than 1000 paths detected (${#INVALIDATION_PATHS[@]}). This might exceed free tier invalidation limits or approach API limits."
    fi
    if [ ${#INVALIDATION_PATHS[@]} -gt 3000 ]; then
        log_error "Too many paths (${#INVALIDATION_PATHS[@]}) for a single CloudFront invalidation request (limit 3000)."
        log_error "Deployment aborted. Consider using a wildcard invalidation like '/*' or restructuring."
        exit 1
    fi

    log_info ""
    log_info "Creating CloudFront invalidation..."
    local INVALIDATION_RESULT
    if ! INVALIDATION_RESULT=$(aws cloudfront create-invalidation \
      --distribution-id "${distribution_id}" \
      --paths "${INVALIDATION_PATHS[@]}" \
      "${aws_cli_opts[@]}" 2>&1); then
        log_error "Error creating CloudFront invalidation:"
        printf "%s\n" "$INVALIDATION_RESULT" >&2
        exit 1
      fi

    local INVALIDATION_ID
    if command -v jq &> /dev/null; then
      INVALIDATION_ID=$(printf "%s" "$INVALIDATION_RESULT" | jq -r '.Invalidation.Id // empty')
    else
      INVALIDATION_ID=$(printf "%s" "$INVALIDATION_RESULT" | grep -o '"Id": "[^"]*"' | head -n 1 | cut -d'"' -f4)
    fi

    if [ -n "$INVALIDATION_ID" ]; then
      log_info "CloudFront invalidation request submitted successfully.";
      log_info "  Invalidation ID: ${INVALIDATION_ID}"
    else
      log_error "CloudFront invalidation submitted, but could not extract Invalidation ID from the result:"
      printf "%s\n" "$INVALIDATION_RESULT" >&2
    fi
  fi

  log_info ""
  log_info "Sync and invalidation process finished for Distribution ID ${distribution_id}."
}

# --- Main Function ---
main() {
  # --- Argument Parsing ---
  local local_path=""
  local s3_target_uri=""
  local cf_alias_or_id=""
  declare -a aws_cli_opts=()

  if [ "$#" -lt 3 ]; then
    log_error "Usage: $0 <local_source_path> <s3_target_uri> <cloudfront_alias_or_id> [aws_cli_options...]"
    log_error "Example: $0 ./build s3://my-bucket/app www.example.com --profile myprof --region us-west-2"
    exit 1
  fi

  local_path="$1"
  s3_target_uri="$2"
  cf_alias_or_id="$3"
  if [ "$#" -gt 3 ]; then
      aws_cli_opts=("${@:4}")
  fi

  # --- Initial Validations ---
  if ! check_command "aws"; then log_error "AWS CLI is required. Please install it."; exit 1; fi
  if [ ! -d "$local_path" ]; then log_error "Local source path '$local_path' not found or is not a directory."; exit 1; fi
  if [[ ! "$s3_target_uri" =~ ^s3://[^/]+ ]]; then log_error "S3 target URI '$s3_target_uri' seems invalid. Expected format: s3://bucket-name[/optional-prefix]"; exit 1; fi
  if [ -z "$cf_alias_or_id" ]; then log_error "CloudFront Alias or Distribution ID cannot be empty."; exit 1; fi

  log_info "Script started."
  log_info "Local Source: $local_path"
  log_info "S3 Target: $s3_target_uri"
  log_info "CloudFront Identifier: $cf_alias_or_id"

  # --- Determine the CloudFront Distribution ID ---
  local distribution_id=""
  if [[ "$cf_alias_or_id" =~ ^E[A-Z0-9]{13}$ ]]; then
    log_info "Input '$cf_alias_or_id' appears to be a Distribution ID. Using it directly."
    distribution_id="$cf_alias_or_id"
  else
    log_info "Input '$cf_alias_or_id' does not look like a Distribution ID. Attempting to resolve it as an Alias..."
    distribution_id=$(get_distribution_id_by_alias "$cf_alias_or_id" "${aws_cli_opts[@]}")
    if [ -z "$distribution_id" ]; then
        log_error "Failed to retrieve a valid Distribution ID for alias '$cf_alias_or_id'."
        exit 1
    fi
  fi

  # --- Execute the Sync and Invalidation Logic ---
  sync_and_invalidate "$local_path" "$s3_target_uri" "$distribution_id" "${aws_cli_opts[@]}"

  log_info ""
  log_info "Deployment process completed successfully."
}

# --- Script Entry Point ---
main "$@"

# Exit with success status code
exit 0
