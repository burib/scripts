#!/bin/bash

# Script to sync a local directory to S3 and invalidate changed files in CloudFront.
# Usage: ./sync_to_s3_and_refresh_cloudfront.sh <local_source_path> <s3_target_uri> <cloudfront_alias_or_id>
#   <local_source_path> : Path to the local directory containing files to sync (e.g., ./build).
#   <s3_target_uri>     : Full S3 URI including bucket and optional path (e.g., s3://my-bucket/dashboard).
#   <cloudfront_alias_or_id>: CloudFront distribution alias (e.g., www.example.com) OR Distribution ID (e.g., E123ABCDEF4567).

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Helper Functions ---

# Check if a command exists
check_command() {
  local cmd="$1"
  if ! command -v "$cmd" &> /dev/null; then
    echo "Error: Required command '$cmd' not found."
    return 1
  fi
  return 0
}

# Attempt to install jq if it's missing
install_jq_if_missing() {
  if check_command "jq"; then return 0; fi
  echo "Required command 'jq' not found. Attempting to install..."
  if command -v apt-get &> /dev/null; then
    echo "Trying: sudo apt-get update && sudo apt-get install -y jq"
    if sudo apt-get update && sudo apt-get install -y jq; then echo "jq installed via apt."; else echo "Failed via apt."; return 1; fi
  elif command -v yum &> /dev/null; then
    echo "Trying: sudo yum install -y jq"
    if sudo yum install -y jq; then echo "jq installed via yum."; else echo "Failed via yum."; return 1; fi
  elif command -v dnf &> /dev/null; then
    echo "Trying: sudo dnf install -y jq"
    if sudo dnf install -y jq; then echo "jq installed via dnf."; else echo "Failed via dnf."; return 1; fi
  elif command -v brew &> /dev/null; then
    echo "Trying: brew install jq"
    if brew install jq; then echo "jq installed via brew."; else echo "Failed via brew."; return 1; fi
  elif command -v choco &> /dev/null; then
     echo "Trying: choco install jq -y"
     if choco install jq -y; then echo "jq installed via choco."; else echo "Failed via choco."; return 1; fi
  else
    echo "Could not detect known package manager. Please install 'jq' manually."; return 1
  fi
  if ! check_command "jq"; then echo "Verification failed. Install 'jq' manually."; return 1; fi
  return 0
}

# Function to get CloudFront Distribution ID by Alias (CNAME)
get_distribution_id_by_alias() {
  local alias_name="$1"; local aws_cli_opts="$2"
  if ! install_jq_if_missing; then exit 1; fi
  echo "Attempting to find CloudFront Distribution ID for Alias: ${alias_name}..."

  # TEMP DEBUG: Run the command and print raw output first
  echo "--- AWS CLI Raw Output ---"
  # Save to file to avoid potential buffering issues with direct pipe + error checking
  aws cloudfront list-distributions ${aws_cli_opts} > aws_output.json || {
      echo "AWS CLI command 'list-distributions' failed!"
      # Attempt to print any error from the file if it exists
      [ -f aws_output.json ] && cat aws_output.json
      exit 1
  }
  echo "(Output saved to aws_output.json, content below)"
  cat aws_output.json # Print raw JSON output to logs
  echo "--- End AWS CLI Raw Output ---"

  # Now run the jq command using the saved file
  local dist_id
  dist_id=$(cat aws_output.json \
    | jq -r --arg alias_name "$alias_name" '.DistributionList.Items[] | select(.Aliases.Items[]? == $alias_name) | .Id' 2>&1)

  # TEMP DEBUG: Print what jq produced
  echo "--- JQ Processed Output (dist_id variable) ---"
  echo "Raw dist_id content: ->${dist_id}<-" # Print what jq produced (might be empty or contain errors)
  echo "--- End JQ Processed Output ---"


  # Original error checks based on jq output
  if [ $? -ne 0 ] || [[ "$dist_id" == *"error"* ]]; then
      echo "Error processing CloudFront distributions with jq:"
      echo "$dist_id" # Print the error captured from jq
      exit 1
  fi

  local id_count; id_count=$(echo "$dist_id" | wc -l | xargs) # Trim whitespace

  if [ -z "$dist_id" ]; then
    echo "Error: JQ processing completed but no CloudFront distribution found matching Alias: ${alias_name}"
    exit 1
  elif [ "$id_count" -ne 1 ]; then
    echo "Error: Found multiple (${id_count}) distributions matching Alias: ${alias_name}. Aliases should be unique."
    echo "$dist_id" # Print the multiple IDs found
    exit 1
  fi

  echo "Found Distribution ID: ${dist_id}";
  echo "$dist_id" # Return the ID
}


# --- Core Deployment Function ---
sync_and_invalidate() {
  local local_path="$1"; local s3_target_uri="$2"; local distribution_id="$3"; local aws_cli_opts="$4"
  # Extract bucket name and prefix from the URI for sed command later
  local bucket_name_from_uri=$(echo "$s3_target_uri" | sed -n 's#^s3://\([^/]*\).*#\1#p')
  local s3_prefix_from_uri=$(echo "$s3_target_uri" | sed -n 's#^s3://[^/]*/\(.*\)#\1#p')

  echo ""; echo "Starting sync and invalidation..."
  echo "  Local Path: ${local_path}"; echo "  S3 Target URI: ${s3_target_uri}"; echo "  CloudFront Distribution ID: ${distribution_id}"

  # Step 1: Sync
  echo ""; echo "Syncing files to S3..."
  local SYNC_OUTPUT;
  SYNC_OUTPUT=$(aws s3 sync "${local_path}" "${s3_target_uri}" --acl private --delete --no-progress ${aws_cli_opts} 2>&1) || {
    echo "Error during S3 sync:"; echo "$SYNC_OUTPUT"; exit 1;
  }
  echo "$SYNC_OUTPUT"; echo "S3 sync completed."

  # Step 2: Parse
  echo ""; echo "Parsing sync output for invalidation..."
  declare -a INVALIDATION_PATHS
  while IFS= read -r line; do
    if [[ "$line" == upload:* ]] || [[ "$line" == copy:* ]] || [[ "$line" == delete:* ]]; then
      local s3_path_full_uri=$(echo "$line" | awk -F ' to | delete: ' '{print $NF}')
      local sed_expr; if [ -n "$s3_prefix_from_uri" ]; then sed_expr="s#^s3://${bucket_name_from_uri}/${s3_prefix_from_uri}/##"; else sed_expr="s#^s3://${bucket_name_from_uri}/##"; fi
      local s3_relative_path=$(echo "$s3_path_full_uri" | sed -e "$sed_expr")
      local cf_path="/${s3_relative_path}"
      # Basic uniqueness check
      if [[ ! " ${INVALIDATION_PATHS[@]} " =~ " ${cf_path} " ]]; then INVALIDATION_PATHS+=("$cf_path"); fi
    fi
  done < <(echo "$SYNC_OUTPUT")

  # Step 3: Invalidate
  if [ ${#INVALIDATION_PATHS[@]} -eq 0 ]; then
    echo ""; echo "No files changed. Skipping CloudFront invalidation.";
  else
    echo ""; echo "Found ${#INVALIDATION_PATHS[@]} changed file(s) requiring invalidation."
    if [ ${#INVALIDATION_PATHS[@]} -gt 1000 ]; then echo "Warning: >1000 paths detected. Consider using a wildcard ('/*')."; fi
    echo "Creating CloudFront invalidation..."; local INVALIDATION_RESULT
    INVALIDATION_RESULT=$(aws cloudfront create-invalidation --distribution-id "${distribution_id}" --paths "${INVALIDATION_PATHS[@]}" ${aws_cli_opts} 2>&1) || {
      echo "Error creating CloudFront invalidation:"; echo "$INVALIDATION_RESULT"; exit 1;
    }
    local INVALIDATION_ID=$(echo "$INVALIDATION_RESULT" | grep -o '"Id": "[^"]*"' | cut -d'"' -f4)
    echo "CloudFront invalidation request submitted successfully."; echo "  Invalidation ID: ${INVALIDATION_ID}"
  fi

  echo ""; echo "Sync and invalidation finished for Distribution ID ${distribution_id}."
}


# --- Main Function ---
main() {
  # --- Configuration (Read from Command Line Arguments) ---
  if [ "$#" -ne 3 ]; then
      echo "Usage: $0 <local_source_path> <s3_target_uri> <cloudfront_alias_or_id>"
      echo "  Example: $0 ./build s3://my-bucket/dashboard www.example.com"
      echo "  Example: $0 ./dist s3://another-bucket E123ABCDEF4567"
      exit 1
  fi

  local local_path="$1"
  local s3_target_uri="$2"
  local cf_alias_or_id="$3"

  # Optional AWS Profile from environment
  local aws_profile="${AWS_PROFILE}" # Keep reading this from env
  local aws_cli_opts=""
  if [ -n "$aws_profile" ]; then
    aws_cli_opts="--profile ${aws_profile}"
    echo "Using AWS Profile (from env): ${aws_profile}"
  fi

  # --- Prerequisites and Validation ---
  if ! check_command "aws"; then
      echo "Please install AWS CLI first and configure your credentials."
      exit 1
  fi
  if [ ! -d "$local_path" ]; then
    echo "Error: Local source path ('$local_path') is not a valid directory."
    exit 1
  fi
  if [[ ! "$s3_target_uri" =~ ^s3:// ]]; then
    echo "Error: S3 target URI ('$s3_target_uri') must start with s3://"
    exit 1
  fi
  if [ -z "$cf_alias_or_id" ]; then
    echo "Error: CloudFront Alias or ID cannot be empty."
    exit 1
  fi


  # --- Determine Distribution ID ---
  local distribution_id=""
  # Simple check: CloudFront IDs start with 'E' followed by uppercase letters/numbers
  if [[ "$cf_alias_or_id" =~ ^E[A-Z0-9]+$ ]]; then
      echo "Using provided value as CloudFront Distribution ID: ${cf_alias_or_id}"
      distribution_id="$cf_alias_or_id"
  else
      # Assume it's an alias and perform lookup (includes jq check/install)
      echo "Provided value '${cf_alias_or_id}' does not look like a Distribution ID. Assuming it's an Alias."
      distribution_id=$(get_distribution_id_by_alias "$cf_alias_or_id" "$aws_cli_opts")
      if [ $? -ne 0 ] || [ -z "$distribution_id" ]; then
          # Error message printed within get_distribution_id_by_alias
          exit 1
      fi
  fi

  # --- Execute Deployment ---
  # Pass the arguments directly to the core function
  sync_and_invalidate "$local_path" "$s3_target_uri" "$distribution_id" "$aws_cli_opts"

  echo ""
  echo "Deployment process completed successfully."
}

# Script Entry Point
main "$@"

exit 0
