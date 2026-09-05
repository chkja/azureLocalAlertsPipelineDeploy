// Entry point deployed at subscription scope. Always ensures the target resource group exists
// (idempotent - safe to re-run against an existing RG), then deploys the Action Group +
// tier-appropriate alert rules into it.
//
// This template is intended to be deployed as an Azure Deployment Stack (not a plain
// `az deployment sub create`) so that every resource it creates is tracked, and accidental
// deletion outside the stack is denied. See scripts/Deploy-AzureLocalAlerts.ps1, which wraps:
//   az stack sub create --name <stackName> --location <region> --template-file bicep/main.bicep \
//     --parameters bicep/parameters/<tier>.parameters.json \
//     --deny-settings-mode denyDelete --action-on-unmanage deleteResources

targetScope = 'subscription'

@allowed([
  'Basic'
  'Advanced'
  'Premium'
])
@description('Managed service tier for this Azure Local cluster. Basic = metric alerts only. Advanced/Premium = metric + log alerts.')
param serviceTier string

@description('Name of the resource group that will contain the Action Group and alert rules. Typically the same RG as the Azure Local cluster resource. Created if it does not already exist.')
param resourceGroupName string

@description('Azure region for the resource group and alert rule metadata.')
param location string = 'westeurope'

@description('ARM resource ID of the Microsoft.AzureStackHCI/clusters resource being monitored.')
param clusterResourceId string

@description('ARM resource ID of the Log Analytics workspace collecting Azure Local Insights data. Required when serviceTier is Advanced or Premium.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Action Group name. One Action Group is deployed per cluster and reused by all its alert rules.')
param actionGroupName string

@maxLength(12)
@description('Action Group short name (max 12 characters), shown in portal/SMS.')
param actionGroupShortName string

@description('Email receivers: [{ name: string, emailAddress: string, useCommonAlertSchema: bool }]')
param emailReceivers array = []

@description('Webhook receivers: [{ name: string, serviceUri: string, useCommonAlertSchema: bool }]')
param webhookReceivers array = []

@description('CPU usage percent threshold for the capacity alert (Advanced/Premium only).')
param cpuThresholdPercent int = 85

@description('Memory usage percent threshold for the capacity alert (Advanced/Premium only).')
param memoryThresholdPercent int = 85

@description('Available volume space (bytes) below which a storage-capacity alert fires (Advanced/Premium only). Absolute bytes, not percent - tune per environment. Default: 200 GiB.')
param storageFreeBytesThreshold int = 214748364800

@description('Available memory (bytes) below which the Microsoft-recommended "Available Memory Bytes" alert fires (Advanced/Premium only). Default: 1 GiB.')
param memoryAvailableBytesThreshold int = 1073741824

@description('Volume read latency threshold, in seconds as a numeric string (Advanced/Premium only). Microsoft-recommended default: 500 ms = "0.5".')
param volumeLatencyReadThresholdSeconds string = '0.5'

@description('Volume write latency threshold, in seconds as a numeric string (Advanced/Premium only). Microsoft-recommended default: 500 ms = "0.5".')
param volumeLatencyWriteThresholdSeconds string = '0.5'

@description('Inbound network throughput threshold, bytes/sec (Advanced/Premium only). Microsoft-recommended default: 500 GB/s.')
param networkInThresholdBytesPerSecond int = 500000000000

@description('Outbound network throughput threshold, bytes/sec (Advanced/Premium only). Microsoft-recommended default: 200 GB/s.')
param networkOutThresholdBytesPerSecond int = 200000000000

@description('Minutes without a Heartbeat before a node is considered unreachable (Advanced/Premium only).')
param heartbeatMissingMinutes int = 10

@description('Evaluation frequency for all alert rules, ISO 8601 duration.')
param evaluationFrequency string = 'PT5M'

@description('Lookback window size for all alert rules, ISO 8601 duration.')
param windowSize string = 'PT15M'

@description('Severity for baseline health alerts (storage degraded, node heartbeat, volume health). 0=Critical .. 4=Verbose.')
param severityHealth int = 1

@description('Severity for capacity alerts (CPU/Memory).')
param severityCapacity int = 2

@description('Severity for the Premium-only enhanced monitoring alert.')
param severityPremium int = 2

@description('Also alert on Azure Service Health events, subscription-wide (Premium tier only, ignored otherwise). Default: true.')
param includeServiceHealth bool = true

@description('''
Array of maintenance-window suppression rule definitions, applied at every service tier. See
modules/suppressionRules.bicep for the exact per-entry shape and docs/service-tiers-and-alerts.md
for worked examples. Default: [] (no suppression rules).
''')
param suppressionWindows array = []

@description('Suppress action-group notifications outside the committed service/working-hours window for Basic/Advanced (ignored for Premium, which commits to 24/7 response). Default: true.')
param enableOffHoursSuppression bool = true

@description('Daily start of the committed service/working-hours window, "HH:mm:ss", Monday-Friday.')
param activeMonitoringHoursStart string = '07:00:00'

@description('Daily end of the committed service/working-hours window, "HH:mm:ss".')
param activeMonitoringHoursEnd string = '17:00:00'

@description('Windows time zone name the active-monitoring-hours window is evaluated in.')
param activeMonitoringHoursTimeZone string = 'Romance Standard Time'

@description('''
Optional throttle for the Advanced/Premium log-based alerts: ISO 8601 duration (e.g. "PT1H") for
which repeat notifications are suppressed after firing, while the condition remains true. Not
supported by Azure Monitor metric alerts. Default: '' (disabled - stateful, single notification).
''')
param logAlertsMuteActionsDuration string = ''

resource rg 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: resourceGroupName
  location: location
}

module alerts 'modules/alerts.bicep' = {
  name: 'deploy-azurelocal-alerts-${serviceTier}'
  scope: resourceGroup(resourceGroupName)
  params: {
    serviceTier: serviceTier
    location: location
    clusterResourceId: clusterResourceId
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    actionGroupName: actionGroupName
    actionGroupShortName: actionGroupShortName
    emailReceivers: emailReceivers
    webhookReceivers: webhookReceivers
    cpuThresholdPercent: cpuThresholdPercent
    memoryThresholdPercent: memoryThresholdPercent
    storageFreeBytesThreshold: storageFreeBytesThreshold
    memoryAvailableBytesThreshold: memoryAvailableBytesThreshold
    volumeLatencyReadThresholdSeconds: volumeLatencyReadThresholdSeconds
    volumeLatencyWriteThresholdSeconds: volumeLatencyWriteThresholdSeconds
    networkInThresholdBytesPerSecond: networkInThresholdBytesPerSecond
    networkOutThresholdBytesPerSecond: networkOutThresholdBytesPerSecond
    heartbeatMissingMinutes: heartbeatMissingMinutes
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    severityHealth: severityHealth
    severityCapacity: severityCapacity
    severityPremium: severityPremium
    includeServiceHealth: includeServiceHealth
    suppressionWindows: suppressionWindows
    enableOffHoursSuppression: enableOffHoursSuppression
    activeMonitoringHoursStart: activeMonitoringHoursStart
    activeMonitoringHoursEnd: activeMonitoringHoursEnd
    activeMonitoringHoursTimeZone: activeMonitoringHoursTimeZone
    logAlertsMuteActionsDuration: logAlertsMuteActionsDuration
  }
  dependsOn: [
    rg
  ]
}

output actionGroupId string = alerts.outputs.actionGroupId
output deployedTier string = alerts.outputs.deployedTier

