// See example-customera-basic.bicepparam for field descriptions. This is the Advanced-tier
// example: includes the same baseline metric alerts plus capacity metric alerts and log-based
// alerts, which requires a Log Analytics workspace resource ID (Advanced/Premium prerequisite:
// Insights log collection must already be enabled on the cluster).
//
// Non-template metadata (service connection/tenant, subscription ID) lives in the companion
// example-customerb-advanced.yml file next to this one.

using '../../bicep/main.bicep'

param serviceTier = 'Advanced'
param resourceGroupName = 'rg-azurelocal-customerb-prod'
param location = 'westeurope'

param clusterResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-azurelocal-customerb-prod/providers/Microsoft.AzureStackHCI/clusters/azlclustercustomerb'
param logAnalyticsWorkspaceResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-azurelocal-customerb-prod/providers/Microsoft.OperationalInsights/workspaces/law-azurelocal-customerb'

param actionGroupName = 'ag-azurelocal-customerb-prod'
param actionGroupShortName = 'azlalerts'

param emailReceivers = [
  {
    name: 'fmp-ops'
    emailAddress: 'azurelocal-ops@example.com'
    useCommonAlertSchema: true
  }
]
param webhookReceivers = [
  {
    name: 'fmp-itsm-webhook'
    serviceUri: 'https://example.freshservice.com/api/v2/webhook/azurelocal-alerts'
    useCommonAlertSchema: true
  }
]

param cpuThresholdPercent = 85
param memoryThresholdPercent = 85
param storageFreeBytesThreshold = 214748364800
param memoryAvailableBytesThreshold = 1073741824
param volumeLatencyReadThresholdSeconds = '0.5'
param volumeLatencyWriteThresholdSeconds = '0.5'
param networkInThresholdBytesPerSecond = 500000000000
param networkOutThresholdBytesPerSecond = 200000000000
param includeServiceHealth = true
param suppressionWindows = []

// Suppress action-group notifications outside the committed Advanced working-hours window (per
// the service description: alert intake/triage "during working hours"). Alert rules still
// evaluate 24/7 - only notifications are silenced outside these hours.
param enableOffHoursSuppression = true
param serviceHoursStart = '07:00:00'
param serviceHoursEnd = '17:00:00'
param serviceHoursTimeZone = 'Romance Standard Time'

// Optional throttle for the log-based alerts (heartbeat/volume health): ISO 8601 duration (e.g.
// 'PT1H') for repeat notifications while an alert remains unresolved. Empty = stateful/single-fire.
param logAlertsMuteActionsDuration = ''

param heartbeatMissingMinutes = 10
