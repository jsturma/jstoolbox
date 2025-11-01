#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Export Azure VM disks and config to a Storage Account container using ONLY Azure CLI.

Features:
- Discover VMs by RG or entire subscription; optional tag filtering
- Per-VM timestamped subdirectory: <vm>/<timestamp>/
- Exports all managed disks (OS + data) using snapshots and server-side copy
- Uploads VM config (config.json) and per-VM export log (export.log)
- Parallel: VMs in parallel, disks per VM in parallel

Prereqs:
- az CLI logged in (az login) with rights: Compute (VM read, snapshots create/delete, grant/revoke) and Storage Blob Data Contributor on destination account.
- Optional: jq (only used to pretty-print VM config; not required for core export)

Usage:
  azure_export_vm_cli.sh \
    --subscription <sub_id_or_name> \
    --storage-account <account_name> \
    --storage-container <container_name> \
    [--resource-group <vm_rg>] \
    [--vm-name <vm_name>] \
    [--vm-tag-filter "k=v k2=v2"] \
    [--snapshot-resource-group <rg_for_snapshots>] \
    [--sas-hours <hours>] \
    [--delete-snapshots true|false] \
    [--tags "k1=v1 k2=v2"]
EOF
}

log() {
  local line
  line="[$(date +'%Y-%m-%dT%H:%M:%S%z')] $*"
  echo "$line"
  if [[ -n "${VM_LOG_FILE:-}" ]]; then
    printf "%s\n" "$line" >>"$VM_LOG_FILE" || true
  fi
}

err() { echo "ERROR: $*" >&2; }

timestamp() { date +%Y%m%d%H%M%S; }

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
VM_TAG_FILTER=""

if [[ $# -eq 0 ]]; then usage; exit 1; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription) SUBSCRIPTION="$2"; shift 2 ;;
    --resource-group) VM_RG="$2"; shift 2 ;;
    --vm-name) VM_NAME="$2"; shift 2 ;;
    --snapshot-resource-group) SNAPSHOT_RG="$2"; shift 2 ;;
    --storage-account) SA_NAME="$2"; shift 2 ;;
    --storage-container) SA_CONTAINER="$2"; shift 2 ;;
    --sas-hours) SAS_HOURS="$2"; shift 2 ;;
    --delete-snapshots) DELETE_SNAPSHOTS="$2"; shift 2 ;;
    --vm-tag-filter) VM_TAG_FILTER="$2"; shift 2 ;;
    --tags) TAGS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "$SUBSCRIPTION" || -z "$SA_NAME" || -z "$SA_CONTAINER" ]]; then
  err "Missing required arguments"; usage; exit 1
fi

if ! command -v az >/dev/null 2>&1; then err "az CLI is required"; exit 1; fi

log "Setting subscription: $SUBSCRIPTION"
az account set --subscription "$SUBSCRIPTION" >/dev/null

if [[ -z "$SNAPSHOT_RG" ]]; then SNAPSHOT_RG="$VM_RG"; fi

# Ensure destination container exists (RBAC login)
az storage container create \
  --account-name "$SA_NAME" \
  --name "$SA_CONTAINER" \
  --auth-mode login \
  --public-access off \
  --fail-on-exist false >/dev/null || true

# Build JMESPath filter from VM_TAG_FILTER (key=value AND chain)
build_tag_jmes() {
  local filter_str="$1"
  if [[ -z "$filter_str" ]]; then echo ""; return 0; fi
  local expr="[?" first=1
  for pair in $filter_str; do
    local k="${pair%%=*}" v="${pair#*=}"
    if [[ $first -eq 0 ]]; then expr+=" && "; fi
    expr+="tags.'$k'=='$v'"
    first=0
  done
  expr+=']'
  echo "$expr"
}

TAG_JMES=$(build_tag_jmes "$VM_TAG_FILTER")

upload_blob_text() {
  local blob_path="$1"; shift
  local content_type="$1"; shift
  local src_file="$1"; shift
  az storage blob upload \
    --account-name "$SA_NAME" \
    --container-name "$SA_CONTAINER" \
    --name "$blob_path" \
    --file "$src_file" \
    --content-type "$content_type" \
    --overwrite true \
    --auth-mode login \
    >/dev/null
}

copy_from_sas_to_blob() {
  local source_sas="$1"; shift
  local dest_blob="$1"; shift
  az storage blob copy start \
    --account-name "$SA_NAME" \
    --destination-container "$SA_CONTAINER" \
    --destination-blob "$dest_blob" \
    --source-uri "$source_sas" \
    --no-progress \
    --auth-mode login >/dev/null
}

poll_copy() {
  local blob="$1"; shift
  while true; do
    sleep 10
    local status prog
    status=$(az storage blob show --account-name "$SA_NAME" --container-name "$SA_CONTAINER" --name "$blob" --query 'properties.copy.status' -o tsv --auth-mode login || echo pending)
    prog=$(az storage blob show --account-name "$SA_NAME" --container-name "$SA_CONTAINER" --name "$blob" --query 'properties.copy.progress' -o tsv --auth-mode login || echo "0/0")
    log "Copy $blob: $status ($prog)"
    case "$status" in
      success) break ;;
      failed) err "Copy failed: $blob"; break ;;
      *) ;;
    esac
  done
}

export_disk() {
  local vm_name="$1"; local disk_id="$2"; local vm_prefix="$3"
  local disk_name; disk_name=$(basename "$disk_id")

  # Snapshot
  local snap_name="${vm_name}-snap-$(timestamp)-${disk_name}"
  log "[$vm_name][$disk_name] Creating snapshot $snap_name"
  az snapshot create -g "$SNAPSHOT_RG" -n "$snap_name" --source "$disk_id" --sku Standard_LRS ${TAGS:+--tags $TAGS} >/dev/null

  # Grant SAS
  local sas
  sas=$(az snapshot grant-access -g "$SNAPSHOT_RG" -n "$snap_name" --duration-in-seconds $((SAS_HOURS*3600)) --access-level Read --query accessSas -o tsv)
  if [[ -z "$sas" ]]; then err "Failed to grant SAS for $snap_name"; return 1; fi

  # Start copy
  local dest_blob="${vm_prefix}/${disk_name}.vhd"
  log "[$vm_name][$disk_name] Starting copy to $dest_blob"
  copy_from_sas_to_blob "$sas" "$dest_blob"
  poll_copy "$dest_blob"

  # Cleanup SAS and optionally snapshot
  az snapshot revoke-access -g "$SNAPSHOT_RG" -n "$snap_name" >/dev/null || true
  if [[ "$DELETE_SNAPSHOTS" == "true" ]]; then
    az snapshot delete -g "$SNAPSHOT_RG" -n "$snap_name" >/dev/null || true
  fi
}

export_vm() {
  local vm_rg="$1"; local vm_name="$2"
  VM_LOG_FILE=${VM_LOG_FILE:-$(mktemp)}
  local vm_ts vm_prefix
  vm_ts=$(timestamp); vm_prefix="${vm_name}/${vm_ts}"

  log "Fetching VM: $vm_rg/$vm_name"
  local vm_json
  vm_json=$(az vm show -g "$vm_rg" -n "$vm_name" -o json)

  # Upload config.json
  local tmp_cfg; tmp_cfg=$(mktemp)
  if command -v jq >/dev/null 2>&1; then echo "$vm_json" | jq '.' >"$tmp_cfg"; else echo "$vm_json" >"$tmp_cfg"; fi
  upload_blob_text "${vm_prefix}/config.json" "application/json" "$tmp_cfg"
  rm -f "$tmp_cfg" || true

  # Disks
  local os_id; os_id=$(echo "$vm_json" | sed -n 's/.*"osDisk":{.*"managedDisk":{.*"id":"\([^"]*\)".*/\1/p') || true
  # Fallback to query for reliability
  if [[ -z "$os_id" ]]; then os_id=$(az vm show -g "$vm_rg" -n "$vm_name" --query 'storageProfile.osDisk.managedDisk.id' -o tsv); fi
  mapfile -t data_ids < <(az vm show -g "$vm_rg" -n "$vm_name" --query 'storageProfile.dataDisks[].managedDisk.id' -o tsv || true)
  local all_ids=("$os_id"); for id in "${data_ids[@]:-}"; do [[ -n "$id" ]] && all_ids+=("$id"); done
  log "[$vm_name] Disks to export: ${#all_ids[@]}"
  for id in "${all_ids[@]}"; do export_disk "$vm_name" "$id" "$vm_prefix" & done
  wait
  log "[$vm_name] Completed disk exports"

  # Upload export.log
  if [[ -f "$VM_LOG_FILE" ]]; then
    upload_blob_text "${vm_prefix}/export.log" "text/plain" "$VM_LOG_FILE"
    rm -f "$VM_LOG_FILE" || true
  fi
}

# Discovery and execution
if [[ -n "$VM_NAME" ]]; then
  if [[ -z "$VM_RG" ]]; then err "--resource-group is required when --vm-name is provided"; exit 1; fi
  VM_LOG_FILE=$(mktemp); export VM_LOG_FILE; export_vm "$VM_RG" "$VM_NAME"
else
  if [[ -n "$VM_RG" ]]; then
    log "Discovering VMs in resource group: $VM_RG"
    if [[ -n "$TAG_JMES" ]]; then
      mapfile -t vms < <(az vm list -g "$VM_RG" --query "${TAG_JMES}.name" -o tsv)
    else
      mapfile -t vms < <(az vm list -g "$VM_RG" --query "[].name" -o tsv)
    fi
    if [[ ${#vms[@]} -eq 0 ]]; then err "No VMs found in RG $VM_RG"; exit 1; fi
    log "Found ${#vms[@]} VMs in $VM_RG. Starting parallel exports."
    for v in "${vms[@]}"; do ( VM_LOG_FILE=$(mktemp); export VM_LOG_FILE; export_vm "$VM_RG" "$v" ) & done
    wait
  else
    log "Discovering all VMs in subscription"
    if [[ -n "$TAG_JMES" ]]; then
      mapfile -t vms_rg < <(az vm list --query "${TAG_JMES}.resourceGroup" -o tsv)
      mapfile -t vms_name < <(az vm list --query "${TAG_JMES}.name" -o tsv)
    else
      mapfile -t vms_rg < <(az vm list --query "[].resourceGroup" -o tsv)
      mapfile -t vms_name < <(az vm list --query "[].name" -o tsv)
    fi
    if [[ ${#vms_name[@]} -eq 0 ]]; then err "No VMs found in subscription"; exit 1; fi
    log "Found ${#vms_name[@]} VMs. Starting parallel exports."
    for i in "${!vms_name[@]}"; do ( VM_LOG_FILE=$(mktemp); export VM_LOG_FILE; export_vm "${vms_rg[$i]}" "${vms_name[$i]}" ) & done
    wait
  fi
  log "All VM exports completed"
fi

log "Export completed. Destination: account=$SA_NAME container=$SA_CONTAINER"


