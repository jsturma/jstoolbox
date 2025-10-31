#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Export all disks (OS + data) of an Azure VM to a Storage Account container based on snapshots.

Requirements:
- Only REST is used (curl-based). No Azure CLI required.
- AAD App registration with appropriate permissions:
  - ARM: Microsoft.Compute snapshots/disks/VM read+write
  - Storage data-plane: Blob Data Contributor (or higher) on the target account
- Environment variables for client credentials:
  - AZ_TENANT_ID, AZ_CLIENT_ID, AZ_CLIENT_SECRET

Usage:
  azure_export_vm_api.sh \
    --resource-group <vm_rg> \
    --vm-name <vm_name> \
    --storage-account <account_name> \
    --storage-container <container_name> \
    [--subscription <sub_id_or_name>] \
    [--snapshot-resource-group <rg_for_snapshots>] \
    [--sas-hours <hours>] \
    [--delete-snapshots true|false] \
    [--tags "k1=v1 k2=v2"]

Notes:
- Snapshots are created per attached managed disk; each snapshot is exported as a VHD blob.
- Exports use temporary SAS from snapshots and server-side copy to the destination container.
- When --delete-snapshots=true, snapshots will be removed after copy completes.
Notes on auth:
- Tokens are acquired via client credentials. Optionally pre-supply tokens:
  - AZ_ARM_TOKEN for ARM; AZ_STORAGE_TOKEN for Blob service.
EOF
}

log() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $*"
}

err() {
  echo "ERROR: $*" >&2
}

# Defaults
SUBSCRIPTION=""
VM_RG=""
VM_NAME=""
SNAPSHOT_RG=""
SA_NAME=""
SA_CONTAINER=""
SAS_HOURS=6
DELETE_SNAPSHOTS="false"
TAGS=""

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription)
      SUBSCRIPTION="$2"; shift 2 ;;
    --resource-group)
      VM_RG="$2"; shift 2 ;;
    --vm-name)
      VM_NAME="$2"; shift 2 ;;
    --snapshot-resource-group)
      SNAPSHOT_RG="$2"; shift 2 ;;
    --storage-account)
      SA_NAME="$2"; shift 2 ;;
    --storage-container)
      SA_CONTAINER="$2"; shift 2 ;;
    --sas-hours)
      SAS_HOURS="$2"; shift 2 ;;
    --delete-snapshots)
      DELETE_SNAPSHOTS="$2"; shift 2 ;;
    --tags)
      TAGS="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      err "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "$SA_NAME" || -z "$SA_CONTAINER" ]]; then
  err "Missing required arguments"
  usage
  exit 1
fi

if [[ -z "$SNAPSHOT_RG" ]]; then
  SNAPSHOT_RG="$VM_RG"
fi

timestamp() {
  date +%Y%m%d%H%M%S
}

require_tools() {
  for b in curl jq; do
    if ! command -v "$b" >/dev/null 2>&1; then
      err "$b is required"
      exit 1
    fi
  done
}

require_tools

ARM_API_VERSION_VM="2023-09-01"
ARM_API_VERSION_DISK="2023-04-02"
ARM_API_VERSION_SNAPSHOT="2023-04-02"
ARM_BASE="https://management.azure.com"

get_oauth_token() {
  local resource_scope="$1" # e.g. https://management.azure.com/.default or https://storage.azure.com/.default
  local token_env="$2"      # env var name to fallback
  local token_value
  token_value=${!token_env:-}
  if [[ -n "$token_value" ]]; then
    echo "$token_value"
    return 0
  fi
  if [[ -z "${AZ_TENANT_ID:-}" || -z "${AZ_CLIENT_ID:-}" || -z "${AZ_CLIENT_SECRET:-}" ]]; then
    err "AZ_TENANT_ID, AZ_CLIENT_ID, AZ_CLIENT_SECRET must be set or provide $token_env"
    exit 1
  fi
  local resp
  resp=$(curl -sS -X POST \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=${AZ_CLIENT_ID}&client_secret=${AZ_CLIENT_SECRET}&scope=${resource_scope}" \
    "https://login.microsoftonline.com/${AZ_TENANT_ID}/oauth2/v2.0/token")
  echo "$resp" | jq -r '.access_token'
}

ARM_TOKEN=${AZ_ARM_TOKEN:-""}
if [[ -z "$ARM_TOKEN" ]]; then
  log "Acquiring ARM token"
  ARM_TOKEN=$(get_oauth_token "https://management.azure.com/.default" "AZ_ARM_TOKEN")
fi

STG_TOKEN=${AZ_STORAGE_TOKEN:-""}
if [[ -z "$STG_TOKEN" ]]; then
  log "Acquiring Storage token"
  STG_TOKEN=$(get_oauth_token "https://storage.azure.com/.default" "AZ_STORAGE_TOKEN")
fi

auth_get() {
  local url="$1"
  curl -sS -H "Authorization: Bearer ${ARM_TOKEN}" -H "Content-Type: application/json" "$url"
}

auth_put() {
  local url="$1"; shift
  local body="$1"; shift || true
  curl -sS -X PUT -H "Authorization: Bearer ${ARM_TOKEN}" -H "Content-Type: application/json" -d "$body" "$url"
}

auth_post() {
  local url="$1"; shift
  local body="$1"; shift || true
  curl -sS -X POST -H "Authorization: Bearer ${ARM_TOKEN}" -H "Content-Type: application/json" -d "$body" "$url"
}

blob_request() {
  local method="$1"; shift
  local url="$1"; shift
  curl -sS -X "$method" \
    -H "Authorization: Bearer ${STG_TOKEN}" \
    -H "x-ms-version: 2023-11-03" \
    -H "x-ms-date: $(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S GMT")" \
    "$@" \
    "$url"
}

if [[ -z "$SUBSCRIPTION" ]]; then
  err "--subscription is required when using REST"
  exit 1
fi

# Ensure destination container exists (idempotent, using AAD auth)
CONTAINER_URL="https://${SA_NAME}.blob.core.windows.net/${SA_CONTAINER}?restype=container"
blob_request PUT "$CONTAINER_URL" >/dev/null || true

export_disk() {
  local vm_name="$1"
  local disk_id="$2"
  local disk_name
  disk_name=$(basename "$disk_id")

  local disk_url="${ARM_BASE}${disk_id}?api-version=${ARM_API_VERSION_DISK}"
  local disk_json
  disk_json=$(auth_get "$disk_url")
  local location
  location=$(echo "$disk_json" | jq -r '.location')
  if [[ -z "$location" || "$location" == "null" ]]; then
    err "Unable to determine location for disk $disk_name"
    return 1
  fi

  local snap_name="${vm_name}-snap-$(timestamp)-${disk_name}"
  local snap_url="${ARM_BASE}/subscriptions/${SUBSCRIPTION}/resourceGroups/${SNAPSHOT_RG}/providers/Microsoft.Compute/snapshots/${snap_name}?api-version=${ARM_API_VERSION_SNAPSHOT}"
  local body
  body=$(jq -n --arg loc "$location" --arg src "$disk_id" --arg tags "$TAGS" '{
    location: $loc,
    sku: { name: "Standard_LRS" },
    tags: (if $tags=="" then null else ([$tags|split(" ")[]|split("=")]|from_entries) end),
    properties: { incremental: false, creationData: { createOption: "Copy", sourceResourceId: $src } }
  }')
  log "[$vm_name][$disk_name] Creating snapshot $snap_name"
  auth_put "$snap_url" "$body" >/dev/null
  while true; do
    sleep 5
    local s_json state
    s_json=$(auth_get "$snap_url")
    state=$(echo "$s_json" | jq -r '.properties.provisioningState // empty')
    [[ "$state" == "Succeeded" ]] && break
    log "[$vm_name][$disk_name] Snapshot state: $state"
  done

  local ga_url="${ARM_BASE}/subscriptions/${SUBSCRIPTION}/resourceGroups/${SNAPSHOT_RG}/providers/Microsoft.Compute/snapshots/${snap_name}/grantAccess?api-version=${ARM_API_VERSION_SNAPSHOT}"
  local ga_body
  ga_body=$(jq -n --argjson d $((SAS_HOURS*3600)) '{access:"Read", durationInSeconds:$d}')
  local ga_resp sas_url
  ga_resp=$(auth_post "$ga_url" "$ga_body")
  sas_url=$(echo "$ga_resp" | jq -r '.accessSas')
  if [[ -z "$sas_url" || "$sas_url" == "null" ]]; then
    err "[$vm_name][$disk_name] Failed to grant SAS"
    return 1
  fi

  local blob_name="${vm_name}_${disk_name}_$(timestamp).vhd"
  local dest_blob_url="https://${SA_NAME}.blob.core.windows.net/${SA_CONTAINER}/${blob_name}"
  log "[$vm_name][$disk_name] Starting copy to ${blob_name}"
  blob_request PUT "$dest_blob_url" \
    -H "x-ms-blob-type: PageBlob" \
    -H "x-ms-copy-source: ${sas_url}" \
    -H "Content-Length: 0" >/dev/null

  while true; do
    sleep 10
    local headers status prog
    headers=$(blob_request HEAD "$dest_blob_url" -D - -o /dev/null)
    status=$(echo "$headers" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-ms-copy-status"{print $2}')
    prog=$(echo "$headers" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-ms-copy-progress"{print $2}')
    log "[$vm_name][$disk_name] Copy: ${status:-unknown} (${prog:-N/A})"
    case "${status:-pending}" in
      success) break ;;
      failed) err "[$vm_name][$disk_name] Copy failed"; break ;;
      *) ;;
    esac
  done

  local ra_url="${ARM_BASE}/subscriptions/${SUBSCRIPTION}/resourceGroups/${SNAPSHOT_RG}/providers/Microsoft.Compute/snapshots/${snap_name}/revokeAccess?api-version=${ARM_API_VERSION_SNAPSHOT}"
  auth_post "$ra_url" '{}' >/dev/null || true

  if [[ "$DELETE_SNAPSHOTS" == "true" ]]; then
    local del_url="${ARM_BASE}/subscriptions/${SUBSCRIPTION}/resourceGroups/${SNAPSHOT_RG}/providers/Microsoft.Compute/snapshots/${snap_name}?api-version=${ARM_API_VERSION_SNAPSHOT}"
    curl -sS -X DELETE -H "Authorization: Bearer ${ARM_TOKEN}" "$del_url" >/dev/null || true
  fi
}

export_vm_disks() {
  local vm_rg="$1"
  local vm_name="$2"
  log "Fetching VM: $vm_rg/$vm_name"
  local vm_url="${ARM_BASE}/subscriptions/${SUBSCRIPTION}/resourceGroups/${vm_rg}/providers/Microsoft.Compute/virtualMachines/${vm_name}?api-version=${ARM_API_VERSION_VM}"
  local vm_json
  vm_json=$(auth_get "$vm_url")
  if [[ "$(echo "$vm_json" | jq -r '.name // empty')" != "$vm_name" ]]; then
    err "VM $vm_name not found or unauthorized"
    return 1
  fi
  # Upload VM configuration JSON into destination container
  local config_blob_name="${vm_name}_config_$(timestamp).json"
  local config_blob_url="https://${SA_NAME}.blob.core.windows.net/${SA_CONTAINER}/${config_blob_name}"
  local config_payload
  config_payload=$(echo "$vm_json" | jq '.')
  local content_length
  content_length=$(printf "%s" "$config_payload" | wc -c | tr -d ' ')
  log "[$vm_name] Uploading VM configuration: ${config_blob_name}"
  blob_request PUT "$config_blob_url" \
    -H "x-ms-blob-type: BlockBlob" \
    -H "Content-Type: application/json" \
    -H "Content-Length: ${content_length}" \
    --data-binary "$config_payload" >/dev/null
  local os_id data_ids
  os_id=$(echo "$vm_json" | jq -r '.properties.storageProfile.osDisk.managedDisk.id')
  mapfile -t disk_ids < <(echo "$vm_json" | jq -r '.properties.storageProfile.dataDisks[].managedDisk.id // empty') || true
  local all_ids=("$os_id")
  for id in "${disk_ids[@]:-}"; do [[ -n "$id" ]] && all_ids+=("$id"); done
  log "[$vm_name] Disks to export: ${#all_ids[@]}"
  for id in "${all_ids[@]}"; do
    export_disk "$vm_name" "$id" &
  done
  wait
  log "[$vm_name] Completed disk exports"
}

if [[ -n "$VM_NAME" ]]; then
  if [[ -z "$VM_RG" ]]; then
    err "--resource-group is required when --vm-name is provided"
    exit 1
  fi
  export_vm_disks "$VM_RG" "$VM_NAME"
else
  if [[ -n "$VM_RG" ]]; then
    log "Discovering VMs in resource group: $VM_RG"
    list_url="${ARM_BASE}/subscriptions/${SUBSCRIPTION}/resourceGroups/${VM_RG}/providers/Microsoft.Compute/virtualMachines?api-version=${ARM_API_VERSION_VM}"
    vm_list=$(auth_get "$list_url")
    mapfile -t vms < <(echo "$vm_list" | jq -r '.value[].name')
    if [[ ${#vms[@]} -eq 0 ]]; then
      err "No VMs found in resource group $VM_RG"
      exit 1
    fi
    log "Found ${#vms[@]} VMs in $VM_RG. Starting parallel exports."
    for v in "${vms[@]}"; do
      export_vm_disks "$VM_RG" "$v" &
    done
    wait
  else
    log "Discovering all VMs in subscription"
    list_url="${ARM_BASE}/subscriptions/${SUBSCRIPTION}/providers/Microsoft.Compute/virtualMachines?api-version=${ARM_API_VERSION_VM}"
    vm_list=$(auth_get "$list_url")
    mapfile -t vms_rg < <(echo "$vm_list" | jq -r '.value[].id | capture("(?<rg>resourceGroups/(?<name>[^/]+))") | .name')
    mapfile -t vms_name < <(echo "$vm_list" | jq -r '.value[].name')
    if [[ ${#vms_name[@]} -eq 0 ]]; then
      err "No VMs found in subscription"
      exit 1
    fi
    log "Found ${#vms_name[@]} VMs in subscription. Starting parallel exports."
    for i in "${!vms_name[@]}"; do
      # Extract resource group name from id reliably
      rg=$(echo "$vm_list" | jq -r --arg idx "$i" '.value[($idx|tonumber)].id | capture("/resourceGroups/(?<rg>[^/]+)/") | .rg')
      export_vm_disks "$rg" "${vms_name[$i]}" &
    done
    wait
  fi
  log "All VM exports completed"
fi

log "Export completed. Destination: account=$SA_NAME container=$SA_CONTAINER"

