#!/bin/bash

set -euo pipefail
umask 077  # ensure files created are not world-readable; reduces race/snoop risk

###############################################################################
# Script : gcp_export_vm_full_api.sh
# Purpose : Export GCP VM disks to a GCS bucket using ONLY REST APIs (curl),
#           including complete VM configuration, with parallel VMs and disks.
#
# Notes :
#   - No gcloud or gsutil usage; auth via metadata server or SA_TOKEN env
#   - Parallel processing of disks and VMs with independent concurrency limits
#   - VM discovery by zone, region, or across the project, with label filtering
#   - Requires: curl, jq, openssl (optional for future JWT flow)
###############################################################################

# === Configuration ===
# Modify these variables according to your needs
readonly PROJECT_ID="${PROJECT_ID:-my-gcp-project}"
readonly ZONE="${ZONE:-}"                 # Leave empty to discover all VMs, or specify zone
readonly INSTANCE_NAME="${INSTANCE_NAME:-}" # Leave empty for discovery, or specify exact instance
readonly REGION="${REGION:-}"             # Optional: specify region for discovery
readonly EXPORT_FORMAT="${EXPORT_FORMAT:-vmdk}"  # vmdk, qcow2, or raw
readonly MAX_PARALLEL="${MAX_PARALLEL:-4}"      # Disks per VM
readonly MAX_VM_PARALLEL="${MAX_VM_PARALLEL:-2}" # VMs in parallel
readonly FILTER_TAG_KEY="${FILTER_TAG_KEY:-}"   # Optional label key
readonly FILTER_TAG_VALUE="${FILTER_TAG_VALUE:-}" # Optional label value
readonly FILTER_TAG_MODE="${FILTER_TAG_MODE:-and}" # and | or

# Generate unique names based on date/time
readonly TIMESTAMP=$(date +%Y%m%d%H%M%S)
readonly BUCKET_NAME="${BUCKET_NAME:-gcp-disk-exports-${TIMESTAMP}}"
readonly BASE_DIR="/tmp/gcp-exports-${TIMESTAMP}"
mkdir -p "$BASE_DIR"

# Colors for logging
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# === Utility Functions ===

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}" >&2; }

# Also mirror logs to a per-VM file when VM_LOG_FILE is set (thread-safe append)
log_append_if_set() {
  local line="$1"
  if [ -n "${VM_LOG_FILE:-}" ]; then
    # shellcheck disable=SC2129
    echo "$line" >> "$VM_LOG_FILE"
  fi
}

log_info_sync() {
  echo -e "${BLUE}ℹ️  $1${NC}" | while IFS= read -r line; do tsline="[$(date +%H:%M:%S)] $line"; echo "$tsline"; log_append_if_set "$tsline"; done
}
log_success_sync() {
  echo -e "${GREEN}✅ $1${NC}" | while IFS= read -r line; do tsline="[$(date +%H:%M:%S)] $line"; echo "$tsline"; log_append_if_set "$tsline"; done
}

cleanup() {
  log_info "Cleaning up temporary files..."
  rm -rf "$BASE_DIR"
}

error_exit() { log_error "$1"; cleanup; exit 1; }

trap cleanup EXIT
trap 'error_exit "Script interrupted"' INT TERM

# === Prerequisites Check ===

check_prerequisites() {
  log_info "Checking prerequisites..."

  local errors=()

  if ! command -v curl >/dev/null 2>&1; then
    errors+=("curl is not installed")
  fi

  if ! command -v jq >/dev/null 2>&1; then
    errors+=("jq is not installed (required for JSON parsing)")
  fi

  if [ -z "${PROJECT_ID:-}" ]; then
    errors+=("PROJECT_ID is not set")
  fi

  # Try to obtain an access token without failing fast
  local token=""
  if [ -n "${SA_TOKEN:-}" ]; then
    token="$SA_TOKEN"
  else
    token=$(get_access_token_metadata || true)
  fi

  if [ -z "$token" ]; then
    errors+=("No access token available. Set SA_TOKEN or run on GCE/Cloud Shell with metadata server access")
  else
    ACCESS_TOKEN="$token"
  fi

  if [ ${#errors[@]} -gt 0 ]; then
    log_error "One or more prerequisites are not met:"
    for e in "${errors[@]}"; do
      log_error " - $e"
    done
    error_exit "Prerequisites check failed"
  fi

  log_success "Prerequisites satisfied"
}

# === Authentication (REST only) ===
# Option A: Use metadata server (GCE/Cloud Shell). Option B: use SA_TOKEN env var.

get_access_token_metadata() {
  curl -s -H "Metadata-Flavor: Google" \
    "http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token" \
    | jq -r '.access_token // empty'
}

get_access_token() {
  if [ -n "${SA_TOKEN:-}" ]; then
    echo "$SA_TOKEN"
    return 0
  fi
  get_access_token_metadata || true
}

gcp_api_call() {
  local method="$1"  # GET, POST, DELETE
  local endpoint="$2"
  local access_token="$3"
  local data="${4:-}"
  local content_type="${5:-application/json}"

  local headers=(
    "Authorization: Bearer $access_token"
    "Content-Type: $content_type"
  )

  case "$method" in
    GET) curl -s -H "${headers[0]}" "$endpoint" ;;
    POST) curl -s -X POST -H "${headers[0]}" -H "${headers[1]}" -d "$data" "$endpoint" ;;
    DELETE) curl -s -X DELETE -H "${headers[0]}" "$endpoint" ;;
    *) echo "" ;;
  esac
}

# GCS helpers (JSON API)
gcs_bucket_exists() {
  local bucket="$1" token="$2"
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $token" \
    "https://storage.googleapis.com/storage/v1/b/${bucket}") || true
  [ "$status" = "200" ]
}

gcs_upload_json() {
  local bucket="$1" object_name="$2" file_path="$3" token="$4"
  local boundary="====$(date +%s%N)===="
  local meta
  meta=$(jq -n --arg name "$object_name" '{name:$name, contentType:"application/json"}')
  curl -s -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: multipart/related; boundary=$boundary" \
    --data-binary @- \
    "https://storage.googleapis.com/upload/storage/v1/b/${bucket}/o?uploadType=multipart" >/dev/null <<EOF
--$boundary
Content-Type: application/json; charset=UTF-8

$meta
--$boundary
Content-Type: application/json

$(cat "$file_path")
--$boundary--
EOF
}

# Generic file upload (multipart) with provided content type
gcs_upload_file() {
  local bucket="$1" object_name="$2" file_path="$3" token="$4" ctype="$5"
  local boundary="====$(date +%s%N)===="
  local meta
  meta=$(jq -n --arg name "$object_name" --arg ct "$ctype" '{name:$name, contentType:$ct}')
  curl -s -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: multipart/related; boundary=$boundary" \
    --data-binary @- \
    "https://storage.googleapis.com/upload/storage/v1/b/${bucket}/o?uploadType=multipart" >/dev/null <<EOF
--$boundary
Content-Type: application/json; charset=UTF-8

$meta
--$boundary
Content-Type: $ctype

$(cat "$file_path")
--$boundary--
EOF
}

# Upload JSON content without writing to disk
# (intentionally no in-memory upload helper in rollback)

# Tag/label filtering
vm_matches_tags() {
  local vm_info="$1"
  if [ -z "$FILTER_TAG_KEY" ] && [ -z "$FILTER_TAG_VALUE" ]; then return 0; fi
  local has_labels
  has_labels=$(echo "$vm_info" | jq 'has("labels")')
  [ "$has_labels" = "true" ] || return 1

  local key_match=false value_match=false
  if [ -n "$FILTER_TAG_KEY" ]; then
    local has_key
    has_key=$(echo "$vm_info" | jq -r --arg k "$FILTER_TAG_KEY" '.labels | has($k)')
    [ "$has_key" = "true" ] && key_match=true
  else
    key_match=true
  fi

  if [ -n "$FILTER_TAG_VALUE" ]; then
    if [ -n "$FILTER_TAG_KEY" ]; then
      local val
      val=$(echo "$vm_info" | jq -r --arg k "$FILTER_TAG_KEY" '.labels[$k] // ""')
      [ "$val" = "$FILTER_TAG_VALUE" ] && value_match=true
    else
      local any
      any=$(echo "$vm_info" | jq -r --arg v "$FILTER_TAG_VALUE" '.labels | to_entries[] | select(.value == $v) | .key' || true)
      [ -n "$any" ] && value_match=true
    fi
  else
    value_match=true
  fi

  if [ "$FILTER_TAG_MODE" = "or" ]; then
    [ "$key_match" = "true" ] || [ "$value_match" = "true" ]
  else
    [ "$key_match" = "true" ] && [ "$value_match" = "true" ]
  fi
}

# VM discovery (REST)
discover_vms() {
  local access_token="$1"
  local vm_list_file="$BASE_DIR/vm-list.json"
  
  if [ -n "$INSTANCE_NAME" ] && [ -n "$ZONE" ]; then
    local instance_endpoint="https://compute.googleapis.com/compute/v1/projects/$PROJECT_ID/zones/$ZONE/instances/$INSTANCE_NAME"
    local instance_info
    instance_info=$(gcp_api_call GET "$instance_endpoint" "$access_token")
    if echo "$instance_info" | jq -e '.error' >/dev/null 2>&1; then
      log_error "Instance $INSTANCE_NAME not found in zone $ZONE"
      echo "[]" > "$vm_list_file"; return 1
    fi
    echo "[{\"name\":\"$INSTANCE_NAME\",\"zone\":\"$ZONE\",\"info\":$(echo "$instance_info" | jq -c .)}]" > "$vm_list_file"
    return 0
  fi

  log_info "Discovering VMs in project $PROJECT_ID..."
  if [ -n "$FILTER_TAG_KEY" ] || [ -n "$FILTER_TAG_VALUE" ]; then
    local msg="Filtering by tag"; [ -n "$FILTER_TAG_KEY" ] && msg="$msg key='$FILTER_TAG_KEY'"; [ -n "$FILTER_TAG_VALUE" ] && msg="$msg value='$FILTER_TAG_VALUE'"; log_info "$msg (mode: $FILTER_TAG_MODE)"
  fi

  local zones_to_search=()
  if [ -n "$ZONE" ]; then
    zones_to_search=("$ZONE")
  elif [ -n "$REGION" ]; then
    local zones
    zones=$(gcp_api_call GET "https://compute.googleapis.com/compute/v1/projects/$PROJECT_ID/regions/$REGION/zones" "$access_token" | jq -r '.items[]?.name // empty')
    readarray -t zones_to_search <<< "$zones"
  else
    local zones
    zones=$(gcp_api_call GET "https://compute.googleapis.com/compute/v1/projects/$PROJECT_ID/zones" "$access_token" | jq -r '.items[]?.name // empty')
    readarray -t zones_to_search <<< "$zones"
  fi

  local temp_file; temp_file=$(mktemp)
  for zone in "${zones_to_search[@]}"; do
    [ -z "$zone" ] && continue
    log_info "Checking zone: $zone"
    local zone_instances
    zone_instances=$(gcp_api_call GET "https://compute.googleapis.com/compute/v1/projects/$PROJECT_ID/zones/$zone/instances" "$access_token")
    if echo "$zone_instances" | jq -e '.items' >/dev/null 2>&1; then
      echo "$zone_instances" | jq -c '.items[]?' | while read -r vm_info; do
        [ -z "$vm_info" ] && continue
        if vm_matches_tags "$vm_info"; then
          local vm_name
          vm_name=$(echo "$vm_info" | jq -r '.name')
          echo "{\"name\":\"$vm_name\",\"zone\":\"$zone\",\"info\":$vm_info}" >> "$temp_file"
        fi
      done
    fi
  done

  if [ -s "$temp_file" ]; then
    jq -s '.' "$temp_file" > "$vm_list_file" || echo "[]" > "$vm_list_file"
  else
    echo "[]" > "$vm_list_file"
  fi
  local count; count=$(jq 'length' "$vm_list_file")
  rm -f "$temp_file"
  log_success "Discovered $count VM(s)"
}

# Disk export (REST)
export_disk() {
  local VM_NAME="$1" VM_ZONE="$2" DISK_NAME="$3" DISK_INDEX="$4" ACCESS_TOKEN="$5"
  local DISK_TS SNAP_NAME IMAGE_NAME DEST_URI SUCCESS
  DISK_TS=$(date +%Y%m%d%H%M%S)
  SNAP_NAME="${VM_NAME}-${DISK_NAME}-snap-${DISK_TS}"
  IMAGE_NAME="${SNAP_NAME}-image"
  DEST_URI="gs://${BUCKET_NAME}/${VM_NAME}/${DISK_NAME}.${EXPORT_FORMAT}.gz"
  SUCCESS=false

  [ -n "$ACCESS_TOKEN" ] || { log_error "[$VM_NAME:$DISK_INDEX] Missing access token"; echo "{}" > "$OUTPUT_FILE"; return 1; }

  log_info_sync "[$VM_NAME:$DISK_INDEX] Creating snapshot : $SNAP_NAME"
  local SNAP_ENDPOINT="https://compute.googleapis.com/compute/v1/projects/$PROJECT_ID/zones/$VM_ZONE/disks/$DISK_NAME/createSnapshot"
  local SNAP_PAYLOAD; SNAP_PAYLOAD=$(jq -n --arg name "$SNAP_NAME" '{name:$name}')
  local SNAP_RESPONSE; SNAP_RESPONSE=$(gcp_api_call POST "$SNAP_ENDPOINT" "$ACCESS_TOKEN" "$SNAP_PAYLOAD")
  if echo "$SNAP_RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
    log_error "[$VM_NAME:$DISK_INDEX] Failed to create snapshot for $DISK_NAME"
    echo "$SNAP_RESPONSE" | jq -r '.error.message // "Unknown error"' >&2
    echo "{}" > "$OUTPUT_FILE"; return 1
  fi

  # Wait for snapshot ready
  local SNAP_URL="https://compute.googleapis.com/compute/v1/projects/$PROJECT_ID/global/snapshots/$SNAP_NAME"
  local waited=0 max_wait=60 SNAP_STATUS=""
  while [ $waited -lt $max_wait ]; do
    SNAP_STATUS=$(gcp_api_call GET "$SNAP_URL" "$ACCESS_TOKEN" | jq -r '.status // ""')
    [ "$SNAP_STATUS" = "READY" ] && break
    sleep 5; waited=$((waited+5))
  done
  if [ "$SNAP_STATUS" != "READY" ]; then
    log_error "[$VM_NAME:$DISK_INDEX] Snapshot not ready after $max_wait seconds"
    gcp_api_call DELETE "$SNAP_URL" "$ACCESS_TOKEN" >/dev/null 2>&1 || true
    echo "{}" > "$OUTPUT_FILE"; return 1
  fi

  log_info_sync "[$VM_NAME:$DISK_INDEX] Creating image : $IMAGE_NAME"
  local IMG_ENDPOINT="https://compute.googleapis.com/compute/v1/projects/$PROJECT_ID/global/images"
  local IMG_PAYLOAD; IMG_PAYLOAD=$(jq -n --arg name "$IMAGE_NAME" --arg snap "projects/$PROJECT_ID/global/snapshots/$SNAP_NAME" '{name:$name, sourceSnapshot:$snap, family:"export-temp"}')
  local IMG_RESPONSE; IMG_RESPONSE=$(gcp_api_call POST "$IMG_ENDPOINT" "$ACCESS_TOKEN" "$IMG_PAYLOAD")
  if echo "$IMG_RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
    log_error "[$VM_NAME:$DISK_INDEX] Failed to create image for $DISK_NAME"
    gcp_api_call DELETE "$SNAP_URL" "$ACCESS_TOKEN" >/dev/null 2>&1 || true
    echo "{}" > "$OUTPUT_FILE"; return 1
  fi

  local IMG_URL="https://compute.googleapis.com/compute/v1/projects/$PROJECT_ID/global/images/$IMAGE_NAME"
  waited=0; local IMG_STATUS=""
  while [ $waited -lt $max_wait ]; do
    IMG_STATUS=$(gcp_api_call GET "$IMG_URL" "$ACCESS_TOKEN" | jq -r '.status // ""')
    [ "$IMG_STATUS" = "READY" ] && break
    sleep 5; waited=$((waited+5))
  done
  if [ "$IMG_STATUS" != "READY" ]; then
    log_error "[$VM_NAME:$DISK_INDEX] Image not ready after $max_wait seconds"
    gcp_api_call DELETE "$SNAP_URL" "$ACCESS_TOKEN" >/dev/null 2>&1 || true
    gcp_api_call DELETE "$IMG_URL" "$ACCESS_TOKEN" >/dev/null 2>&1 || true
    echo "{}" > "$OUTPUT_FILE"; return 1
  fi

  log_info_sync "[$VM_NAME:$DISK_INDEX] Exporting to Cloud Storage : $DEST_URI"
  local EXPORT_ENDPOINT="https://compute.googleapis.com/compute/v1/projects/$PROJECT_ID/global/images/$IMAGE_NAME/export"
  local EXPORT_PAYLOAD; EXPORT_PAYLOAD=$(jq -n --arg fmt "$EXPORT_FORMAT" --arg uri "$DEST_URI" '{destinationFormat:$fmt, destinationUri:$uri}')
  local EXPORT_RESPONSE; EXPORT_RESPONSE=$(gcp_api_call POST "$EXPORT_ENDPOINT" "$ACCESS_TOKEN" "$EXPORT_PAYLOAD")
  if echo "$EXPORT_RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
    log_error "[$VM_NAME:$DISK_INDEX] Failed to export $DISK_NAME"
    gcp_api_call DELETE "$SNAP_URL" "$ACCESS_TOKEN" >/dev/null 2>&1 || true
    gcp_api_call DELETE "$IMG_URL" "$ACCESS_TOKEN" >/dev/null 2>&1 || true
    echo "{}" > "$OUTPUT_FILE"; return 1
  fi

  log_success_sync "[$VM_NAME:$DISK_INDEX] Export successful : $DEST_URI"; SUCCESS=true

  log_info_sync "[$VM_NAME:$DISK_INDEX] Cleaning up temporary resources..."
  gcp_api_call DELETE "$SNAP_URL" "$ACCESS_TOKEN" >/dev/null 2>&1 || true
  gcp_api_call DELETE "$IMG_URL" "$ACCESS_TOKEN" >/dev/null 2>&1 || true

  # Write per-disk result JSON locally (for aggregation) and upload later
  local OUTPUT_FILE="$BASE_DIR/${VM_NAME}-${DISK_NAME}-export.json"
  cat > "$OUTPUT_FILE" <<EOF
{
  "disk_name": "$DISK_NAME",
  "snapshot_name": "$SNAP_NAME",
  "export_uri": "$DEST_URI",
  "export_format": "$EXPORT_FORMAT",
  "instance": "$VM_NAME",
  "zone": "$VM_ZONE",
  "timestamp": "$DISK_TS",
  "success": $SUCCESS
}
EOF
}

# VM export (REST)
export_vm() {
  local VM_NAME="$1" VM_ZONE="$2" INSTANCE_INFO="$3" ACCESS_TOKEN="$4"
  log_info "Processing VM: $VM_NAME in zone $VM_ZONE"

  # Setup per-VM logfile (inherited by disk jobs)
  VM_LOG_FILE="$BASE_DIR/${VM_NAME}-export.log"
  : > "$VM_LOG_FILE"
  log_info_sync "Starting VM export: $VM_NAME"

  # Write instance configuration locally and upload via GCS JSON API
  local VM_CONFIG_FILE="$BASE_DIR/${VM_NAME}-config.json"
  echo "$INSTANCE_INFO" | jq . > "$VM_CONFIG_FILE"
  gcs_upload_json "$BUCKET_NAME" "$VM_NAME/instance_config.json" "$VM_CONFIG_FILE" "$ACCESS_TOKEN"

  local VM_METADATA_FILE="$BASE_DIR/${VM_NAME}-metadata.json"
  echo "[" > "$VM_METADATA_FILE"
  local DISKS
  DISKS=$(echo "$INSTANCE_INFO" | jq -r '.disks[] | .deviceName // .source | split("/") | .[-1]' | grep -v "^$")
  if [ -z "$DISKS" ]; then
    log_warning "No disks found for VM $VM_NAME";
    echo "[]" > "$VM_METADATA_FILE"
    gcs_upload_json "$BUCKET_NAME" "$VM_NAME/metadata.json" "$VM_METADATA_FILE" "$ACCESS_TOKEN"
    return 0
  fi
  readarray -t DISK_ARRAY <<< "$DISKS"; local TOTAL_DISKS=${#DISK_ARRAY[@]}
  log_info "VM $VM_NAME has $TOTAL_DISKS disk(s)"

  local ACTIVE_JOBS=0 DISK_INDEX=0 SUCCESSFUL_EXPORTS=0
  while [ $DISK_INDEX -lt $TOTAL_DISKS ]; do
    if [ $ACTIVE_JOBS -lt $MAX_PARALLEL ]; then
      DISK_INDEX=$((DISK_INDEX + 1)); local DISK_NAME="${DISK_ARRAY[$((DISK_INDEX - 1))]}"
      export_disk "$VM_NAME" "$VM_ZONE" "$DISK_NAME" "$DISK_INDEX" "$ACCESS_TOKEN" &
      ACTIVE_JOBS=$((ACTIVE_JOBS + 1))
    else
      wait -n; ACTIVE_JOBS=$((ACTIVE_JOBS - 1))
    fi
  done
  while [ $ACTIVE_JOBS -gt 0 ]; do wait -n; ACTIVE_JOBS=$((ACTIVE_JOBS - 1)); done

  # Gather results from local per-disk JSONs and upload as metadata.json
  local FIRST=true
  for DISK_NAME in "${DISK_ARRAY[@]}"; do
    local OUTPUT_FILE="$BASE_DIR/${VM_NAME}-${DISK_NAME}-export.json"
    if [ -f "$OUTPUT_FILE" ]; then
      if grep -q '"success": *true' "$OUTPUT_FILE" 2>/dev/null; then SUCCESSFUL_EXPORTS=$((SUCCESSFUL_EXPORTS + 1)); fi
      [ "$FIRST" = false ] && echo "," >> "$VM_METADATA_FILE"
      sed -e '1s/^{$//' -e '$s/^}$//' -e 's/^/  /' "$OUTPUT_FILE" >> "$VM_METADATA_FILE"; FIRST=false
    fi
  done
  echo -e "\n]" >> "$VM_METADATA_FILE"
  gcs_upload_json "$BUCKET_NAME" "$VM_NAME/metadata.json" "$VM_METADATA_FILE" "$ACCESS_TOKEN"
  log_success "VM $VM_NAME: $SUCCESSFUL_EXPORTS/$TOTAL_DISKS disks exported successfully"

  # Upload per-VM export log
  local LOG_OBJECT="$VM_NAME/logs/export-$TIMESTAMP.log"
  gcs_upload_file "$BUCKET_NAME" "$LOG_OBJECT" "$VM_LOG_FILE" "$ACCESS_TOKEN" "text/plain"
  log_success "Uploaded VM log: gs://${BUCKET_NAME}/${LOG_OBJECT}"
}

########## Main ##########

# Run prerequisite checks (aggregate errors, then fail if any)
check_prerequisites

# Ensure we have a token (set by check_prerequisites or fallback)
ACCESS_TOKEN="${ACCESS_TOKEN:-$(get_access_token)}"
[ -n "$ACCESS_TOKEN" ] || error_exit "Unable to obtain access token via metadata server or SA_TOKEN"

# Bucket existence check (do NOT create)
log_info "Checking bucket..."
if ! gcs_bucket_exists "$BUCKET_NAME" "$ACCESS_TOKEN"; then
  error_exit "Bucket gs://${BUCKET_NAME} does not exist"
fi
log_success "Bucket exists : gs://${BUCKET_NAME}"

# Discover VMs (write to file in BASE_DIR)
discover_vms "$ACCESS_TOKEN"
VM_LIST_FILE="$BASE_DIR/vm-list.json"
VM_COUNT=$(jq 'length' "$VM_LIST_FILE")
[ "$VM_COUNT" -gt 0 ] || error_exit "No VMs found to export"
log_success "Found $VM_COUNT VM(s) to export"

# Parallel VM processing
log_info "Starting parallel VM processing (max $MAX_VM_PARALLEL VMs simultaneously)..."
ACTIVE_VM_JOBS=0; VM_INDEX=0
while [ $VM_INDEX -lt $VM_COUNT ]; do
  if [ $ACTIVE_VM_JOBS -lt $MAX_VM_PARALLEL ]; then
    VM_INDEX=$((VM_INDEX + 1))
    VM_NAME=$(jq -r ".[$((VM_INDEX - 1))].name" "$VM_LIST_FILE")
    VM_ZONE=$(jq -r ".[$((VM_INDEX - 1))].zone" "$VM_LIST_FILE")
    VM_INFO=$(jq -r ".[$((VM_INDEX - 1))].info" "$VM_LIST_FILE")
    log_info "Starting export for VM [$VM_INDEX/$VM_COUNT]: $VM_NAME"
    export_vm "$VM_NAME" "$VM_ZONE" "$VM_INFO" "$ACCESS_TOKEN" &
    ACTIVE_VM_JOBS=$((ACTIVE_VM_JOBS + 1))
  else
    wait -n; ACTIVE_VM_JOBS=$((ACTIVE_VM_JOBS - 1))
  fi
done
while [ $ACTIVE_VM_JOBS -gt 0 ]; do wait -n; ACTIVE_VM_JOBS=$((ACTIVE_VM_JOBS - 1)); done

log_success "All VM exports completed"
echo ""
log_info "📁 Files available in gs://${BUCKET_NAME}/"
echo "   • Each VM has its own folder: gs://${BUCKET_NAME}/{vm-name}/"
echo "   • instance_config.json : complete VM configuration per VM"
echo "   • metadata.json : disk export index per VM"
echo "   • *.${EXPORT_FORMAT}.gz : disk archives per VM"
echo ""
log_info "📊 Export details :"
echo "   • VMs processed : $VM_COUNT"
echo "   • Format : $EXPORT_FORMAT"
echo "   • Timestamp : $TIMESTAMP"
echo "   • Bucket : gs://${BUCKET_NAME}/"


