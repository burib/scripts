#!/bin/bash

# Script to sync a local directory to S3 and invalidate changed files in CloudFront.
# Usage: ./sync_to_s3_and_refresh_cloudfront.sh <local_source_path> <s3_target_uri> <cloudfront_alias_or_id> [--profile <aws_profile>] [--region <aws_region>]
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
  # Use sudo only if not already root
  local sudo_cmd=""
  if [[ $EUID -ne 0 ]]; then
    sudo_cmd="sudo"
  fi

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
  if ! check_command "jq"; then log_error "Verification failed after install attempt. Install 'jq' manually."; return 1; fi
  return 0
}


# Function to get CloudFront Distribution ID by Alias (CNAME)
get_distribution_id_by_alias() {
  local alias_name="$1"
  local aws_cli_opts=("${@:2}") # Capture remaining args as array for AWS CLI options

  # Ensure jq is available (calls the global function)
  if ! install_jq_if_missing; then exit 1; fi

  log_info "Attempting to find CloudFront Distribution ID for Alias: ${alias_name}..."

  # Create a temporary file securely
  local aws_output_file
  aws_output_file=$(mktemp)
  # Ensure cleanup on exit
  trap 'rm -f "$aws_output_file"' EXIT

  log_info "--- AWS CLI Raw Output (stderr) ---"
  if ! aws cloudfront list-distributions "${aws_cli_opts[@]}" > "$aws_output_file"; then
      log_error "AWS CLI command 'list-distributions' failed!"
      # Attempt to print any error content captured in the file to stderr
      cat "$aws_output_file" >&2
      # Cleanup is handled by trap
      exit 1
  fi
  log_info "(Raw AWS output saved to temporary file, content below printed to stderr)"
  cat "$aws_output_file" >&2 # Print raw JSON output to stderr for debugging
  log_info "--- End AWS CLI Raw Output (stderr) ---"

  # Now run the jq command using the saved file
  local dist_id_output # Capture jq output/errors
  local jq_exit_status

  # Capture jq output AND exit status separately
  dist_id_output=$(jq -r --arg alias_name "$alias_name" \
    '.DistributionList.Items[] | select(.Aliases.Items[]? == $alias_name) | .Id' < "$aws_output_file" 2>&1)
  jq_exit_status=$?

  # Temp file no longer needed, cleanup handled by trap, but can remove earlier if desired
  # rm -f "$aws_output_file"
  # trap - EXIT # Remove trap if cleaning up manually here

  log_info "--- JQ Processed Output (dist_id_output variable, stderr) ---"
  log_info "Raw dist_id_output content: ->${dist_id_output}<-"
  log_info "JQ exit status: ${jq_exit_status}"
  log_info "--- End JQ Processed Output (stderr) ---"

  # Check jq exit status first
  if [ "$jq_exit_status" -ne 0 ]; then
      log_error "jq command failed with exit status ${jq_exit_status}:"
      printf "%s\n" "$dist_id_output" >&2 # Print the captured error output from jq
      exit 1
  fi

  # Check if jq output indicates an internal jq error despite exit 0 (less common)
  if [[ "$dist_id_output" == *"error"* ]]; then
      log_error "Potential error detected in jq output processing:"
      printf "%s\n" "$dist_id_output" >&2
      exit 1
  fi

  local dist_id="$dist_id_output"
  local id_count
  id_count=$(printf "%s" "$dist_id" | wc -l | tr -d '[:space:]') # Trim whitespace robustly

  if [ -z "$dist_id" ]; then
    log_error "No CloudFront distribution found matching Alias: ${alias_name}"
    exit 1
  elif [ "$id_count" -ne 1 ]; then
    log_error "Found multiple (${id_count}) distributions matching Alias: ${alias_name}. Aliases should be unique."
    log_info "Found IDs:"
    printf "%s\n" "$dist_id" >&2 # Print the multiple IDs found
    exit 1
  fi

  log_info "Found Distribution ID: ${dist_id} (message to stderr)";

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

  log_info ""
  log_info "Starting sync and invalidation..."
  log_info "  Local Path: ${local_path}"
  log_info "  S3 Target URI: ${s3_target_uri}"
  log_info "  CloudFront Distribution ID: ${distribution_id}"
  log_info "  AWS CLI Options: ${aws_cli_opts[*]}" # Show options being used

  # Step 1: Sync
  log_info ""
  log_info "Syncing files to S3..."
  local SYNC_OUTPUT
  # Use process substitution and tee to capture output while showing progress if needed
  # Using --no-progress here, so just capture directly
  if ! SYNC_OUTPUT=$(aws s3 sync "${local_path}" "${s3_target_uri}" --acl private --delete --no-progress "${aws_cli_opts[@]}" 2>&1); then
    log_error "Error during S3 sync:"
    printf "%s\n" "$SYNC_OUTPUT" >&2
    exit 1
  fi
  printf "%s\n" "$SYNC_OUTPUT" >&2 # Print sync output to stderr for logs
  log_info "S3 sync completed."

  # Step 2: Parse
  log_info ""
  log_info "Parsing sync output for invalidation..."
  declare -a INVALIDATION_PATHS
  log_info "--- Paths identified for invalidation (pre-processing): ---" # DEBUG
  while IFS= read -r line; do
    # Match lines indicating upload, copy, or delete operations
    if [[ "$line" =~ ^(upload|copy|delete): ]]; then
      local s3_path_full_uri
      # Extract the target S3 path robustly
      if [[ "$line" =~ ^(upload|copy):.*[[:space:]]to[[:space:]](s3://.*) ]]; then
         s3_path_full_uri="${BASH_REMATCH[2]}"
      elif [[ "$line" =~ ^delete:[[:space:]](s3://.*) ]]; then
         s3_path_full_uri="${BASH_REMATCH[1]}"
      else
         log_info "  Skipping unparseable line: $line"
         continue # Skip lines we can't parse reliably
      fi

      # Remove only the 's3://<bucket_name>/' part to get the full object key
      local s3_object_key
      s3_object_key=$(echo "$s3_path_full_uri" | sed -e "s#^s3://${bucket_name_from_uri}/##")
      # Prepend '/' to the object key for the CloudFront path
      local cf_path="/${s3_object_key}"

      log_info "  Generated CF Path: ->${cf_path}<-"

      # Basic uniqueness check (safe for typical numbers of paths)
      if [[ ! " ${INVALIDATION_PATHS[@]} " =~ " ${cf_path} " ]]; then
         INVALIDATION_PATHS+=("$cf_path")
         log_info "    (Added to list)"
      else
         log_info "    (Duplicate, skipped)"
      fi
    fi
  done < <(printf "%s\n" "$SYNC_OUTPUT") # Feed captured output line by line
  log_info "--- End Paths Identified ---" # DEBUG

  # Step 3: Invalidate
  if [ ${#INVALIDATION_PATHS[@]} -eq 0 ]; then
    log_info ""
    log_info "No files changed or deleted. Skipping CloudFront invalidation.";
  else
    log_info ""
    log_info "Found ${#INVALIDATION_PATHS[@]} unique path(s) requiring invalidation."

    # Check CloudFront limits (soft limit 1000 free per month, hard limit 3000 per invalidation)
    if [ ${#INVALIDATION_PATHS[@]} -gt 1000 ]; then
      log_info "Warning: More than 1000 paths detected (${#INVALIDATION_PATHS[@]}). This might exceed free tier invalidation limits or approach API limits."
      log_info "Consider invalidating '/*' if appropriate, or batching invalidations if necessary."
    fi
    # AWS hard limit check
    if [ ${#INVALIDATION_PATHS[@]} -gt 3000 ]; then
        log_error "Too many paths (${#INVALIDATION_PATHS[@]}) for a single CloudFront invalidation request (limit 3000)."
        log_error "Please adjust your deployment or use a wildcard invalidation like '/*'."
        exit 1
    fi

    log_info ""
    log_info "--- Preparing CloudFront Invalidation Command ---"
    log_info "  Distribution ID: ${distribution_id}"
    log_info "  Paths to Invalidate (${#INVALIDATION_PATHS[@]} items):"
    # Use printf to list paths safely, one per line, indented
    printf "    '%s'\n" "${INVALIDATION_PATHS[@]}" >&2
    # Construct the command string for review (optional, but good for complex commands)
    local full_cmd_string="aws cloudfront create-invalidation --distribution-id \"${distribution_id}\" --paths"
    for path in "${INVALIDATION_PATHS[@]}"; do
        full_cmd_string+=" '${path}'" # Use single quotes for safety, assuming no single quotes in paths
    done
    full_cmd_string+=" ${aws_cli_opts[*]}" # Add other AWS CLI options
    log_info "  Full Command Preview (for review):"
    log_info "    ${full_cmd_string}"
    log_info "--- End Command Preparation ---"


    log_info ""
    log_info "Creating CloudFront invalidation..."
    local INVALIDATION_RESULT
    # Use the dynamically generated INVALIDATION_PATHS array
    if ! INVALIDATION_RESULT=$(aws cloudfront create-invalidation \
      --distribution-id "${distribution_id}" \
      --paths "${INVALIDATION_PATHS[@]}" \
      "${aws_cli_opts[@]}" 2>&1); then
        log_error "Error creating CloudFront invalidation:"
        printf "%s\n" "$INVALIDATION_RESULT" >&2
        exit 1
      fi

    # Extract Invalidation ID more reliably using jq if available (fallback to grep/cut)
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
      log_error "Could not extract Invalidation ID from the result:"
      printf "%s\n" "$INVALIDATION_RESULT" >&2
      # Decide if this is a fatal error or just a reporting issue
      # exit 1
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
  declare -a aws_cli_opts=() # Array to hold AWS options

  # Simple positional argument parsing + catch-all for AWS options
  if [ "$#" -lt 3 ]; then
    log_error "Usage: $0 <local_source_path> <s3_target_uri> <cloudfront_alias_or_id> [aws_cli_options...]"
    log_error "Example: $0 ./build s3://my-bucket/app www.example.com --profile myprof --region us-west-2"
    exit 1
  fi

  local_path="$1"
  s3_target_uri="$2"
  cf_alias_or_id="$3"
  # All remaining arguments are considered AWS CLI options
  if [ "$#" -gt 3 ]; then
      aws_cli_opts=("${@:4}")
  fi

  # --- Initial Checks ---
  if ! check_command "aws"; then log_error "AWS CLI is required. Please install it."; exit 1; fi
  if [ ! -d "$local_path" ]; then log_error "Local source path '$local_path' not found or is not a directory."; exit 1; fi
  if [[ ! "$s3_target_uri" =~ ^s3://[^/]+ ]]; then log_error "S3 target URI '$s3_target_uri' seems invalid. Expected format: s3://bucket-name[/optional-prefix]"; exit 1; fi
  if [ -z "$cf_alias_or_id" ]; then log_error "CloudFront Alias or Distribution ID cannot be empty."; exit 1; fi

  log_info "Script started."
  log_info "Local Source: $local_path"
  log_info "S3 Target: $s3_target_uri"
  log_info "CloudFront Identifier: $cf_alias_or_id"
  log_info "AWS CLI Options: ${aws_cli_opts[*]}"


  # --- Determine CloudFront Distribution ID ---
  local distribution_id=""
  # Regex to check if input looks like a CloudFront Distribution ID (E + 13 alphanumeric chars)
  if [[ "$cf_alias_or_id" =~ ^E[A-Z0-9]{13}$ ]]; then
    log_info "Input '$cf_alias_or_id' looks like a Distribution ID. Using it directly."
    distribution_id="$cf_alias_or_id"
  else
    log_info "Input '$cf_alias_or_id' does not look like a Distribution ID. Attempting to resolve it as an Alias..."
    # Pass the AWS CLI options to the lookup function
    # Capture the output (the ID) from stdout
    distribution_id=$(get_distribution_id_by_alias "$cf_alias_or_id" "${aws_cli_opts[@]}")
    # get_distribution_id_by_alias exits on error, so if we reach here, $distribution_id should be set
    if [ -z "$distribution_id" ]; then
        # This case should ideally not be reached due to checks within the function, but as a safeguard:
        log_error "Failed to retrieve Distribution ID for alias '$cf_alias_or_id'."
        exit 1
    fi
    # No need to echo here, the function already printed status to stderr and ID to stdout (captured)
  fi

  # --- Execute Sync and Invalidation ---
  # Pass the determined ID and AWS CLI options
  sync_and_invalidate "$local_path" "$s3_target_uri" "$distribution_id" "${aws_cli_opts[@]}"

  log_info ""
  log_info "Deployment process completed successfully."
}

# --- Script Entry Point ---
# Pass all arguments to main
main "$@"

exit 0
