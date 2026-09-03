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
param heartbeatMissingMinutes int = 10
param evaluationFrequency string = 'PT5M'
param windowSize string = 'PT15M'
param severityHealth int = 1
param severityCapacity int = 2
param severityPremium int = 2

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

output actionGroupId string = actionGroup.outputs.actionGroupId
output deployedTier string = serviceTier
