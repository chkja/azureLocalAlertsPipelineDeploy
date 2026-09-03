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
| CPU usage high | Metric | ✅ | ✅ | ✅ | metric `Hyper-V Hypervisor Logical Processor\% Total Run Time` (MS-recommended: >80%; default here: 85%) |
| Memory usage high (%) | Metric | ✅ | ✅ | ✅ | metric `ClusterNode Memory Usage` |
| Available memory low (bytes) | Metric | ✅ | ✅ | ✅ | metric `Memory\Available Bytes` - MS-recommended alert, < 1 GiB |
| Volume read latency high | Metric | ✅ | ✅ | ✅ | metric `Cluster CSVFS\Avg. sec/Read` - MS-recommended alert, > 500 ms |
| Volume write latency high | Metric | ✅ | ✅ | ✅ | metric `Cluster CSVFS\Avg. sec/Write` - MS-recommended alert, > 500 ms |
| Network inbound throughput high | Metric | ❌ | ✅ | ✅ | metric `Network Adapter\Bytes Received/sec` - MS-recommended alert, > 500 GB/s |
| Network outbound throughput high | Metric | ❌ | ✅ | ✅ | metric `Network Adapter\Bytes Sent/sec` - MS-recommended alert, > 200 GB/s |
| Storage capacity low (per volume) | Metric | ✅ | ✅ | ✅ | metric `Volume Size Available` (dimension-split by `LUN`), absolute bytes threshold |
| Node heartbeat missing (unreachable node) | Log | ❌ | ✅ | ✅ | `Heartbeat` table, KQL |
| Volume health degraded | Log | ❌ | ✅ | ✅ | `Event` table (`Microsoft-Windows-Health/Operational` + `Microsoft-Windows-SDDC-Management/Operational`), KQL |
| Elevated Error-event rate (proactive) | Log | ❌ | ❌ | ✅ | `Event` table, KQL |
| Subscription-wide Resource Health degraded/unavailable | Activity Log | ❌ | ❌ | ✅ | `Microsoft.Insights/activityLogAlerts`, category `ResourceHealth`, scoped to the whole subscription |
| Subscription-wide Service Health events | Activity Log | ❌ | ❌ | ✅ | `Microsoft.Insights/activityLogAlerts`, category `ServiceHealth` (toggle: `includeServiceHealth`) |

This directly maps to the service description:
- **Basic**: "Baseline monitoring of cluster availability and health signals (only alerts from
  cluster health)" and "only using metric alert" → storage-degraded, CPU, memory (% and bytes),
  and volume capacity/latency metric alerts, all with no Log Analytics dependency. Network
  in/out are excluded at Basic - their MS-recommended defaults are very high and require
  per-environment tuning, so they are held back to Advanced/Premium alongside the log alerts.
- **Advanced**: "Monitoring of core Azure Local data sources... via Log Analytics log collection",
  "Monitor capacity (CPU, memory and storage)" → adds network in/out metric alerts +
  heartbeat/volume health log alerts on top of the Basic metric set.
- **Premium**: "Full enablement and tuning of Azure Local Insights..." and "24/7 alert response...
  under SLA" → adds the enhanced proactive log alert, subscription-wide Activity Log alerts
  (Resource Health + Service Health) as a platform-health safety net, and (operationally) a second
  notification receiver representing the on-call rotation.


> **Premium-only Activity Log alerts are deliberately subscription-wide, not cluster-scoped.**
> `Microsoft.Insights/activityLogAlerts` must be deployed inside a resource group (an ARM
> requirement for the resource type), but its own `scopes` property is set to `subscription().id`
> so it catches ANY resource in the subscription reporting a Resource Health issue via the
> Activity Log - not just the monitored cluster. This matches the Premium tier's "full incident
> lifecycle ownership" and 24/7 SLA commitments: platform/hardware issues (e.g. underlying host,
> storage fabric, or connectivity problems reported by the Azure platform itself) are caught even
> if they haven't yet surfaced as a cluster-specific metric/log alert. Set `includeServiceHealth:
> false` to opt out of the companion Service Health alert (planned maintenance/service
> issues/security advisories) if it's already covered by a separate subscription-wide alert.

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
       ├─ modules/actionGroup.bicep       (email + webhook receivers)
       ├─ modules/metricAlerts.bicep      (storage-degraded, CPU, memory %/bytes, and volume
       │                                   capacity/latency in ALL tiers - pure metric alerts,
       │                                   no Log Analytics dependency; network in/out added
       │                                   only if Advanced/Premium)
       ├─ modules/logAlerts.bicep         (heartbeat + volume-health if Advanced/Premium; error-rate if Premium)
       ├─ modules/activityLogAlerts.bicep (Premium only - subscription-wide Resource/Service Health)
       ├─ modules/suppressionRules.bicep  (all tiers - ad hoc maintenance-window suppression rules)
       └─ modules/offHoursSuppression.bicep (Basic/Advanced only - standing weekly off-hours suppression)
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

### Log Analytics workspace pre-flight check (Advanced/Premium)

Before submitting the deployment, `Deploy-AzureLocalAlerts.ps1` calls `az resource show --ids
<LogAnalyticsWorkspaceResourceId>` to confirm the workspace actually exists and is reachable. This
matters because a `Microsoft.Insights/scheduledQueryRules` (log alert) resource deploys
**successfully** even when it points at a workspace ID that is misspelled or no longer exists - it
just silently never retrieves data, which otherwise surfaces later as "why did this alert never
fire" rather than as a deployment failure. The check fails fast, before any ARM call, with a clear
error identifying the bad workspace ID.

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

### Standing off-hours notification suppression (Basic/Advanced)

Per the service description, Basic alerts are "only responded to during service window" and
Advanced alerts are triaged "during working hours" - only Premium commits to 24/7 response.
`modules/offHoursSuppression.bicep` implements this directly: for Basic and Advanced (controlled
by the `enableOffHoursSuppression` parameter, default `true`; Premium ignores it and is always
24/7), it deploys a **standing weekly** `Microsoft.AlertsManagement/actionRules` schedule that
silences action-group notifications outside `serviceHoursStart`-`serviceHoursEnd` (default
`07:00:00`-`17:00:00`), Monday-Friday, in the `serviceHoursTimeZone` (default `Romance Standard
Time` / Copenhagen). Alert rules still evaluate around the clock in every tier - nothing is ever
silently missed, and the full history remains visible/queryable - only the notification is
suppressed outside the committed hours.

This is a separate mechanism from the maintenance-window suppression rules below: it's a fixed,
tier-derived standing schedule (not something an operator hand-authors), and covers the full week
using four rules to correctly handle midnight-crossing evenings and the two non-working days:

| Rule | Coverage (default 07:00-17:00 Mon-Fri) |
|---|---|
| Weekday evening → next morning | Mon 17:00 → Tue 07:00, ... , Fri 17:00 → Sat 07:00 |
| Monday early morning | Mon 00:00 → 07:00 (not covered by the rule above, since Sunday isn't a working day) |
| Saturday | All day |
| Sunday | All day |

Set `enableOffHoursSuppression: false` (or the `enableOffHoursSuppression` pipeline variable to
`'false'`) to opt a specific Basic/Advanced cluster out of this behavior (e.g. if the customer
wants 24/7 paging despite a Basic/Advanced contract).

### Maintenance-window suppression rules (all tiers)

Every tier supports **multiple suppression rules** (`Microsoft.AlertsManagement/actionRules`,
type `Suppression`) via the `suppressionWindows` array parameter / `suppressionWindowsJson`
pipeline variable. These quiet **notifications only** for a scheduled window - the underlying
alert rules stay enabled and alerts still fire/show in the portal, they just don't page anyone -
which avoids the configuration drift that comes from manually disabling/snoozing alerts in the
portal during planned maintenance (e.g. the monthly Azure Local solution update, SBE firmware
runs, or a customer-scheduled change window).

Each array entry becomes one suppression rule. Supported `recurrenceType` values:

| `recurrenceType` | Use case | Required fields |
|---|---|---|
| `None` | A single one-off window (e.g. a specific migration date) | `effectiveFrom`, `effectiveUntil` |
| `Daily` | Every day, same time window | + `startTime`, `endTime` |
| `Weekly` | Specific day(s) of the week | + `startTime`, `endTime`, `daysOfWeek` |
| `Monthly` | Specific day(s) of the month | + `startTime`, `endTime`, `daysOfMonth` |

Example - a recurring Saturday-night patch window plus a one-off migration window:

```json
[
  {
    "name": "monthly-patch-window",
    "description": "Monthly Azure Local solution update window",
    "effectiveFrom": "2026-01-01T00:00:00",
    "effectiveUntil": "2027-01-01T00:00:00",
    "timeZone": "UTC",
    "recurrenceType": "Weekly",
    "startTime": "22:00:00",
    "endTime": "02:00:00",
    "daysOfWeek": ["Saturday"]
  },
  {
    "name": "one-time-migration",
    "effectiveFrom": "2026-09-10T22:00:00",
    "effectiveUntil": "2026-09-11T04:00:00",
    "timeZone": "UTC",
    "recurrenceType": "None"
  }
]
```

Set this as `suppressionWindowsJson` (compact JSON string) in a `pipeline/environments/<name>.yml`
file, or as the `suppressionWindows` array parameter directly in a `bicep/parameters/*.json` file
for a one-off manual deployment. `scripts/Deploy-AzureLocalAlerts.ps1` validates the shape up
front (required fields per `recurrenceType`) before submitting the deployment, so a malformed
window fails fast with a clear error instead of a deep ARM error.

Suppression rules match on the resource ID(s) in `modules/suppressionRules.bicep`'s `scopes`
(the cluster resource ID by default) - matching is based on the **affected resource** of the
fired alert, not which alert rule created it, so a cluster-scoped suppression rule also silences
the Premium subscription-wide Resource Health alert for that same cluster during the window.

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
| `includeServiceHealth` | `true` | Premium only - also deploy the subscription-wide Service Health activity log alert |
| `suppressionWindows` | `[]` | All tiers - ad hoc maintenance-window suppression rules, see section 3 |
| `enableOffHoursSuppression` | `true` (Basic/Advanced), `false` (Premium) | Standing weekly off-hours notification suppression, see section 3 |
| `serviceHoursStart` / `serviceHoursEnd` | `07:00:00` / `17:00:00` | Committed service/working-hours window, Monday-Friday |
| `serviceHoursTimeZone` | `Romance Standard Time` | Windows time zone name for the service-hours window |
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
