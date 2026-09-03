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
| CPU usage high | Metric | ❌ | ✅ | ✅ | metric `Hyper-V Hypervisor Logical Processor\% Total Run Time` |
| Memory usage high | Metric | ❌ | ✅ | ✅ | metric `ClusterNode Memory Usage` |
| Node heartbeat missing (unreachable node) | Log | ❌ | ✅ | ✅ | `Heartbeat` table, KQL |
| Volume health degraded | Log | ❌ | ✅ | ✅ | `Event` table (`Microsoft-Windows-Health/Operational` + `Microsoft-Windows-SDDC-Management/Operational`), KQL |
| Elevated Error-event rate (proactive) | Log | ❌ | ❌ | ✅ | `Event` table, KQL |

This directly maps to the service description:
- **Basic**: "Baseline monitoring of cluster availability and health signals (only alerts from
  cluster health)" → storage-degraded metric alert only.
- **Advanced**: "Monitoring of core Azure Local data sources... via Log Analytics log collection",
  "Monitor capacity (CPU, memory and storage)" → adds CPU/memory metric alerts + heartbeat/volume
  health log alerts.
- **Premium**: "Full enablement and tuning of Azure Local Insights..." and "24/7 alert response...
  under SLA" → adds the enhanced proactive log alert and (operationally) a second notification
  receiver representing the on-call rotation.

> Storage **capacity** alerting (as opposed to storage **health**) is intentionally left as a
> tuning exercise per environment - see section 4 - because the exact Perf `CounterName` used for
> volume free-space percentage should be confirmed against your workspace before wiring a
> threshold (unlike CPU/Memory %, which are documented, stable platform metric names).

## 3. Deployment model

```
bicep/main.bicep                     (subscription scope, optional RG creation)
  └─ bicep/modules/alerts.bicep      (resource-group scope orchestrator, tier gating)
       ├─ modules/actionGroup.bicep  (email + webhook receivers)
       ├─ modules/metricAlerts.bicep (storage-degraded always; CPU/Memory if Advanced/Premium)
       └─ modules/logAlerts.bicep    (heartbeat + volume-health if Advanced/Premium; error-rate if Premium)
```

One Action Group per cluster is reused by every alert rule for that cluster, and supports both
**email** and **webhook** receivers (e.g. Freshservice ITSM webhook + an ops distribution list).

### Config-as-code / drift prevention

`pipeline/environments/<name>.yml` files commit, per cluster/tenant: the Azure DevOps service
connection (tenant), subscription/resource group, service tier, cluster/workspace resource IDs,
and action group receivers. `pipeline/azure-pipelines.yml` triggers on every push to `main` that
touches `bicep/**` or `pipeline/environments/**`. Because Bicep deployments are declarative, each
run re-applies exactly what's committed - reverting any manual portal changes on the next run
instead of letting configuration drift persist silently.

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

# Pull current values for the 3 metrics used in this repo's alert rules
az monitor metrics list \
  --resource "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.AzureStackHCI/clusters/<name>" \
  --metric "Cluster Node Storage Degraded,Hyper-V Hypervisor Logical Processor\% Total Run Time,ClusterNode Memory Usage" \
  --interval PT1H --output table
```

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
| `severityCapacity` | 2 (Warning) | CPU / Memory |
| `severityPremium` | 2 (Warning) | Error-event rate |
| `cpuThresholdPercent` | 85 | Tune per cluster workload profile |
| `memoryThresholdPercent` | 85 | Tune per cluster workload profile |
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
