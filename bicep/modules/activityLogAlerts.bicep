// Activity Log Alerts (Microsoft.Insights/activityLogAlerts) - Premium tier only.
//
// The activityLogAlerts resource type can only be deployed at resource-group scope (it lives
// inside this alerting resource group), but its `scopes` property targets the WHOLE
// SUBSCRIPTION - so this catches ANY resource in the subscription reporting a Resource Health
// issue via the Activity Log, not just the monitored cluster. This is a deliberate Premium-tier
// safety net: the service description's Premium commitments ("24/7 alert response... under
// SLA", "full incident lifecycle ownership") call for broad platform-health coverage in
// addition to the cluster-specific metric/log alerts deployed by the other modules.
//
// Reference: https://learn.microsoft.com/azure/azure-monitor/alerts/resource-manager-alerts-resource-health
// Reference: https://learn.microsoft.com/azure/service-health/alerts-activity-log-service-notifications-portal

@description('Action Group resource ID to notify.')
param actionGroupId string

@description('Name prefix for the activity log alert resource(s), e.g. "alert-sub-<clustername>".')
param namePrefix string

@description('Also alert on Azure Service Health events (planned maintenance, service issues, security advisories, health advisories) affecting the subscription, in addition to per-resource Resource Health events. Default: true.')
param includeServiceHealth bool = true

resource resourceHealthAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: '${namePrefix}-resource-health'
  location: 'Global'
  properties: {
    enabled: true
    description: 'Fires when any resource in the subscription reports a Degraded or Unavailable Resource Health status via the Activity Log. Subscription-wide Premium-tier safety net for platform/hardware health issues that may not be surfaced by cluster-specific metric/log alerts (e.g. underlying host, storage, or network fabric problems reported by the Azure platform itself).'
    scopes: [
      subscription().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ResourceHealth'
        }
        {
          anyOf: [
            {
              field: 'properties.currentHealthStatus'
              equals: 'Unavailable'
            }
            {
              field: 'properties.currentHealthStatus'
              equals: 'Degraded'
            }
          ]
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroupId
        }
      ]
    }
  }
}

resource serviceHealthAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = if (includeServiceHealth) {
  name: '${namePrefix}-service-health'
  location: 'Global'
  properties: {
    enabled: true
    description: 'Fires on Azure Service Health events (service issues, planned maintenance, security advisories, health advisories) affecting this subscription.'
    scopes: [
      subscription().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ServiceHealth'
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroupId
        }
      ]
    }
  }
}

output resourceHealthAlertId string = resourceHealthAlert.id
output serviceHealthAlertId string = includeServiceHealth ? serviceHealthAlert.id : ''
