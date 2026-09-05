// See example-customera-basic.bicepparam for field descriptions. This is the Premium-tier
// example: same as Advanced plus the enhanced proactive monitoring log alert (error-event rate)
// and a second email receiver representing the 24/7 on-call rotation required for the Premium SLA.
//
// Non-template metadata (service connection/tenant, subscription ID) lives in the companion
// example-customerc-premium.yml file next to this one. The DCR resource ID (used only for the
// script's pre-flight event-log auto-extension check, not a Bicep template parameter) also lives
// there.

using '../../bicep/main.bicep'

param serviceTier = 'Premium'
param resourceGroupName = 'rg-azurelocal-customerc-prod'
param location = 'westeurope'

param clusterResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-azurelocal-customerc-prod/providers/Microsoft.AzureStackHCI/clusters/azlclustercustomerc'
param logAnalyticsWorkspaceResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-azurelocal-customerc-prod/providers/Microsoft.OperationalInsights/workspaces/law-azurelocal-customerc'

param actionGroupName = 'ag-azurelocal-customerc-prod'
param actionGroupShortName = 'azlalerts'

param emailReceivers = [
  {
    name: 'fmp-ops'
    emailAddress: 'azurelocal-ops@example.com'
    useCommonAlertSchema: true
  }
  {
    name: 'fmp-oncall'
    emailAddress: 'azurelocal-oncall@example.com'
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

// Example maintenance window (recurring, every Saturday 22:00-02:00 UTC) - uncomment/adapt to enable:
// param suppressionWindows = [
//   {
//     name: 'monthly-patch-window'
//     description: 'Monthly Azure Local solution update window'
//     effectiveFrom: '2026-01-01T00:00:00'
//     effectiveUntil: '2027-01-01T00:00:00'
//     timeZone: 'UTC'
//     recurrenceType: 'Weekly'
//     startTime: '22:00:00'
//     endTime: '02:00:00'
//     daysOfWeek: ['Saturday']
//   }
// ]
param suppressionWindows = []

// Premium commits to 24/7 alert response under SLA - never suppress off-hours.
param enableOffHoursSuppression = false
param activeMonitoringHoursStart = '07:00:00'
param activeMonitoringHoursEnd = '17:00:00'
param activeMonitoringHoursTimeZone = 'Romance Standard Time'

// Optional throttle for the log-based alerts (heartbeat/volume health/error-rate): ISO 8601
// duration (e.g. 'PT1H') for repeat notifications while an alert remains unresolved - useful for
// Premium's 24/7 on-call to be re-paged periodically on a long-running unresolved incident.
// Empty (default) = stateful/single-fire (one Fired, one Resolved notification).
param logAlertsMuteActionsDuration = ''

param heartbeatMissingMinutes = 10
