// Deploys a single Action Group used by all metric and log alerts for one Azure Local cluster.
// Supports Email and Webhook receivers. Both arrays are optional but at least one receiver
// (of either kind) should be supplied or alerts will fire with nobody notified.

@description('Name of the Action Group resource.')
param actionGroupName string

@description('Short name shown on SMS/portal (max 12 chars).')
@maxLength(12)
param actionGroupShortName string

@description('Azure region for the Action Group (Action Groups are global, but a location value is still required by the resource schema).')
param location string = 'global'

@description('Email receivers. Each item: { name: string, emailAddress: string, useCommonAlertSchema: bool }')
param emailReceivers array = []

@description('Webhook receivers. Each item: { name: string, serviceUri: string, useCommonAlertSchema: bool }')
param webhookReceivers array = []

@description('Whether the Action Group is enabled.')
param enabled bool = true

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: location
  properties: {
    groupShortName: actionGroupShortName
    enabled: enabled
    emailReceivers: [for r in emailReceivers: {
      name: r.name
      emailAddress: r.emailAddress
      useCommonAlertSchema: r.?useCommonAlertSchema ?? true
    }]
    webhookReceivers: [for r in webhookReceivers: {
      name: r.name
      serviceUri: r.serviceUri
      useCommonAlertSchema: r.?useCommonAlertSchema ?? true
    }]
  }
}

output actionGroupId string = actionGroup.id
output actionGroupName string = actionGroup.name
