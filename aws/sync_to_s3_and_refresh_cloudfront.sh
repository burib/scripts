#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Helper Functions ---

# Check if a command exists
check_command() {
  # $1: command name
  # $2: package name (optional, for install message)
  local cmd="$1"
  local pkg="${2:-$1}" # Default package name to command name
  if ! command -v "$cmd" &> /dev/null; then
    echo "Error: Required command '$cmd' not found."
    echo "Attempting installation..." # Message moved to install function
    return 1 # Indicate command not found
  fi
  return 0 # Indicate command found
}

# Attempt to install jq if it's missing
install_jq_if_missing() {
  if check_command "jq"; then
    # echo "jq is already installed." # Optional: uncomment for verbose feedback
    return 0
  fi

  echo "Required command 'jq' not found. Attempting to install..."

  # Attempt to detect package manager and install
  if command -v apt-get &> /dev/null; then
    echo "Detected apt (Debian/Ubuntu). Trying: sudo apt-get update && sudo apt-get install -y jq"
    if sudo apt-get update && sudo apt-get install -y jq; then
      echo "jq installed successfully via apt."
    else
      echo "Failed to install jq using apt. Please install it manually."
      return 1
    fi
  elif command -v yum &> /dev/null; then
    echo "Detected yum (CentOS/RHEL/Older Fedora). Trying: sudo yum install -y jq"
    if sudo yum install -y jq; then
      echo "jq installed successfully via yum."
    else
      echo "Failed to install jq using yum. Please install it manually."
      return 1
    fi
 elif command -v dnf &> /dev/null; then
    echo "Detected dnf (Fedora/Newer CentOS/RHEL). Trying: sudo dnf install -y jq"
    if sudo dnf install -y jq; then
      echo "jq installed successfully via dnf."
    else
      echo "Failed to install jq using dnf. Please install it manually."
      return 1
    fi
  elif command -v brew &> /dev/null; then
    echo "Detected Homebrew (macOS). Trying: brew install jq"
    if brew install jq; then
      echo "jq installed successfully via brew."
    else
      echo "Failed to install jq using brew. Please install it manually."
      return 1
    fi
  elif command -v choco &> /dev/null; then
     echo "Detected Chocolatey (Windows). Trying: choco install jq"
     if choco install jq -y; then # -y for confirmation often needed
         echo "jq installed successfully via choco."
     else
         echo "Failed to install jq using choco. Please install it manually."
         return 1
     fi
  else
    echo "Could not detect a known package manager (apt, yum, dnf, brew, choco)."
    echo "Please install 'jq' manually for your system."
    return 1
  fi

  # Verify installation after attempt
  if ! check_command "jq"; then
     echo "Installation verification failed. Please install 'jq' manually."
     return 1
  fi

  return 0
}


# Function to get CloudFront Distribution ID by Alias (CNAME)
get_distribution_id_by_alias() {
  local alias_name="$1"
  local aws_cli_opts="$2" # Pass optional AWS CLI args like --profile

  # Ensure jq is available before proceeding
  if ! install_jq_if_missing; then
      exit 1 # Exit if jq couldn't be installed/found
  fi

  echo "Attempting to find CloudFront Distribution ID for Alias: ${alias_name}..."

  local dist_id
  dist_id=$(aws cloudfront list-distributions ${aws_cli_opts} \
    | jq -r --arg alias_name "$alias_name" '.DistributionList.Items[] | select(.Aliases.Items[]? == $alias_name) | .Id' 2>&1)

  if [ $? -ne 0 ] || [[ "$dist_id" == *"error"* ]]; then
      echo "Error querying CloudFront distributions:"
      echo "$dist_id"
      exit 1
  fi

  local id_count
  id_count=$(echo "$dist_id" | wc -l | xargs)

  if [ -z "$dist_id" ]; then
    echo "Error: No CloudFront distribution found with Alias: ${alias_name}"
    exit 1
  elif [ "$id_count" -ne 1 ]; then
    echo "Error: Found multiple (${id_count}) CloudFront distributions matching Alias: ${alias_name}. Aliases should be unique."
    echo "$dist_id"
    exit 1
  fi

  echo "Found Distribution ID: ${dist_id}"
  echo "$dist_id"
}


# --- Core Deployment Function ---
sync_and_invalidate() {
  local local_path="$1"
  local bucket_name="$2"
  local distribution_id="$3"
  local aws_cli_opts="$4"

  echo ""
  echo "Starting sync and invalidation..."
  echo "  Local Path: ${local_path}"
  echo "  S3 Bucket:  s3://${bucket_name}"
  echo "  CloudFront Distribution ID: ${distribution_id}"

  # Step 1: Sync
  echo ""
  echo "Syncing files to S3..."
  local SYNC_OUTPUT
  SYNC_OUTPUT=$(aws s3 sync "${local_path}" "s3://${bucket_name}" --acl private --delete --no-progress ${aws_cli_opts} 2>&1) || {
    echo "Error during S3 sync:"
    echo "$SYNC_OUTPUT"; exit 1
  }
  echo "$SYNC_OUTPUT"
  echo "S3 sync completed."

  # Step 2: Parse
  echo ""
  echo "Parsing sync output for invalidation..."
  declare -a INVALIDATION_PATHS
  while IFS= read -r line; do
    if [[ "$line" == upload:* ]] || [[ "$line" == copy:* ]] || [[ "$line" == delete:* ]]; then
      local s3_path
      s3_path=$(echo "$line" | awk -F ' to | delete: ' '{print $NF}' | sed -e 's/^s3:\/\/[^/]*\///')
      local cf_path="/${s3_path}"
      if [[ ! " ${INVALIDATION_PATHS[@]} " =~ " ${cf_path} " ]]; then
          INVALIDATION_PATHS+=("$cf_path")
      fi
    fi
  done < <(echo "$SYNC_OUTPUT")

  # Step 3: Invalidate
  if [ ${#INVALIDATION_PATHS[@]} -eq 0 ]; then
    echo ""
    echo "No files were changed. Skipping CloudFront invalidation."
  else
    echo ""
    echo "Found ${#INVALIDATION_PATHS[@]} changed file(s) requiring invalidation."
    if [ ${#INVALIDATION_PATHS[@]} -gt 1000 ]; then
       echo "Warning: More than 1000 paths detected (${#INVALIDATION_PATHS[@]}). Consider using a wildcard invalidation ('/*')."
    fi

    echo "Creating CloudFront invalidation..."
    local INVALIDATION_RESULT
    INVALIDATION_RESULT=$(aws cloudfront create-invalidation \
      --distribution-id "${distribution_id}" \
      --paths "${INVALIDATION_PATHS[@]}" \
      ${aws_cli_opts} 2>&1) || {
        echo "Error creating CloudFront invalidation:"; echo "$INVALIDATION_RESULT"; exit 1
      }

    local INVALIDATION_ID
    INVALIDATION_ID=$(echo "$INVALIDATION_RESULT" | grep -o '"Id": "[^"]*"' | cut -d'"' -f4)

    echo "CloudFront invalidation request submitted successfully."
    echo "  Invalidation ID: ${INVALIDATION_ID}"
  fi

  echo ""
  echo "Sync and invalidation finished for Distribution ID ${distribution_id}."
}

# --- Main Function ---
main() {
  # Configuration
  local LOCAL_PATH_TO_SYNC_FILES_FROM="./build"
  local BUCKET_NAME="your-s3-bucket-name"
  local CLOUDFRONT_ALIAS="www.example.com"
  local DISTRIBUTION_ID=""
  # DISTRIBUTION_ID="E123ABCDEF4567"

  local AWS_PROFILE="" # Optional: set your profile name e.g. "my-work-profile"
  local AWS_CLI_OPTIONS=""
  if [ -n "$AWS_PROFILE" ]; then
    AWS_CLI_OPTIONS="--profile ${AWS_PROFILE}"
    echo "Using AWS Profile: ${AWS_PROFILE}"
  fi

  # Prerequisites and Validation
  if ! check_command "aws"; then # Check for aws first
      echo "Please install AWS CLI first and configure your credentials."
      exit 1
  fi
  # Note: jq check/install is handled within get_distribution_id_by_alias

  if [ -z "$LOCAL_PATH_TO_SYNC_FILES_FROM" ] || [ ! -d "$LOCAL_PATH_TO_SYNC_FILES_FROM" ]; then
    echo "Error: LOCAL_PATH_TO_SYNC_FILES_FROM ('$LOCAL_PATH_TO_SYNC_FILES_FROM') is not set or not a valid directory."; exit 1
  fi
  if [ -z "$BUCKET_NAME" ]; then
    echo "Error: BUCKET_NAME is not set."; exit 1
  fi

  # Determine Distribution ID
  if [ -z "$DISTRIBUTION_ID" ]; then
      if [ -z "$CLOUDFRONT_ALIAS" ]; then
          echo "Error: You must set either DISTRIBUTION_ID or CLOUDFRONT_ALIAS."; exit 1
      fi
      # Dynamic lookup triggers jq check/install internally
      DISTRIBUTION_ID=$(get_distribution_id_by_alias "$CLOUDFRONT_ALIAS" "$AWS_CLI_OPTIONS")
      if [ $? -ne 0 ] || [ -z "$DISTRIBUTION_ID" ]; then
          echo "Error: Failed to retrieve Distribution ID for alias '$CLOUDFRONT_ALIAS'."; exit 1
      fi
  else
      echo "Using explicitly set Distribution ID: ${DISTRIBUTION_ID}"
      # Check/install jq only if dynamic lookup was skipped but jq might be needed later (defensive check)
      # if ! install_jq_if_missing; then exit 1; fi
      # ^^ Actually, if ID is set explicitly, jq isn't needed by *this* script anymore.
  fi

  # Execute Deployment
  sync_and_invalidate "$LOCAL_PATH_TO_SYNC_FILES_FROM" "$BUCKET_NAME" "$DISTRIBUTION_ID" "$AWS_CLI_OPTIONS"

  echo ""
  echo "Deployment process completed successfully."
}

# Script Entry Point
main "$@"

exit 0
