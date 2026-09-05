// One .bicepparam file per Azure Local cluster / tenant. Add a new file here to onboard a new
// customer or cluster, then add its base file name (without extension) to the `environmentFile`
// allowed values list in pipeline/azure-pipelines.yml.
//
// Committing these values in git (instead of an Azure DevOps variable group/library) is the
// intentional "config as code" approach requested: the CD pipeline re-applies exactly what is
// committed here on every run, so manual portal edits (drift) get reverted on the next merge to
// main instead of silently persisting.
//
// NOTE: Do not commit real secrets here. Webhook URLs that embed secrets/tokens should instead
// be stored in an Azure DevOps variable group and interpolated into a separate secrets file at
// pipeline runtime, if your organization requires that.
//
// Non-template metadata (which Azure DevOps service connection/tenant to deploy with, and the
// subscription ID used for `az account set`) lives in the companion
// example-customera-basic.yml file next to this one - it is NOT a Bicep parameter.

using '../../bicep/main.bicep'

param serviceTier = 'Basic'
param resourceGroupName = 'rg-azurelocal-customera-prod'
param location = 'westeurope'

param clusterResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-azurelocal-customera-prod/providers/Microsoft.AzureStackHCI/clusters/azlclustercustomera'
// Basic tier has no Log Analytics dependency - leave empty.
param logAnalyticsWorkspaceResourceId = ''

param actionGroupName = 'ag-azurelocal-customera-prod'
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

// Suppress action-group notifications outside the committed Basic service window (per the
// service description: "alerts will only be responded to during service window"). Alert rules
// still evaluate 24/7 - only notifications are silenced outside these hours.
param enableOffHoursSuppression = true
param activeMonitoringHoursStart = '07:00:00'
param activeMonitoringHoursEnd = '17:00:00'
param activeMonitoringHoursTimeZone = 'Romance Standard Time'

// Optional throttle for log-based alerts (ignored - Basic has none): ISO 8601 duration (e.g.
// 'PT1H') for repeat notifications while an alert remains unresolved. Empty = stateful/single-fire.
param logAlertsMuteActionsDuration = ''

param heartbeatMissingMinutes = 10
