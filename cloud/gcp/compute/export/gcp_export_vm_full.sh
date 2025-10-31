#!/bin/bash

set -euo pipefail  # Exit on error, undefined vars, pipe failures

###############################################################################
# Script : gcp_export_vm_full.sh
# Purpose : Export GCP VM disks to a GCS bucket,
#           including the complete VM configuration.
#
# Notes :
#   - Uses GCP REST API directly via curl for better performance
#   - Parallel processing of disks and VMs with control over simultaneous jobs
#   - Supports VM discovery by zone, region, or all VMs in project
#   - Requires : gcloud, curl, jq, gsutil
###############################################################################

# === Configuration ===
# Modify these variables according to your needs
readonly PROJECT_ID="${PROJECT_ID:-my-gcp-project}"
readonly ZONE="${ZONE:-}"  # Leave empty to discover all VMs, or specify zone
readonly INSTANCE_NAME="${INSTANCE_NAME:-}"  # Leave empty for discovery, or specify exact instance
readonly REGION="${REGION:-}"  # Optional: specify region for discovery
readonly EXPORT_FORMAT="${EXPORT_FORMAT:-vmdk}"  # vmdk, qcow2, or raw
readonly SKIP_AUTH="${SKIP_AUTH:-false}"
readonly MAX_PARALLEL="${MAX_PARALLEL:-4}"  # Maximum number of disks per VM to process in parallel
readonly MAX_VM_PARALLEL="${MAX_VM_PARALLEL:-2}"  # Maximum number of VMs to process simultaneously
readonly FILTER_TAG_KEY="${FILTER_TAG_KEY:-}"  # Optional: filter VMs by label key (e.g., "environment")
readonly FILTER_TAG_VALUE="${FILTER_TAG_VALUE:-}"  # Optional: filter VMs by label value (e.g., "production")
readonly FILTER_TAG_MODE="${FILTER_TAG_MODE:-and}"  # "and" or "or" for multiple tag filtering

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

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}" >&2
}

log_info_sync() {
    # Log thread-safe with a simple lock
    echo -e "${BLUE}ℹ️  $1${NC}" | while IFS= read -r line; do
        echo "[$(date +%H:%M:%S)] $line"
    done
}

log_success_sync() {
    echo -e "${GREEN}✅ $1${NC}" | while IFS= read -r line; do
        echo "[$(date +%H:%M:%S)] $line"
    done
}

cleanup() {
    log_info "Cleaning up temporary files..."
    rm -rf "$BASE_DIR"
}

# Function to get an OAuth2 access token
get_access_token() {
    gcloud auth print-access-token 2>/dev/null
}

# Function to call GCP REST API
gcp_api_call() {
    local method="$1"  # GET, POST, DELETE
    local endpoint="$2"
    local access_token="$3"
    local data="${4:-}"
    
    local headers=(
        "Authorization: Bearer $access_token"
        "Content-Type: application/json"
    )
    
    if [ "$method" = "GET" ]; then
        curl -s -H "${headers[0]}" "$endpoint"
    elif [ "$method" = "POST" ]; then
        curl -s -X POST -H "${headers[0]}" -H "${headers[1]}" -d "$data" "$endpoint"
    elif [ "$method" = "DELETE" ]; then
        curl -s -X DELETE -H "${headers[0]}" "$endpoint"
    fi
}

# Function to check if a VM matches tag filters
vm_matches_tags() {
    local vm_info="$1"
    
    # If no filters specified, include all VMs
    if [ -z "$FILTER_TAG_KEY" ] && [ -z "$FILTER_TAG_VALUE" ]; then
        return 0
    fi
    
    # Check if VM has labels
    local has_labels=$(echo "$vm_info" | jq 'has("labels")')
    if [ "$has_labels" != "true" ]; then
        return 1
    fi
    
    # Get labels from VM
    local vm_labels=$(echo "$vm_info" | jq -c '.labels')
    
    # Check key filter
    local key_match=false
    local value_match=false
    
    if [ -n "$FILTER_TAG_KEY" ]; then
        local has_key=$(echo "$vm_info" | jq -r --arg key "$FILTER_TAG_KEY" '.labels | has($key)')
        if [ "$has_key" = "true" ]; then
            key_match=true
        fi
    else
        key_match=true  # No key filter specified, so always match
    fi
    
    # Check value filter
    if [ -n "$FILTER_TAG_VALUE" ]; then
        # If we have a specific key, check that key's value
        if [ -n "$FILTER_TAG_KEY" ]; then
            local actual_value=$(echo "$vm_info" | jq -r --arg key "$FILTER_TAG_KEY" '.labels[$key] // ""')
            if [ "$actual_value" = "$FILTER_TAG_VALUE" ]; then
                value_match=true
            fi
        else
            # Check if any label value matches
            local values_match=$(echo "$vm_info" | jq -r --arg val "$FILTER_TAG_VALUE" '.labels | to_entries[] | select(.value == $val)')
            if [ -n "$values_match" ]; then
                value_match=true
            fi
        fi
    else
        value_match=true  # No value filter specified, so always match
    fi
    
    # Apply filter mode
    if [ "$FILTER_TAG_MODE" = "or" ]; then
        [ "$key_match" = "true" ] || [ "$value_match" = "true" ]
    else
        # Default: "and" mode
        [ "$key_match" = "true" ] && [ "$value_match" = "true" ]
    fi
}

# Function to discover VMs
discover_vms() {
    local access_token="$1"
    local vm_list_file="$BASE_DIR/vm-list.json"
    
    if [ -n "$INSTANCE_NAME" ] && [ -n "$ZONE" ]; then
        # Single VM mode
        local instance_endpoint="https://compute.googleapis.com/compute/v1/projects/$PROJECT_ID/zones/$ZONE/instances/$INSTANCE_NAME"
        local instance_info=$(gcp_api_call GET "$instance_endpoint" "$access_token")
        
        if echo "$instance_info" | jq -e '.error' >/dev/null 2>&1; then
            log_error "Instance $INSTANCE_NAME not found in zone $ZONE"
            echo "[]" > "$vm_list_file"
            return 1
        fi
        
        # Create array with single VM
        echo "[{\"name\":\"$INSTANCE_NAME\",\"zone\":\"$ZONE\",\"info\":$(echo "$instance_info" | jq -c .)}]" > "$vm_list_file"
        return 0
    fi
    
    # Discovery mode
    log_info "Discovering VMs in project $PROJECT_ID..."
    
    # Log filtering criteria if specified
    if [ -n "$FILTER_TAG_KEY" ] || [ -n "$FILTER_TAG_VALUE" ]; then
        local filter_msg="Filtering by tag"
        if [ -n "$FILTER_TAG_KEY" ]; then
            filter_msg="$filter_msg key='$FILTER_TAG_KEY'"
        fi
        if [ -n "$FILTER_TAG_VALUE" ]; then
            filter_msg="$filter_msg value='$FILTER_TAG_VALUE'"
        fi
        log_info "$filter_msg (mode: $FILTER_TAG_MODE)"
    fi
    
    local zones_to_search=()
    
    if [ -n "$ZONE" ]; then
        # Specific zone
        zones_to_search=("$ZONE")
    elif [ -n "$REGION" ]; then
        # All zones in region
        log_info "Getting zones in region $REGION..."
        local zones=$(gcp_api_call GET "https://compute.googleapis.com/compute/v1/projects/$PROJECT_ID/regions/$REGION/zones" "$access_token" | jq -r '.items[]?.name // empty')
        readarray -t zones_to_search <<< "$zones"
    else
        # All zones in project
        log_info "Getting all zones in project..."
        local zones=$(gcp_api_call GET "https://compute.googleapis.com/compute/v1/projects/$PROJECT_ID/zones" "$access_token" | jq -r '.items[]?.name // empty')
        readarray -t zones_to_search <<< "$zones"
    fi
    
    log_info "Searching in ${#zones_to_search[@]} zone(s)..."
    
    local vm_count=0
    local temp_file=$(mktemp)
    
    for zone in "${zones_to_search[@]}"; do
        if [ -z "$zone" ]; then continue; fi
        
        log_info "Checking zone: $zone"
        local zone_instances=$(gcp_api_call GET "https://compute.googleapis.com/compute/v1/projects/$PROJECT_ID/zones/$zone/instances" "$access_token")
        
        if echo "$zone_instances" | jq -e '.items' >/dev/null 2>&1; then
            # Process each instance with filtering
            echo "$zone_instances" | jq -c '.items[]?' | while read -r vm_info; do
                if [ -z "$vm_info" ]; then continue; fi
                
                # Apply tag filtering
                if vm_matches_tags "$vm_info"; then
                    local vm_name=$(echo "$vm_info" | jq -r '.name')
                    local instance_json="{\"name\":\"$vm_name\",\"zone\":\"$zone\",\"info\":$vm_info}"
                    echo "$instance_json" >> "$temp_file"
                fi
            done
        fi
    done
    
    # Count and format JSON properly
    if [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
        # Read all VMs and format as proper JSON array
        local vm_json=$(cat "$temp_file" | jq -s '.')
        echo "$vm_json" > "$vm_list_file"
        vm_count=$(jq 'length' "$vm_list_file")
    else
        echo "[]" > "$vm_list_file"
    fi
    
    rm -f "$temp_file"
    
    log_success "Discovered $vm_count VM(s)"
    return 0
}

# Function to export a single disk
export_disk() {
    local VM_NAME="$1"
    local VM_ZONE="$2"
    local DISK_NAME="$3"
    local DISK_INDEX="$4"
    local ACCESS_TOKEN="$5"
    local OUTPUT_FILE="$BASE_DIR/${VM_NAME}-${DISK_NAME}-export.json"
    
    local DISK_TS=$(date +%Y%m%d%H%M%S)
    local SNAP_NAME="${VM_NAME}-${DISK_NAME}-snap-${DISK_TS}"
    local IMAGE_NAME="${SNAP_NAME}-image"
    local DEST_URI="gs://${BUCKET_NAME}/${VM_NAME}/${DISK_NAME}.${EXPORT_FORMAT}.gz"
    local SUCCESS=false
    
    if [ -z "$ACCESS_TOKEN" ]; then
        log_error "[$VM_NAME:$DISK_INDEX] Unable to obtain access token"
        echo "{}" > "$OUTPUT_FILE"
        return 1
    fi
    
    log_info_sync "[$VM_NAME:$DISK_INDEX] Starting processing of : $DISK_NAME"
    
    # Create snapshot via API
    log_info_sync "[$VM_NAME:$DISK_INDEX] Creating snapshot : $SNAP_NAME"
    local SNAP_ENDPOINT="https://compute.googleapis.com/compute/v1/projects/$PROJECT_ID/zones/$VM_ZONE/disks/$DISK_NAME/createSnapshot"
    local SNAP_PAYLOAD="{\"name\":\"$SNAP_NAME\"}"
    local SNAP_RESPONSE=$(gcp_api_call POST "$SNAP_ENDPOINT" "$ACCESS_TOKEN" "$SNAP_PAYLOAD")
    
    if echo "$SNAP_RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
        log_error "[$VM_NAME:$DISK_INDEX] Failed to create snapshot for $DISK_NAME"
        echo "$SNAP_RESPONSE" | jq -r '.error.message // "Unknown error"' >&2
        echo "{}" > "$OUTPUT_FILE"
        return 1
    fi
    
    log_success_sync "[$VM_NAME:$DISK_INDEX] Snapshot created : $SNAP_NAME"
    
    # Wait for snapshot to be ready
    sleep 10
    local SNAP_STATUS=""
    local SNAP_URL="https://compute.googleapis.com/compute/v1/projects/$PROJECT_ID/global/snapshots/$SNAP_NAME"
    local max_wait=60
    local waited=0
    
    while [ $waited -lt $max_wait ]; do
        SNAP_STATUS=$(gcp_api_call GET "$SNAP_URL" "$ACCESS_TOKEN" | jq -r '.status // ""')
        if [ "$SNAP_STATUS" = "READY" ]; then
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done
    
    if [ "$SNAP_STATUS" != "READY" ]; then
        log_error "[$VM_NAME:$DISK_INDEX] Snapshot not ready after $max_wait seconds"
        gcp_api_call DELETE "$SNAP_URL" "$ACCESS_TOKEN" >/dev/null 2>&1
        echo "{}" > "$OUTPUT_FILE"
        return 1
    fi
    
    # Create image from snapshot via API
    log_info_sync "[$VM_NAME:$DISK_INDEX] Creating image : $IMAGE_NAME"
    local IMG_ENDPOINT="https://compute.googleapis.com/compute/v1/projects/$PROJECT_ID/global/images"
    local IMG_PAYLOAD="{\"name\":\"$IMAGE_NAME\",\"sourceSnapshot\":\"projects/$PROJECT_ID/global/snapshots/$SNAP_NAME\",\"family\":\"export-temp\"}"
    local IMG_RESPONSE=$(gcp_api_call POST "$IMG_ENDPOINT" "$ACCESS_TOKEN" "$IMG_PAYLOAD")
    
    if echo "$IMG_RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
        log_error "[$VM_NAME:$DISK_INDEX] Failed to create image for $DISK_NAME"
        echo "$IMG_RESPONSE" | jq -r '.error.message // "Unknown error"' >&2
        gcp_api_call DELETE "$SNAP_URL" "$ACCESS_TOKEN" >/dev/null 2>&1
        echo "{}" > "$OUTPUT_FILE"
        return 1
    fi
    
    # Wait for image to be ready
    sleep 10
    local IMG_STATUS=""
    local IMG_URL="https://compute.googleapis.com/compute/v1/projects/$PROJECT_ID/global/images/$IMAGE_NAME"
    waited=0
    
    while [ $waited -lt $max_wait ]; do
        IMG_STATUS=$(gcp_api_call GET "$IMG_URL" "$ACCESS_TOKEN" | jq -r '.status // ""')
        if [ "$IMG_STATUS" = "READY" ]; then
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done
    
    if [ "$IMG_STATUS" != "READY" ]; then
        log_error "[$VM_NAME:$DISK_INDEX] Image not ready after $max_wait seconds"
        gcp_api_call DELETE "$SNAP_URL" "$ACCESS_TOKEN" >/dev/null 2>&1 || true
        gcp_api_call DELETE "$IMG_URL" "$ACCESS_TOKEN" >/dev/null 2>&1 || true
        echo "{}" > "$OUTPUT_FILE"
        return 1
    fi
    
    # Export image to Cloud Storage via API
    log_info_sync "[$VM_NAME:$DISK_INDEX] Exporting to Cloud Storage : $DEST_URI"
    local EXPORT_ENDPOINT="https://compute.googleapis.com/compute/v1/projects/$PROJECT_ID/global/images/$IMAGE_NAME/export"
    local EXPORT_PAYLOAD="{\"destinationFormat\":\"$EXPORT_FORMAT\",\"destinationUri\":\"$DEST_URI\"}"
    local EXPORT_RESPONSE=$(gcp_api_call POST "$EXPORT_ENDPOINT" "$ACCESS_TOKEN" "$EXPORT_PAYLOAD")
    
    if echo "$EXPORT_RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
        log_error "[$VM_NAME:$DISK_INDEX] Failed to export $DISK_NAME"
        echo "$EXPORT_RESPONSE" | jq -r '.error.message // "Unknown error"' >&2
        gcp_api_call DELETE "$SNAP_URL" "$ACCESS_TOKEN" >/dev/null 2>&1 || true
        gcp_api_call DELETE "$IMG_URL" "$ACCESS_TOKEN" >/dev/null 2>&1 || true
        echo "{}" > "$OUTPUT_FILE"
        return 1
    fi
    
    log_success_sync "[$VM_NAME:$DISK_INDEX] Export successful : $DEST_URI"
    SUCCESS=true
    
    # Cleanup via API
    log_info_sync "[$VM_NAME:$DISK_INDEX] Cleaning up temporary resources..."
    gcp_api_call DELETE "$SNAP_URL" "$ACCESS_TOKEN" >/dev/null 2>&1 || true
    gcp_api_call DELETE "$IMG_URL" "$ACCESS_TOKEN" >/dev/null 2>&1 || true
    
    # Generate metadata JSON for this disk
    cat > "$OUTPUT_FILE" <<EOF
{
  "disk_name": "$DISK_NAME",
  "snapshot_name": "$SNAP_NAME",
  "export_uri": "$DEST_URI",
  "export_format": "$EXPORT_FORMAT",
  "instance": "$VM_NAME",
  "zone": "$VM_ZONE",
  "instance_config": "gs://${BUCKET_NAME}/${VM_NAME}/instance_config.json",
  "timestamp": "$DISK_TS",
  "success": $SUCCESS
}
EOF
    
    if [ "$SUCCESS" = true ]; then
        return 0
    else
        return 1
    fi
}

# Function to export a complete VM
export_vm() {
    local VM_NAME="$1"
    local VM_ZONE="$2"
    local INSTANCE_INFO="$3"
    local ACCESS_TOKEN="$4"
    
    log_info "Processing VM: $VM_NAME in zone $VM_ZONE"
    
    # Create VM-specific bucket path
    local VM_METADATA_FILE="$BASE_DIR/${VM_NAME}-metadata.json"
    local VM_CONFIG_FILE="$BASE_DIR/${VM_NAME}-config.json"
    
    # Export VM configuration
    echo "$INSTANCE_INFO" | jq . > "$VM_CONFIG_FILE"
    gsutil cp "$VM_CONFIG_FILE" "gs://${BUCKET_NAME}/${VM_NAME}/instance_config.json" >/dev/null 2>&1
    
    # Initialize metadata file
    echo "[" > "$VM_METADATA_FILE"
    
    # Get disk list
    local DISKS=$(echo "$INSTANCE_INFO" | jq -r '.disks[] | .deviceName // .source | split("/") | .[-1]' | grep -v "^$")
    
    if [ -z "$DISKS" ]; then
        log_warning "No disks found for VM $VM_NAME"
        echo "[]" > "$VM_METADATA_FILE"
        return 0
    fi
    
    # Convert to array
    readarray -t DISK_ARRAY <<< "$DISKS"
    local TOTAL_DISKS=${#DISK_ARRAY[@]}
    
    log_info "VM $VM_NAME has $TOTAL_DISKS disk(s)"
    
    # Process disks in parallel
    local ACTIVE_JOBS=0
    local DISK_INDEX=0
    local SUCCESSFUL_EXPORTS=0
    
    while [ $DISK_INDEX -lt $TOTAL_DISKS ]; do
        if [ $ACTIVE_JOBS -lt $MAX_PARALLEL ]; then
            DISK_INDEX=$((DISK_INDEX + 1))
            local DISK_NAME="${DISK_ARRAY[$((DISK_INDEX - 1))]}"
            
            export_disk "$VM_NAME" "$VM_ZONE" "$DISK_NAME" "$DISK_INDEX" "$ACCESS_TOKEN" &
            ACTIVE_JOBS=$((ACTIVE_JOBS + 1))
        else
            wait -n
            ACTIVE_JOBS=$((ACTIVE_JOBS - 1))
        fi
    done
    
    # Wait for remaining jobs
    while [ $ACTIVE_JOBS -gt 0 ]; do
        wait -n
        ACTIVE_JOBS=$((ACTIVE_JOBS - 1))
    done
    
    # Gather results
    local FIRST=true
    for DISK_NAME in "${DISK_ARRAY[@]}"; do
        local OUTPUT_FILE="$BASE_DIR/${VM_NAME}-${DISK_NAME}-export.json"
        
        if [ -f "$OUTPUT_FILE" ]; then
            if grep -q '"success": *true' "$OUTPUT_FILE" 2>/dev/null; then
                SUCCESSFUL_EXPORTS=$((SUCCESSFUL_EXPORTS + 1))
            fi
            
            if [ "$FIRST" = false ]; then
                echo "," >> "$VM_METADATA_FILE"
            fi
            
            sed -e '1s/^{$//' -e '$s/^}$//' -e 's/^/  /' "$OUTPUT_FILE" >> "$VM_METADATA_FILE"
            FIRST=false
        fi
    done
    
    echo -e "\n]" >> "$VM_METADATA_FILE"
    
    # Upload metadata
    gsutil cp "$VM_METADATA_FILE" "gs://${BUCKET_NAME}/${VM_NAME}/metadata.json" >/dev/null 2>&1
    
    log_success "VM $VM_NAME: $SUCCESSFUL_EXPORTS/$TOTAL_DISKS disks exported successfully"
}

error_exit() {
    log_error "$1"
    cleanup
    exit 1
}

# Handle script exit
trap cleanup EXIT
trap 'error_exit "Script interrupted"' INT TERM

# === Prerequisites Check ===

log_info "Checking prerequisites..."

if ! command -v gcloud &> /dev/null; then
    error_exit "gcloud CLI is not installed"
fi

if ! command -v curl &> /dev/null; then
    error_exit "curl is not installed"
fi

if ! command -v jq &> /dev/null; then
    error_exit "jq is not installed (required for JSON parsing)"
fi

# === Authentication ===

if [ "$SKIP_AUTH" != "true" ]; then
    log_info "Checking authentication..."
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
        log_warning "No active authentication detected"
        gcloud auth login
    fi
fi

# Configure project
gcloud config set project "$PROJECT_ID" >/dev/null 2>&1 || error_exit "Unable to configure project $PROJECT_ID"
log_success "Project configured : $PROJECT_ID"

# Get a global access token
ACCESS_TOKEN=$(get_access_token)
if [ -z "$ACCESS_TOKEN" ]; then
    error_exit "Unable to obtain OAuth2 access token"
fi

# === VM Discovery ===

if ! discover_vms "$ACCESS_TOKEN"; then
    error_exit "Failed to discover VMs"
fi

VM_LIST_FILE="$BASE_DIR/vm-list.json"
VM_COUNT=$(jq 'length' "$VM_LIST_FILE")

if [ "$VM_COUNT" -eq 0 ]; then
    error_exit "No VMs found to export"
fi

log_success "Found $VM_COUNT VM(s) to export"

# === Bucket Creation ===

log_info "Checking bucket..."
if ! gsutil ls -b "gs://${BUCKET_NAME}" >/dev/null 2>&1; then
    log_info "Creating bucket : gs://${BUCKET_NAME}"
    # Try to get zone from first VM or use default
    if [ "$VM_COUNT" -gt 0 ]; then
        local first_zone=$(jq -r '.[0].zone' "$VM_LIST_FILE")
    else
        local first_zone="${ZONE:-us-central1-b}"
    fi
    
    if ! gsutil mb -p "$PROJECT_ID" -l "$first_zone" "gs://${BUCKET_NAME}" 2>/dev/null; then
        error_exit "Unable to create bucket $BUCKET_NAME"
    fi
    log_success "Bucket created : gs://${BUCKET_NAME}"
else
    log_success "Bucket already exists : gs://${BUCKET_NAME}"
fi

# === Parallel VM Export ===

log_info "Starting parallel VM processing (max $MAX_VM_PARALLEL VMs simultaneously)..."

ACTIVE_VM_JOBS=0
VM_INDEX=0
TOTAL_EXPORTED_DISKS=0

# Process VMs in parallel
while [ $VM_INDEX -lt $VM_COUNT ]; do
    if [ $ACTIVE_VM_JOBS -lt $MAX_VM_PARALLEL ]; then
        VM_INDEX=$((VM_INDEX + 1))
        local VM_NAME=$(jq -r ".[$((VM_INDEX - 1))].name" "$VM_LIST_FILE")
        local VM_ZONE=$(jq -r ".[$((VM_INDEX - 1))].zone" "$VM_LIST_FILE")
        local VM_INFO=$(jq -r ".[$((VM_INDEX - 1))].info" "$VM_LIST_FILE")
        
        log_info "Starting export for VM [$VM_INDEX/$VM_COUNT]: $VM_NAME"
        export_vm "$VM_NAME" "$VM_ZONE" "$VM_INFO" "$ACCESS_TOKEN" &
        ACTIVE_VM_JOBS=$((ACTIVE_VM_JOBS + 1))
    else
        wait -n
        ACTIVE_VM_JOBS=$((ACTIVE_VM_JOBS - 1))
    fi
done

# Wait for all VM jobs to complete
while [ $ACTIVE_VM_JOBS -gt 0 ]; do
    wait -n
    ACTIVE_VM_JOBS=$((ACTIVE_VM_JOBS - 1))
done

log_success "All VM exports completed"

# === Summary ===

log_success "All exports completed successfully !"
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