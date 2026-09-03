// Resource-group scoped orchestration module: deploys the Action Group plus the metric/log
// alerts that apply to the selected service tier. Called from main.bicep (subscription scope).

@allowed([
  'Basic'
  'Advanced'
  'Premium'
])
@description('Managed service tier for this Azure Local cluster. Drives which alert set is deployed.')
param serviceTier string

@description('Azure region used for alert rule metadata.')
param location string

@description('ARM resource ID of the Microsoft.AzureStackHCI/clusters resource being monitored.')
param clusterResourceId string

@description('ARM resource ID of the Log Analytics workspace collecting Azure Local Insights data. Required for Advanced/Premium, ignored for Basic.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Action Group name.')
param actionGroupName string

@maxLength(12)
param actionGroupShortName string

@description('Email receivers: [{ name, emailAddress, useCommonAlertSchema }]')
param emailReceivers array = []

@description('Webhook receivers: [{ name, serviceUri, useCommonAlertSchema }]')
param webhookReceivers array = []

param cpuThresholdPercent int = 85
param memoryThresholdPercent int = 85
param storageFreeBytesThreshold int = 214748364800
param memoryAvailableBytesThreshold int = 1073741824
param volumeLatencyReadThresholdSeconds string = '0.5'
param volumeLatencyWriteThresholdSeconds string = '0.5'
param networkInThresholdBytesPerSecond int = 500000000000
param networkOutThresholdBytesPerSecond int = 200000000000
param heartbeatMissingMinutes int = 10
param evaluationFrequency string = 'PT5M'
param windowSize string = 'PT15M'
param severityHealth int = 1
param severityCapacity int = 2
param severityPremium int = 2

@description('Also alert on Azure Service Health events (Premium tier only, ignored otherwise). Default: true.')
param includeServiceHealth bool = true

@description('''
Array of maintenance-window suppression rule definitions, applied at every service tier. Each
entry creates one Suppression alert-processing rule that quiets action-group notifications for
this cluster during the defined schedule, without disabling the underlying alert rules. See
modules/suppressionRules.bicep for the exact per-entry shape, and docs/service-tiers-and-alerts.md
for worked examples. Default: [] (no suppression rules).
''')
param suppressionWindows array = []

var isAdvancedOrPremium = serviceTier == 'Advanced' || serviceTier == 'Premium'
var isPremium = serviceTier == 'Premium'

// NOTE: Advanced/Premium require a non-empty logAnalyticsWorkspaceResourceId.
// This is validated up-front by scripts/Deploy-AzureLocalAlerts.ps1 before this template
// is submitted, so a missing workspace ID fails fast with a clear error instead of a
// confusing deployment error deep in modules/logAlerts.bicep.

module actionGroup 'actionGroup.bicep' = {
  name: 'deploy-action-group'
  params: {
    actionGroupName: actionGroupName
    actionGroupShortName: actionGroupShortName
    emailReceivers: emailReceivers
    webhookReceivers: webhookReceivers
  }
}

module metricAlerts 'metricAlerts.bicep' = {
  name: 'deploy-metric-alerts'
  params: {
    clusterResourceId: clusterResourceId
    location: location
    actionGroupId: actionGroup.outputs.actionGroupId
    includeCapacityMetrics: isAdvancedOrPremium
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    severityHealth: severityHealth
    severityCapacity: severityCapacity
    cpuThresholdPercent: cpuThresholdPercent
    memoryThresholdPercent: memoryThresholdPercent
    storageFreeBytesThreshold: storageFreeBytesThreshold
    memoryAvailableBytesThreshold: memoryAvailableBytesThreshold
    volumeLatencyReadThresholdSeconds: volumeLatencyReadThresholdSeconds
    volumeLatencyWriteThresholdSeconds: volumeLatencyWriteThresholdSeconds
    networkInThresholdBytesPerSecond: networkInThresholdBytesPerSecond
    networkOutThresholdBytesPerSecond: networkOutThresholdBytesPerSecond
  }
}

module logAlerts 'logAlerts.bicep' = if (isAdvancedOrPremium) {
  name: 'deploy-log-alerts'
  params: {
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    clusterResourceId: clusterResourceId
    location: location
    actionGroupId: actionGroup.outputs.actionGroupId
    heartbeatMissingMinutes: heartbeatMissingMinutes
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    severityHealth: severityHealth
    severityStorage: severityHealth
    includePremiumAlerts: isPremium
    severityPremium: severityPremium
  }
}

// Premium only: subscription-wide Resource Health / Service Health safety net (see module header
// comment for rationale). Deployed inside this resource group (an ARM requirement for this
// resource type), but its own `scopes` property targets the whole subscription.
module activityLogAlerts 'activityLogAlerts.bicep' = if (isPremium) {
  name: 'deploy-activity-log-alerts'
  params: {
    actionGroupId: actionGroup.outputs.actionGroupId
    namePrefix: 'alert-sub-${last(split(clusterResourceId, '/'))}'
    includeServiceHealth: includeServiceHealth
  }
}

// All tiers: maintenance-window suppression rules. An empty suppressionWindows array (the
// default) deploys zero rules - safe to always include this module.
module suppressionRules 'suppressionRules.bicep' = {
  name: 'deploy-suppression-rules'
  params: {
    clusterResourceId: clusterResourceId
    suppressionWindows: suppressionWindows
  }
}

output actionGroupId string = actionGroup.outputs.actionGroupId
output deployedTier string = serviceTier
