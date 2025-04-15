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
#!/bin/bash

# Placeholder for the actual function if needed
install_jq_if_missing() {
  if ! command -v jq &> /dev/null; then
    printf "Error: 'jq' command not found. Please install jq.\n" >&2
    return 1
  fi
  return 0
}

get_distribution_id_by_alias() {
  local alias_name="$1"
  local aws_cli_opts="$2" # Example: "--profile myprofile --region us-east-1"

  # Ensure jq is available
  if ! install_jq_if_missing; then exit 1; fi

  # Use printf for status messages, redirecting to stderr
  printf "Attempting to find CloudFront Distribution ID for Alias: %s...\n" "$alias_name" >&2

  # --- Debugging AWS CLI ---
  printf "%s\n" "--- AWS CLI Raw Output (stderr) ---" >&2
  # Save to file to avoid potential buffering issues with direct pipe + error checking
  if ! aws cloudfront list-distributions ${aws_cli_opts} > aws_output.json; then
      printf "Error: AWS CLI command 'list-distributions' failed!\n" >&2
      # Attempt to print any error content captured in the file to stderr
      [ -f aws_output.json ] && cat aws_output.json >&2
      # Clean up temp file on error
      rm -f aws_output.json
      exit 1
  fi
  printf "%s\n" "(Output saved to aws_output.json, content below printed to stderr)" >&2
  cat aws_output.json >&2 # Print raw JSON output to stderr for debugging
  printf "%s\n" "--- End AWS CLI Raw Output (stderr) ---" >&2
  # --- End Debugging AWS CLI ---

  # Now run the jq command using the saved file
  local dist_id_output # Capture jq output/errors
  local jq_exit_status

  # Capture jq output AND exit status separately
  # Redirect jq's stderr (potential errors) to stdout to capture it in the variable
  dist_id_output=$(cat aws_output.json | jq -r --arg alias_name "$alias_name" \
    '.DistributionList.Items[] | select(.Aliases.Items[]? == $alias_name) | .Id' 2>&1)
  jq_exit_status=$?

  # Clean up the temporary file now that we're done with it
  rm -f aws_output.json

  # --- Debugging JQ ---
  printf "%s\n" "--- JQ Processed Output (dist_id_output variable, stderr) ---" >&2
  # Print raw content captured from jq (might be ID, empty, or error message) to stderr
  printf "Raw dist_id_output content: ->%s<-\n" "$dist_id_output" >&2
  printf "JQ exit status: %d\n" "$jq_exit_status" >&2
  printf "%s\n" "--- End JQ Processed Output (stderr) ---" >&2
  # --- End Debugging JQ ---

  # Check jq exit status first
  if [ "$jq_exit_status" -ne 0 ]; then
      printf "Error: jq command failed with exit status %d:\n" "$jq_exit_status" >&2
      printf "%s\n" "$dist_id_output" >&2 # Print the captured error output from jq
      exit 1
  fi

  # If jq succeeded (exit 0), check the content of the output
  # Check if jq output indicates an internal jq error despite exit 0 (less common)
  # Note: Simple checks like *error* might have false positives if an ID contained 'error'.
  # Relying on exit status is generally better. This check is kept from the original logic.
  if [[ "$dist_id_output" == *"error"* ]]; then
      printf "Error: Potential error detected in jq output processing:\n" >&2
      printf "%s\n" "$dist_id_output" >&2
      exit 1
  fi

  # Now process the potentially valid ID(s)
  local dist_id="$dist_id_output"
  local id_count

  # Count lines in the output, handle potential leading/trailing whitespace
  # Using parameter expansion and wc for robustness
  id_count=$(printf "%s" "$dist_id" | wc -l)
  id_count="${id_count//[[:space:]]/}" # Remove whitespace from wc output

  # Check if any ID was found
  if [ -z "$dist_id" ]; then
    printf "Error: No CloudFront distribution found matching Alias: %s\n" "$alias_name" >&2
    exit 1
  # Check if exactly one ID was found
  elif [ "$id_count" -ne 1 ]; then
    printf "Error: Found multiple (%s) distributions matching Alias: %s. Aliases should be unique.\n" "$id_count" "$alias_name" >&2
    printf "Found IDs:\n%s\n" "$dist_id" >&2 # Print the multiple IDs found
    exit 1
  fi

  # Success: Found exactly one ID
  printf "Found Distribution ID: %s (message to stderr)\n" "$dist_id" >&2;

  # Use echo for the final output to stdout, as requested.
  # This is the intended "return value" of the function via stdout.
  echo "$dist_id"

  return 0 # Indicate success
}

sync_and_invalidate() {
  local local_path="$1"; local s3_target_uri="$2"; local distribution_id="$3"; local aws_cli_opts="$4"
  # Extract bucket name from the URI
  local bucket_name_from_uri=$(echo "$s3_target_uri" | sed -n 's#^s3://\([^/]*\).*#\1#p')
  # s3_prefix_from_uri is not needed for path generation anymore

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
  echo "--- Paths identified for invalidation (pre-processing): ---" # DEBUG
  while IFS= read -r line; do
    if [[ "$line" == upload:* ]] || [[ "$line" == copy:* ]] || [[ "$line" == delete:* ]]; then
      local s3_path_full_uri=$(echo "$line" | awk -F ' to | delete: ' '{print $NF}')
      # Remove only the 's3://<bucket_name>/' part to get the full object key
      local s3_object_key=$(echo "$s3_path_full_uri" | sed -e "s#^s3://${bucket_name_from_uri}/##")
      # Prepend '/' to the object key for the CloudFront path
      local cf_path="/${s3_object_key}"

      # DEBUG: Print each generated path
      echo "  Generated CF Path: ->${cf_path}<-"

      # Basic uniqueness check
      if [[ ! " ${INVALIDATION_PATHS[@]} " =~ " ${cf_path} " ]]; then
         INVALIDATION_PATHS+=("$cf_path")
         # DEBUG: Indicate path was added
         echo "    (Added to list)"
      else
         # DEBUG: Indicate path was duplicate
         echo "    (Duplicate, skipped)"
      fi
    fi
  done < <(echo "$SYNC_OUTPUT")
  echo "--- End Paths Identified ---" # DEBUG

  # Step 3: Invalidate
  if [ ${#INVALIDATION_PATHS[@]} -eq 0 ]; then
    echo ""; echo "No files changed. Skipping CloudFront invalidation.";
  else
    echo ""; echo "Found ${#INVALIDATION_PATHS[@]} unique path(s) requiring invalidation."

    # *** START TEMPORARY HARDCODED PATH TEST ***
    # Comment out or remove the original dynamic list for this test
    echo "!!! WARNING: USING HARDCODED PATH FOR INVALIDATION TEST !!!"
    local TEST_PATHS=("/dashboard/browser/index.html") # Hardcode ONE known path
    echo "  Test Path(s): ${TEST_PATHS[@]}"
    # *** END TEMPORARY HARDCODED PATH TEST ***

    # Use TEST_PATHS count for the warning check during the test
    if [ ${#TEST_PATHS[@]} -gt 1000 ]; then echo "Warning: >1000 paths detected (in test array)."; fi

    # --- Enhanced Debugging for Invalidation Command ---
    echo ""
    # Adjust title for clarity during test
    echo "--- Preparing CloudFront Invalidation Command (HARDCODED TEST) ---"
    echo "  Distribution ID: ${distribution_id}"
    # Use TEST_PATHS for printing
    echo "  Paths to Invalidate (${#TEST_PATHS[@]} items):"
    printf "    '%s'\n" "${TEST_PATHS[@]}"
    # Construct the command string using TEST_PATHS
    local full_cmd_string="aws cloudfront create-invalidation --distribution-id \"${distribution_id}\" --paths"
    for path in "${TEST_PATHS[@]}"; do
        full_cmd_string+=" \"$path\"" # Add each path quoted
    done
    [ -n "$aws_cli_opts" ] && full_cmd_string+=" ${aws_cli_opts}"
    echo "  Full Command String (for review):"
    echo "    ${full_cmd_string}"
    echo "--- End Command Preparation ---"
    # --- End Enhanced Debugging ---

    echo ""
    echo "Creating CloudFront invalidation (HARDCODED TEST)..."
    local INVALIDATION_RESULT
    # *** Use the hardcoded TEST_PATHS array in the AWS command ***
    INVALIDATION_RESULT=$(aws cloudfront create-invalidation \
      --distribution-id "${distribution_id}" \
      --paths "${TEST_PATHS[@]}" \
      ${aws_cli_opts} 2>&1) || {
        # Adjust error message for clarity
        echo "Error creating CloudFront invalidation (HARDCODED TEST):"; echo "$INVALIDATION_RESULT"; exit 1;
      }

    # (Rest of the success reporting remains the same)
    local INVALIDATION_ID=$(echo "$INVALIDATION_RESULT" | grep -o '"Id": "[^"]*"' | cut -d'"' -f4)
    # Adjust success message for clarity
    echo "CloudFront invalidation request submitted successfully (HARDCODED TEST)."; echo "  Invalidation ID: ${INVALIDATION_ID}"
  fi

  echo ""; echo "Sync and invalidation finished for Distribution ID ${distribution_id}."
}

# --- Main Function ---
main() {
  if [ "$#" -ne 3 ]; then echo "Usage: $0 <local_source_path> <s3_target_uri> <cloudfront_alias_or_id>"; exit 1; fi
  local local_path="$1"; local s3_target_uri="$2"; local cf_alias_or_id="$3"
  local aws_profile="${AWS_PROFILE}"; local aws_cli_opts=""
  if [ -n "$aws_profile" ]; then aws_cli_opts="--profile ${aws_profile}"; echo "Using AWS Profile (from env): ${aws_profile}"; fi
  if ! check_command "aws"; then echo "Install AWS CLI."; exit 1; fi
  if [ ! -d "$local_path" ]; then echo "Error: Local path '$local_path' not found."; exit 1; fi
  if [[ ! "$s3_target_uri" =~ ^s3:// ]]; then echo "Error: S3 URI '$s3_target_uri' invalid."; exit 1; fi
  if [ -z "$cf_alias_or_id" ]; then echo "Error: CloudFront Alias/ID empty."; exit 1; fi
  local distribution_id=""; if [[ "$cf_alias_or_id" =~ ^E[A-Z0-9]+$ ]]; then echo "Using provided value as CF ID: ${cf_alias_or_id}"; distribution_id="$cf_alias_or_id"; else echo "Provided value '${cf_alias_or_id}' not ID. Assuming Alias."; distribution_id=$(get_distribution_id_by_alias "$cf_alias_or_id" "$aws_cli_opts"); if [ $? -ne 0 ] || [ -z "$distribution_id" ]; then exit 1; fi; fi
  sync_and_invalidate "$local_path" "$s3_target_uri" "$distribution_id" "$aws_cli_opts"
  echo ""; echo "Deployment process completed successfully."
}

# Script Entry Point
main "$@"

exit 0
