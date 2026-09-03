# Azure Local Managed Service - Alerting Tiers & Reference

This document maps the Azure Local Managed Service tiers (Basic, Advanced, Premium) - as defined
in the Azure Local Managed Service description - to concrete Azure Monitor alert rules, and
explains how they are deployed and kept drift-free by the pipeline in this repository.

## 1. Why the split between metric and log alerts

| | Basic | Advanced | Premium |
|---|---|---|---|
| Alert type | Metric only | Metric + Log | Metric + Log |
| Log Analytics / Insights log collection | Not required | Required (prerequisite) | Required (prerequisite, tuned) |
| Alert response | During agreed service hours | Working hours | 24/7 under SLA |

Azure Local publishes a set of **platform metrics** directly on the `Microsoft.AzureStackHCI/clusters`
resource (category `Availability`, `Errors`, `Latency`, `Saturation` in Azure Monitor). These are
available immediately, with no Log Analytics workspace or Data Collection Rule required - which is
exactly why the **Basic** tier (no log collection prerequisite) can still offer meaningful alerting.

Advanced and Premium additionally require Azure Monitor/Log Analytics + DCR/DCE configured for
Azure Local Insights (see the transition prerequisites and `azure-local-insights-part1.md`). Once
that log pipeline exists, richer signals become available from the `Heartbeat`, `Perf`, and `Event`
tables, enabling **log-based alerts** (KQL scheduled query rules) for node connectivity, cluster/
volume health events, and (Premium) proactive anomaly detection.

## 2. Alert matrix by tier

| Alert | Type | Basic | Advanced | Premium | Source |
|---|---|:---:|:---:|:---:|---|
| Storage degraded (failed/missing drives) | Metric | ✅ | ✅ | ✅ | `Microsoft.AzureStackHCI/clusters` metric `Cluster Node Storage Degraded` |
| CPU usage high | Metric | ❌ | ✅ | ✅ | metric `Hyper-V Hypervisor Logical Processor\% Total Run Time` (MS-recommended: >80%; default here: 85%) |
| Memory usage high (%) | Metric | ❌ | ✅ | ✅ | metric `ClusterNode Memory Usage` |
| Available memory low (bytes) | Metric | ❌ | ✅ | ✅ | metric `Memory\Available Bytes` - MS-recommended alert, < 1 GiB |
| Volume read latency high | Metric | ❌ | ✅ | ✅ | metric `Cluster CSVFS\Avg. sec/Read` - MS-recommended alert, > 500 ms |
| Volume write latency high | Metric | ❌ | ✅ | ✅ | metric `Cluster CSVFS\Avg. sec/Write` - MS-recommended alert, > 500 ms |
| Network inbound throughput high | Metric | ❌ | ✅ | ✅ | metric `Network Adapter\Bytes Received/sec` - MS-recommended alert, > 500 GB/s |
| Network outbound throughput high | Metric | ❌ | ✅ | ✅ | metric `Network Adapter\Bytes Sent/sec` - MS-recommended alert, > 200 GB/s |
| Storage capacity low (per volume) | Metric | ❌ | ✅ | ✅ | metric `Volume Size Available` (dimension-split by `LUN`), absolute bytes threshold |
| Node heartbeat missing (unreachable node) | Log | ❌ | ✅ | ✅ | `Heartbeat` table, KQL |
| Volume health degraded | Log | ❌ | ✅ | ✅ | `Event` table (`Microsoft-Windows-Health/Operational` + `Microsoft-Windows-SDDC-Management/Operational`), KQL |
| Elevated Error-event rate (proactive) | Log | ❌ | ❌ | ✅ | `Event` table, KQL |

This directly maps to the service description:
- **Basic**: "Baseline monitoring of cluster availability and health signals (only alerts from
  cluster health)" → storage-degraded metric alert only.
- **Advanced**: "Monitoring of core Azure Local data sources... via Log Analytics log collection",
  "Monitor capacity (CPU, memory and storage)" → adds CPU/memory/storage-capacity metric alerts +
  heartbeat/volume health log alerts.
- **Premium**: "Full enablement and tuning of Azure Local Insights..." and "24/7 alert response...
  under SLA" → adds the enhanced proactive log alert and (operationally) a second notification
  receiver representing the on-call rotation.

> **Storage capacity alerting uses an absolute-bytes threshold, not a percentage.** Azure Monitor
> metric alerts cannot compute a ratio between two metrics (e.g. `Available / Total`), so the
> `storageCapacityAlert` rule fires when the platform metric `Volume Size Available` drops below
> `storageFreeBytesThreshold` (default: 214748364800 bytes = 200 GiB) for any volume. The rule is
> **dimension-split on `LUN`**, meaning Azure evaluates and can alert per-volume rather than only
> as a cluster-wide aggregate - each volume below the threshold fires its own alert instance.
> Because "200 GiB free" means something very different on a 2 TiB volume vs a 20 TiB volume,
> **tune `storageFreeBytesThreshold` per environment** using the live `Volume Size Total` values
> for your cluster - see section 4 for the exploration command. This is a deliberate trade-off:
> the underlying Log Analytics `Perf` table on the tested cluster only carried
> Memory/Network/Processor counters (no disk/volume capacity counters), so a log-based
> percentage alert was not viable; the metric-based absolute-bytes alert was used instead because
> `Volume Size Available` / `Volume Size Total` / `Physicaldisk Capacity Size Total`/`Used` are
> confirmed, documented platform metrics available even without Log Analytics.

> **Advanced/Premium include all 6 of Microsoft's officially documented "recommended alert rules"
> for Azure Local** (see [Enable recommended alert rules for Azure Local](https://learn.microsoft.com/azure/azure-local/manage/set-up-recommended-alert-rules)):
> Percentage CPU, Available Memory Bytes, Volume Latency Read, Volume Latency Write, Network In
> Per Second, and Network Out Per Second - plus this repo's own additions (storage-degraded
> health, percentage-based memory, per-volume storage capacity). All 6 metric names/units were
> confirmed live against the tested cluster's metric definitions
> (`az monitor metrics list-definitions`). Defaults match Microsoft's documented suggested
> thresholds (CPU >80%, memory <1 GiB, volume latency >500 ms read/write, network in >500 GB/s,
> network out >200 GB/s) and are fully tunable per environment via the corresponding Bicep
> parameters/pipeline variables. Note Microsoft's 500/200 GB/s network defaults are extremely
> high for most NIC speeds - review and lower them per environment.

## 3. Deployment model

```
bicep/main.bicep                     (subscription scope, optional RG creation)
  └─ bicep/modules/alerts.bicep      (resource-group scope orchestrator, tier gating)
       ├─ modules/actionGroup.bicep  (email + webhook receivers)
       ├─ modules/metricAlerts.bicep (storage-degraded always; CPU/Memory/storage-capacity if Advanced/Premium)
       └─ modules/logAlerts.bicep    (heartbeat + volume-health if Advanced/Premium; error-rate if Premium)
```

One Action Group per cluster is reused by every alert rule for that cluster, and supports both
**email** and **webhook** receivers (e.g. Freshservice ITSM webhook + an ops distribution list).

The resource group named by the `resourceGroupName` parameter is always created/ensured as part
of `main.bicep` (idempotent - safe against an already-existing RG); there is no separate toggle.

### Deployment stacks - tracked resources, deny-delete protection

Instead of a plain `az deployment sub create`, `scripts/Deploy-AzureLocalAlerts.ps1` deploys via
[`az stack sub create`](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-stacks)
(Azure Deployment Stacks). This gives two guarantees:

- **`--deny-settings-mode denyDelete`** (default): Azure Resource Manager denies delete operations
  against any resource the stack manages (the resource group, Action Group, and every alert
  rule), so they cannot be deleted from the portal or CLI outside the pipeline - a stronger
  guarantee than "the pipeline will just redeploy over drift".
- **`--action-on-unmanage deleteResources`** (default): resources that fall out of the template
  (e.g. downgrading a cluster from Advanced to Basic removes its log alerts) are deleted
  automatically on the next deployment, so there's no orphaned-resource cleanup to do by hand.
  Resource **groups** are deliberately never auto-deleted by this setting, even if the stack
  itself is later removed - only `deleteAll` would do that, and it is intentionally not the
  default because the RG also contains the customer's live Azure Local cluster resource.

One deployment stack is created per resource group, named `stack-azurelocal-alerts-<rg-name>` by
default (override with `-DeploymentStackName`). Re-running the pipeline updates the existing
stack in place.

### Config-as-code / drift prevention

`pipeline/environments/<name>.yml` files commit, per cluster/tenant: the Azure DevOps service
connection (tenant), subscription/resource group, service tier, cluster/workspace resource IDs,
and action group receivers. `pipeline/azure-pipelines.yml` triggers on every push to `main` that
touches `bicep/**` or `pipeline/environments/**`. Because Bicep deployments are declarative, each
run re-applies exactly what's committed - reverting any manual portal changes on the next run
instead of letting configuration drift persist silently. The deny-delete deployment stack setting
above adds a second layer of protection on top of pipeline-driven redeployment.

To onboard a new cluster:
1. Copy an existing file in `pipeline/environments/` and fill in the tenant's values.
2. Add its file name to the `environmentFile` parameter's `values` list in `azure-pipelines.yml`.
3. Merge to `main` - the pipeline deploys automatically for that environment on the next manual
   run selecting it, or wire a dedicated trigger/stage per environment if you want every commit
   to redeploy every tenant unattended.

To change tier or service connection **once** without touching git, use the `serviceTierOverride` /
`serviceConnectionOverride` runtime parameters on a manual pipeline run.

## 4. Exploration commands - confirm signals before tuning thresholds

Run these against a live cluster/workspace before relying on the default thresholds in
`bicep/parameters/*.json`. A wrapper script is provided: `scripts/Get-AzureLocalAlertExploration.ps1`.

### Metrics (works for all tiers - no Log Analytics required)

```bash
# List every platform metric the cluster resource actually exposes
az monitor metrics list-definitions \
  --resource "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.AzureStackHCI/clusters/<name>" \
  --output table

# Pull current values for the metrics used in this repo's alert rules
az monitor metrics list \
  --resource "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.AzureStackHCI/clusters/<name>" \
  --metric "Cluster Node Storage Degraded,Hyper-V Hypervisor Logical Processor\% Total Run Time,ClusterNode Memory Usage,Volume Size Available,Volume Size Total" \
  --interval PT1H --output table
```

> Use `Volume Size Available` and `Volume Size Total` per-volume (dimension `LUN`) to pick a
> realistic `storageFreeBytesThreshold` for the cluster - e.g. ~10-15% of `Volume Size Total`
> rather than the generic 200 GiB default.

### Log Analytics (Advanced/Premium only)

```bash
# Which tables is the cluster actually sending data to?
az monitor log-analytics query -w <workspace-guid> --analytics-query "
union withsource=TableName *
| where TimeGenerated > ago(1d)
| summarize Count = count() by TableName
| order by Count desc"

# Perf: confirm exact ObjectName/CounterName combos before writing a storage-capacity KQL alert
az monitor log-analytics query -w <workspace-guid> --analytics-query "
Perf
| where TimeGenerated > ago(1d)
| summarize by ObjectName, CounterName
| order by ObjectName asc"

# Heartbeat: confirm node naming used for KQL scoping
az monitor log-analytics query -w <workspace-guid> --analytics-query "
Heartbeat
| summarize LastHeartbeat = max(TimeGenerated) by Computer
| order by LastHeartbeat desc"

# Event: most frequent EventID/EventLog combinations (find new candidate alert signals)
az monitor log-analytics query -w <workspace-guid> --analytics-query "
Event
| where TimeGenerated > ago(1d)
| summarize Count = count() by EventLog, EventID, EventLevelName
| order by Count desc
| take 25"

# Event: baseline Error-level event rate per 5-minute bucket (tune the Premium error-rate alert)
az monitor log-analytics query -w <workspace-guid> --analytics-query "
Event
| where TimeGenerated > ago(7d)
| where EventLevelName == 'Error'
| summarize ErrorCount = count() by bin(TimeGenerated, 5m)
| summarize AvgPer5Min = avg(ErrorCount), MaxPer5Min = max(ErrorCount)"
```

Or from the Azure Portal: **Azure Local instance → Monitoring → Insights → (view) → LAW icon →
switch to KQL mode** - this is the same workflow documented in
[Azure Local - Insights and Logging - Part 2 - Log Alerts](/blog/azure-local-insights-part2-logalert),
which is also the source of the volume-health KQL used in `modules/logAlerts.bicep`.

## 5. Severities and thresholds

| Parameter | Default | Notes |
|---|---|---|
| `severityHealth` | 1 (Error) | Storage degraded, node heartbeat, volume health |
| `severityCapacity` | 2 (Warning) | CPU / Memory / storage capacity / latency / network |
| `severityPremium` | 2 (Warning) | Error-event rate |
| `cpuThresholdPercent` | 85 | Tune per cluster workload profile (MS recommends 80) |
| `memoryThresholdPercent` | 85 | Tune per cluster workload profile |
| `storageFreeBytesThreshold` | 214748364800 (200 GiB) | Absolute bytes, per volume (dimension `LUN`) - tune against `Volume Size Total` |
| `memoryAvailableBytesThreshold` | 1073741824 (1 GiB) | MS-recommended "Available Memory Bytes" alert |
| `volumeLatencyReadThresholdSeconds` | `'0.5'` (500 ms) | MS-recommended default; numeric string (seconds) |
| `volumeLatencyWriteThresholdSeconds` | `'0.5'` (500 ms) | MS-recommended default; numeric string (seconds) |
| `networkInThresholdBytesPerSecond` | 500000000000 (500 GB/s) | MS-recommended default - very high, review per NIC speed |
| `networkOutThresholdBytesPerSecond` | 200000000000 (200 GB/s) | MS-recommended default - very high, review per NIC speed |
| `heartbeatMissingMinutes` | 10 | Node considered unreachable |
| `evaluationFrequency` / `windowSize` | PT5M / PT15M | All alert rules |

All are Bicep parameters - override per environment in `bicep/parameters/*.json` or per pipeline
run via `pipeline/environments/<name>.yml`.

## 6. Related reading

- [Azure Local - Insights and Logging - Part 1](/blog/azure-local-insights-part1) - enabling log
  collection (Advanced/Premium prerequisite)
- [Azure Local - Insights and Logging - Part 2 - Log Alerts](/blog/azure-local-insights-part2-logalert) -
  the manual KQL alert-authoring workflow this repo automates
- [Azure Local - LENS - Deploy and auto-update the workbook with Azure DevOps](/blog/azure-local-lens-azure-devops-pipeline) -
  companion pipeline pattern for the LENS fleet-visibility workbook referenced in the Premium tier
