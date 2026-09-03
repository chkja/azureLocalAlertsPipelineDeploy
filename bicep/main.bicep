// Entry point deployed at subscription scope so the pipeline can optionally create the
// resource group, then deploys the Action Group + tier-appropriate alert rules into it.
//
// Deploy with:
//   az deployment sub create --location <region> --template-file bicep/main.bicep \
//     --parameters bicep/parameters/<tier>.parameters.json
// or via scripts/Deploy-AzureLocalAlerts.ps1 (recommended - includes validation).

targetScope = 'subscription'

@allowed([
  'Basic'
  'Advanced'
  'Premium'
])
@description('Managed service tier for this Azure Local cluster. Basic = metric alerts only. Advanced/Premium = metric + log alerts.')
param serviceTier string

@description('Resource group that contains (or will contain) the Action Group and alert rules. Typically the same RG as the Azure Local cluster resource.')
param resourceGroupName string

@description('Azure region for the resource group (if created) and alert rule metadata.')
param location string = 'westeurope'

@description('Create the resource group as part of this deployment. Set to false if the RG already exists.')
param createResourceGroup bool = false

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

resource rg 'Microsoft.Resources/resourceGroups@2022-09-01' = if (createResourceGroup) {
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
    heartbeatMissingMinutes: heartbeatMissingMinutes
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    severityHealth: severityHealth
    severityCapacity: severityCapacity
    severityPremium: severityPremium
  }
  dependsOn: createResourceGroup ? [rg] : []
}

output actionGroupId string = alerts.outputs.actionGroupId
output deployedTier string = alerts.outputs.deployedTier
