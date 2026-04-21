# Azure Resiliency Scanner

A PowerShell-based tool that scans your entire Azure estate and evaluates the resiliency configuration of 70+ resource types. Results are exported to CSV files and visualized through a Power BI dashboard template.

---

## Why This Exists

There's no single pane of glass in Azure that answers: *"How resilient is my entire estate, right now?"*

As Azure footprints grow, tracking resiliency configurations becomes genuinely difficult. Best practices evolve, Azure capabilities change, and the focus is usually on new deployments — leaving older resources behind. A database deployed before zone-redundant support was available in your region now has a viable upgrade path, but nobody noticed.

On top of that, each Azure service uses different terminology:

| Service Category | Terminology Used |
|---|---|
| Compute | Zonal / Regional (NonZonal) |
| Storage | LRS / ZRS / GRS / GZRS |
| PaaS Databases | NonZonal / Zonal / ZoneRedundant / SameZoneHA |
| SQL / MI | Failover Groups |
| MySQL / PostgreSQL / Cosmos | GeoReplicas |
| Networking, KeyVault, etc. | Redundant by Default |

This scanner normalizes all of that into a consistent model and gives you a complete picture.

---

## What It Covers

### Zonal Resiliency — 70+ Resource Types including:
- Virtual Machines & VMSS
- Managed Disks
- Azure Kubernetes Service (AKS)
- Load Balancers, Application Gateways, Firewalls
- Public IPs, NAT Gateways, VNet Gateways, Bastion
- Storage Accounts
- SQL Database, SQL Managed Instances
- MySQL & PostgreSQL Flexible Servers
- Cosmos DB, Mongo Clusters
- Redis Cache, Redis Enterprise
- Service Bus, Event Hub, Event Grid
- API Management
- App Service Plans
- Key Vault, Managed HSM
- Recovery Services Vaults
- Log Analytics Workspaces
- Container Registry (ACR)
- Cognitive Services / Azure OpenAI
- SignalR, Web PubSub
- And more via catch-all zone detection

### Geo Resiliency evaluated for:
- Azure Virtual Machines (ASR configuration)
- Azure Storage Accounts (GRS/GZRS)
- Azure SQL Database & SQL Managed Instances (Failover Groups)
- Azure Database for MySQL & PostgreSQL (Geo Replicas)
- Cosmos DB (Multi-region writes)
- API Management (Additional Locations)
- Service Bus & Event Hub (Geo Data Replication)
- Key Vault (Paired Region)

### Additional Enrichments:
- **Backup status** — pulls data from Recovery Services vaults, enriches each VM/storage record with backup health and last backup time
- **ASR configuration** — identifies which VMs are protected with Azure Site Recovery and their replication target
- **Physical Zone mapping** — maps logical zone numbers to physical zones per subscription, enabling single-zone exposure and impact analysis
- **Public IP correlation** — links public IPs to their attached resources (VMs, Load Balancers, App Gateways)
- **SQL Failover Groups** — detected and correlated to server and database records

> **Note on Zone Redundant overrides:** Azure Application Gateways, Firewalls, Container Registries, and Public IPs running in regions with Availability Zones are reported as Zone Redundant even if ARM metadata hasn't been updated in the portal. If you're unsure about a specific resource, raise a support case — Microsoft support can verify the physical deployment.

---

## Prerequisites

### Required PowerShell Modules
```powershell
Install-Module Az.ResourceGraph
Install-Module Az.Accounts
Install-Module Az.Storage
```

### Required Permissions
- **Reader** access on all subscriptions you want to scan
- Reader on Recovery Services vaults (for backup and ASR data)
- The script supports both **interactive login** and **Managed Identity** (for Automation Account execution)

---

## Files

| File | Description |
|---|---|
| `AzResiliencyScanner.ps1` | Main scanner script — orchestrates data collection, enrichment, and export |
| `ResiliencyRules.ps1` | Rules engine definitions — one rule block per resource type |
| `AzureResiliencyDashboard.pbit` | Power BI template file |

---

## Running the Scanner

### Option 1 — Azure Cloud Shell (Recommended, no local setup needed)

Upload both `AzResiliencyScanner.ps1` and `ResiliencyRules.ps1` to Cloud Shell and run:

```powershell
.\AzResiliencyScanner.ps1 -localexport $true -customerTags @()
```

### Option 2 — Local PowerShell

Install the required modules (see Prerequisites) and run from the script directory.

---

## Usage Examples

**Scan all accessible subscriptions:**
```powershell
.\AzResiliencyScanner.ps1 -localexport $true -customerTags @()
```

**Scan specific subscriptions (by ID or name):**
```powershell
.\AzResiliencyScanner.ps1 `
    -localexport $true `
    -subscriptionList @("subid1", "subid2", "subid3")
```

**Scan an entire tenant:**
```powershell
.\AzResiliencyScanner.ps1 -tenantscope "your-tenant-id"
```

**Include resource tags as filterable columns in the report:**
```powershell
.\AzResiliencyScanner.ps1 `
    -localexport $true `
    -customerTags @("Environment", "CostCenter", "Owner", "Project")
```

**Export results to Azure Blob Storage:**
```powershell
.\AzResiliencyScanner.ps1 `
    -localexport $false `
    -exportstoragesubid "your-storage-subscription-id" `
    -exportstorageAccount "your-storage-account-name"
```

---

## Parameters

| Parameter | Type | Required | Description |
|---|---|---|---|
| `localexport` | bool | No | Export to local folder (default: `$true`) |
| `subscriptionList` | string[] | No | List of subscription IDs or names to scan. Scans all if omitted |
| `tenantscope` | string | No | Tenant ID to scope subscription discovery |
| `customerTags` | array | No | Tag names to include as columns in the output |
| `exportstoragesubid` | string | Conditional | Required when `localexport` is `$false` |
| `exportstorageAccount` | string | Conditional | Required when `localexport` is `$false` |

---

## Output Files

After the scan completes, all report files are zipped into `ResiliencyReport.zip`.

| File | Description |
|---|---|
| `MasterReport.csv` | Main resiliency inventory — one row per resource |
| `ResiliencyInfo.csv` | Zonal and geo resiliency detail view |
| `asr_backup.csv` | Backup and ASR records from Recovery Services vaults |
| `lbReport.csv` | Load balancer frontend IP configuration detail |
| `pipReport.csv` | Public IP addresses with zone and attachment info |
| `zonemapping.csv` | Logical-to-physical availability zone mapping per subscription |

---

## Dashboard Setup

1. Run the scanner and download `ResiliencyReport.zip`
2. Extract to a local folder
3. Open `AzureResiliencyDashboard.pbit` in Power BI Desktop
4. When prompted, enter the path to the extracted report folder
5. Power BI will load all CSV files and populate the dashboard

### Dashboard Views

- **Overview** — overall resiliency score per subscription and resource type
- **Zonal Resiliency** — breakdown by resiliency configuration (ZoneRedundant, Zonal, LocallyRedundant, NonZonal)
- **Geo Resiliency** — geo-redundancy coverage by subscription and resource type
- **Physical Zone Distribution** — zone spread for zonal resources, useful for identifying concentration risk
- **Backup Protected Instances** — backup health, last backup time, and cross-region restore status
- **ASR View** — ASR-protected VMs and replication configuration
- **Public IP View** — public IP inventory with zone and resource attachment

> **Scoring note:** The resiliency score is calculated as `(Resources with Zonal or Geo Resiliency) / All Applicable Resources`. Disks are excluded from VM-level scoring since disk resiliency is evaluated as part of the VM record. This is a guidance metric — your actual RTO/RPO requirements will determine what "good" looks like for your workloads.

---

## Extending the Rules

Each resource type is defined as a rule block in `ResiliencyRules.ps1`. Adding support for a new resource type requires adding a single entry:

```powershell
@{
    ResourceSubType  = 'Microsoft.Example/resourceType'
    ExtraProperties  = @('propertyOne', 'propertyTwo')
    ResiliencyLogic  = {
        param($item)
        $config = if ($item.properties.zoneRedundant -eq $true) { 'ZoneRedundant' } else { 'NonZonal' }
        @{
            ResiliencyConfig = $config
            ZonalResiliency  = $config
        }
    }
}
```

For resources with a static resiliency value (e.g., always redundant by default):

```powershell
@{
    ResourceSubType   = 'Microsoft.Network/virtualNetworks'
    DefaultResiliency = 'RedundantbyDefault'
}
```

---

## Performance

- Per-subscription scan time: **10–40 seconds average**
- Only **Reader** permissions required
- Supports pagination for large subscriptions (1000+ resources per page via Azure Resource Graph skip tokens)
- Memory-optimized with batch processing for subscriptions with large resource counts

---



## License

MIT License — see [LICENSE](LICENSE) for details.