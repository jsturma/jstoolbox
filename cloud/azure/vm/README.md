## Azure VM Export (REST and CLI)

These scripts snapshot all managed disks (OS + data) attached to one or more Azure VMs and export them as VHDs to a Storage Account container. They also upload each VM's full ARM configuration JSON and per-VM export logs. Two variants are provided:

- `azure_export_vm_api.sh`: REST-only (curl + OAuth), no Azure CLI required.
- `azure_export_vm_cli.sh`: Azure CLI–only, no direct REST calls.

### Features
- REST-only: uses OAuth2 and Azure ARM/Blob REST APIs
- Snapshots each managed disk and performs server-side copy to Blob Storage
- Uploads VM configuration JSON to the same container
- Optional on-premise replication: download all exports to local path
- Parallelism:
  - Per-VM: multiple VMs export concurrently
  - Per-disk: disks on a VM export concurrently
- Scope discovery:
  - Single VM (requires resource group)
  - All VMs in a resource group
  - All VMs in a subscription

### Requirements (REST script)
- `curl` and `jq`
- Azure AD App Registration or Managed Identity equivalent with:
  - Compute (ARM): read VM, read disks; create/delete snapshots; grant/revoke snapshot access
  - Storage (data plane): Blob Data Contributor (or higher) on the destination Storage Account

### Authentication (REST script)
Set either tokens or client credentials as environment variables:

- Tokens (optional, if you already obtained them):
  - `AZ_ARM_TOKEN` (scope `https://management.azure.com/.default`)
  - `AZ_STORAGE_TOKEN` (scope `https://storage.azure.com/.default`)

- Client credentials (used to obtain tokens when `AZ_*_TOKEN` not provided):
  - `AZ_TENANT_ID`
  - `AZ_CLIENT_ID`
  - `AZ_CLIENT_SECRET`

### Usage (REST script)
```
azure_export_vm_api.sh \
  --subscription <sub_id_or_name> \
  --storage-account <account_name> \
  --storage-container <container_name> \
  [--resource-group <vm_rg>] \
  [--vm-name <vm_name>] \
  [--vm-tag-filter "k=v k2=v2"] \
  [--snapshot-resource-group <rg_for_snapshots>] \
  [--sas-hours <hours>] \
  [--delete-snapshots true|false] \
  [--tags "k1=v1 k2=v2"] \
  [--replicate-to <local_path>]
```

### Parameters (both scripts unless noted)
- **--subscription**: Azure subscription ID or name. Required. Used for ARM requests and VM discovery.
- **--storage-account**: Destination Storage Account name for exports. Required.
- **--storage-container**: Destination container name within the Storage Account. Required. Created if missing.
- **--resource-group**: Resource group containing the VM(s). Optional when exporting all subscription VMs. Required when `--vm-name` is provided.
- **--vm-name**: Name of a single VM to export. Optional. If omitted, discovery is based on `--resource-group` presence (RG-wide or subscription-wide).
- **--vm-tag-filter**: Space-delimited `key=value` pairs. Only VMs with all matching tags are exported. Applies to single, RG-wide, and subscription-wide discovery.
- **--snapshot-resource-group**: Resource group where snapshots will be created. Optional. Defaults to the VM's resource group.
- **--sas-hours**: Lifetime, in hours, of the temporary SAS granted on snapshots for copy. Optional. Default: 6.
- **--delete-snapshots**: Whether to delete snapshots after the copy completes. Optional. Values: `true` or `false`. Default: `false`.
- **--tags**: Space-delimited list of `key=value` tags applied to created snapshots. Optional. Example: `--tags "project=backup env=prod"`.
- **--replicate-to**: Local directory path for on-premise replication. If provided, after all exports complete, downloads all blobs from the container to the specified local path, maintaining the same `vm/timestamp/` directory structure. Optional.

### Environment variables (REST script only)
- **AZ_ARM_TOKEN**: Optional bearer token for ARM (`https://management.azure.com/.default`). If not set, the script uses client credentials.
- **AZ_STORAGE_TOKEN**: Optional bearer token for Storage (`https://storage.azure.com/.default`). If not set, the script uses client credentials.
- **AZ_TENANT_ID**: Tenant ID for OAuth2 client credentials. Required if `AZ_ARM_TOKEN`/`AZ_STORAGE_TOKEN` are not provided.
- **AZ_CLIENT_ID**: Client ID for OAuth2 client credentials. Required if tokens are not provided.
- **AZ_CLIENT_SECRET**: Client secret for OAuth2 client credentials. Required if tokens are not provided.

### Behavior by scope (both scripts)
- Single VM: provide `--vm-name` and `--resource-group`.
- All VMs in a resource group: provide `--resource-group`, omit `--vm-name`.
- All VMs in subscription: omit both `--resource-group` and `--vm-name`.

### Examples (REST script)
- Single VM
```bash
AZ_TENANT_ID=... AZ_CLIENT_ID=... AZ_CLIENT_SECRET=... \
./azure_export_vm_api.sh \
  --subscription "SUB_ID" \
  --resource-group "VM_RG" \
  --vm-name "VM_NAME" \
  --storage-account "STG_ACCOUNT" \
  --storage-container "vhds-backups" \
  --sas-hours 8 \
  --delete-snapshots true \
  --tags "project=backup env=prod"
```

- All VMs in a resource group
```bash
AZ_TENANT_ID=... AZ_CLIENT_ID=... AZ_CLIENT_SECRET=... \
./azure_export_vm_api.sh \
  --subscription "SUB_ID" \
  --resource-group "VM_RG" \
  --storage-account "STG_ACCOUNT" \
  --storage-container "vhds-backups"
```

- All VMs in a subscription
```bash
AZ_TENANT_ID=... AZ_CLIENT_ID=... AZ_CLIENT_SECRET=... \
./azure_export_vm_api.sh \
  --subscription "SUB_ID" \
  --storage-account "STG_ACCOUNT" \
  --storage-container "vhds-backups"
```

- Export with on-premise replication
```bash
AZ_TENANT_ID=... AZ_CLIENT_ID=... AZ_CLIENT_SECRET=... \
./azure_export_vm_api.sh \
  --subscription "SUB_ID" \
  --storage-account "STG_ACCOUNT" \
  --storage-container "vhds-backups" \
  --replicate-to "/backups/azure-vms"
```

### Outputs (both scripts)
- Artifacts are stored under a per-VM, timestamped virtual subdirectory: `/<vm>/<timestamp>/...`
- Per VM directory contents:
  - `config.json` (full ARM VM model)
  - One VHD blob per disk: `<disk>.vhd`
  - `export.log` (logs from the export process for that VM)

### Notes (both scripts)
- Snapshots are created in `--snapshot-resource-group` (defaults to VM RG). Use `--delete-snapshots true` to clean them up after copy.
- Copy uses `x-ms-copy-source` from the snapshot SAS to the destination page blob.
- Ensure the destination container exists or let the script create it.
- On-premise replication (`--replicate-to`) downloads all exported blobs after export completes, maintaining the same directory structure. Downloads run in parallel for efficiency.

### Limitations
- Classic (ASM) VMs are not supported by ARM. If you still have classic VMs, adapt a legacy flow that enumerates their page blobs and copies them directly.
---

## Azure VM Export (CLI-only)

`azure_export_vm_cli.sh` performs the same operations using only the Azure CLI.

### Requirements (CLI script)
- Azure CLI logged in (`az login`), with:
  - Compute: read VM/disks; create/delete snapshots; grant/revoke snapshot access
  - Storage: Blob Data Contributor (or higher) on destination account
- Optional: `jq` (pretty prints VM config before upload)

### Usage (CLI script)
```
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
  [--tags "k1=v1 k2=v2"] \
  [--replicate-to <local_path>]
```

### Examples (CLI script)
- Single VM
```bash
./azure_export_vm_cli.sh \
  --subscription "SUB_ID" \
  --resource-group "VM_RG" \
  --vm-name "VM_NAME" \
  --storage-account "STG_ACCOUNT" \
  --storage-container "vhds-backups" \
  --delete-snapshots true
```

- All VMs in a resource group with tag filter
```bash
./azure_export_vm_cli.sh \
  --subscription "SUB_ID" \
  --resource-group "VM_RG" \
  --storage-account "STG_ACCOUNT" \
  --storage-container "vhds-backups" \
  --vm-tag-filter "env=prod project=appX"
```

- All VMs in a subscription
```bash
./azure_export_vm_cli.sh \
  --subscription "SUB_ID" \
  --storage-account "STG_ACCOUNT" \
  --storage-container "vhds-backups"
```

- Export with on-premise replication
```bash
./azure_export_vm_cli.sh \
  --subscription "SUB_ID" \
  --storage-account "STG_ACCOUNT" \
  --storage-container "vhds-backups" \
  --replicate-to "/backups/azure-vms"
```