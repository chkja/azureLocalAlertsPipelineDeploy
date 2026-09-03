<#
.SYNOPSIS
    Exploration helper: runs the discovery commands documented in
    docs/service-tiers-and-alerts.md against a live Azure Local cluster and its Log Analytics
    workspace, so you can confirm exact metric/table/counter names before tuning alert
    thresholds in the parameter files.

.DESCRIPTION
    This script does NOT deploy anything. It only queries and prints results so you can decide
    on real thresholds for your environment. Requires Azure CLI (`az`) logged in with read
    access to the cluster and workspace.

.PARAMETER ClusterResourceId
    ARM resource ID of the Microsoft.AzureStackHCI/clusters resource.

.PARAMETER LogAnalyticsWorkspaceId
    Workspace GUID (Workspace ID, not ARM resource ID) used by `az monitor log-analytics query`.

.EXAMPLE
    pwsh -File ./Get-AzureLocalAlertExploration.ps1 `
      -ClusterResourceId "/subscriptions/.../providers/Microsoft.AzureStackHCI/clusters/azlclustercustomera" `
      -LogAnalyticsWorkspaceId "00000000-0000-0000-0000-000000000000"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ClusterResourceId,

    [Parameter(Mandatory = $false)]
    [string]$LogAnalyticsWorkspaceId
)

$ErrorActionPreference = 'Stop'

Write-Host "`n=== 1. Platform metric definitions available on the cluster resource ===" -ForegroundColor Cyan
az monitor metrics list-definitions --resource $ClusterResourceId --output table

Write-Host "`n=== 2. Current values for the metrics used by this repo's alert rules ===" -ForegroundColor Cyan
$metricNames = @(
    'Cluster Node Storage Degraded',
    'Hyper-V Hypervisor Logical Processor\% Total Run Time',
    'ClusterNode Memory Usage'
) -join ','
az monitor metrics list --resource $ClusterResourceId --metric $metricNames --interval PT1H --output table

if (-not $LogAnalyticsWorkspaceId) {
    Write-Host "`nNo -LogAnalyticsWorkspaceId supplied - skipping Log Analytics exploration (Advanced/Premium only)." -ForegroundColor Yellow
    return
}

Write-Host "`n=== 3. Which tables is the cluster actually sending data to? ===" -ForegroundColor Cyan
az monitor log-analytics query -w $LogAnalyticsWorkspaceId --analytics-query `
    "union withsource=TableName *
| where TimeGenerated > ago(1d)
| summarize Count = count() by TableName
| order by Count desc" --output table

Write-Host "`n=== 4. Perf table: available ObjectName/CounterName combinations (use to tune storage-capacity KQL) ===" -ForegroundColor Cyan
az monitor log-analytics query -w $LogAnalyticsWorkspaceId --analytics-query `
    "Perf
| where TimeGenerated > ago(1d)
| summarize by ObjectName, CounterName
| order by ObjectName asc" --output table

Write-Host "`n=== 5. Heartbeat: last heartbeat per node (validate node naming used in KQL scoping) ===" -ForegroundColor Cyan
az monitor log-analytics query -w $LogAnalyticsWorkspaceId --analytics-query `
    "Heartbeat
| summarize LastHeartbeat = max(TimeGenerated) by Computer
| order by LastHeartbeat desc" --output table

Write-Host "`n=== 6. Event table: most frequent EventID/EventLog combinations in the last 24h ===" -ForegroundColor Cyan
az monitor log-analytics query -w $LogAnalyticsWorkspaceId --analytics-query `
    "Event
| where TimeGenerated > ago(1d)
| summarize Count = count() by EventLog, EventID, EventLevelName
| order by Count desc
| take 25" --output table

Write-Host "`n=== 7. Event table: baseline Error-level event rate per 5m bucket (tune Premium error-rate alert threshold) ===" -ForegroundColor Cyan
az monitor log-analytics query -w $LogAnalyticsWorkspaceId --analytics-query `
    "Event
| where TimeGenerated > ago(7d)
| where EventLevelName == 'Error'
| summarize ErrorCount = count() by bin(TimeGenerated, 5m)
| summarize AvgPer5Min = avg(ErrorCount), MaxPer5Min = max(ErrorCount)" --output table

Write-Host "`nDone. Use these results to validate metric names in bicep/modules/metricAlerts.bicep and tune KQL/thresholds in bicep/modules/logAlerts.bicep." -ForegroundColor Green
