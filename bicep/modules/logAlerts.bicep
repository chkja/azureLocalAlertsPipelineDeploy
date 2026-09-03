// Log alerts (scheduledQueryRules) against the Log Analytics workspace collecting Azure Local
// Insights data (Heartbeat, Perf, Event tables). Only deployed for Advanced and Premium tiers,
// where log collection via Data Collection Rules is a service prerequisite.
//
// See docs/service-tiers-and-alerts.md for the full KQL used and how each query was derived.

@description('Resource ID of the Log Analytics workspace collecting Azure Local Insights data.')
param logAnalyticsWorkspaceResourceId string

@description('ARM resource ID of the monitored Microsoft.AzureStackHCI/clusters resource. Used to scope KQL to this cluster only.')
param clusterResourceId string

@description('Azure region for the alert rule metadata.')
param location string

@description('Action Group resource ID to notify.')
param actionGroupId string

@description('Minutes since last Heartbeat before a node is considered unreachable.')
param heartbeatMissingMinutes int = 10

@description('Evaluation frequency, ISO 8601 duration.')
param evaluationFrequency string = 'PT5M'

@description('Window size, ISO 8601 duration.')
param windowSize string = 'PT15M'

@description('Severity for node-down / connectivity alerts.')
param severityHealth int = 1

@description('Severity for volume/storage health alerts.')
param severityStorage int = 1

@description('Include the extra Premium-tier proactive monitoring alert (event-log error rate spike).')
param includePremiumAlerts bool = false

@description('Severity for the Premium-only enhanced monitoring alert.')
param severityPremium int = 2

var clusterName = last(split(clusterResourceId, '/'))

// ---------------------------------------------------------------------------
// Advanced + Premium: node heartbeat / connectivity loss
// ---------------------------------------------------------------------------
resource nodeHeartbeatAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-${clusterName}-node-heartbeat-missing'
  location: location
  properties: {
    displayName: 'Azure Local - Node heartbeat missing (${clusterName})'
    description: 'Fires when an Azure Local node has not sent a Heartbeat within ${heartbeatMissingMinutes} minutes, indicating the node/AMA agent is unreachable.'
    severity: severityHealth
    enabled: true
    scopes: [
      logAnalyticsWorkspaceResourceId
    ]
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    criteria: {
      allOf: [
        {
          query: 'Heartbeat\n| where Computer has "${clusterName}"\n| summarize LastHeartbeat = max(TimeGenerated) by Computer\n| where LastHeartbeat < ago(${heartbeatMissingMinutes}m)\n| project Computer, LastHeartbeat'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroupId
      ]
    }
    autoMitigate: true
  }
}

// ---------------------------------------------------------------------------
// Advanced + Premium: volume / storage health (Microsoft-Windows-Health event correlation)
// Adapted from the KQL published in "Azure Local - Insights and Logging - Part 2 - Log Alerts":
// https://chkja.dk/blog/azure-local-insights-part2-logalert
// ---------------------------------------------------------------------------
resource volumeHealthAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-${clusterName}-volume-health'
  location: location
  properties: {
    displayName: 'Azure Local - Volume health degraded (${clusterName})'
    description: 'Fires when a cluster volume reports a health fault (Status > 0) via Microsoft-Windows-Health/Operational event correlation.'
    severity: severityStorage
    enabled: true
    scopes: [
      logAnalyticsWorkspaceResourceId
    ]
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    criteria: {
      allOf: [
        {
          query: 'Event\n| where EventLog == "Microsoft-Windows-SDDC-Management/Operational"\n| where EventID == 3002\n| where _ResourceId !contains "/Microsoft.AzureStackHCI/"\n| project TimeGenerated, EventData, RenderedDescription\n| extend x = parse_xml(EventData)\n| extend ClusterArmId = tostring(x.DataItem.UserData.EventData["ArmId"])\n| where ClusterArmId =~ "${clusterResourceId}"\n| summarize arg_max(TimeGenerated, RenderedDescription) by ClusterArmId\n| extend volumes = parse_json(RenderedDescription).VolumeList\n| mv-expand volumes\n| extend VolumeId = tostring(volumes.m_Id)\n| join kind=inner (\n    Event\n    | where EventLog == "Microsoft-Windows-Health/Operational"\n    | extend d = parse_json(RenderedDescription)\n    | where tostring(d.Fault.ObjectType) == "Microsoft.Health.EntityType.Volume"\n    | extend VolumeId = extract(@"volume{([^}]+)}", 1, tostring(d.Fault.ObjectId))\n    | extend Severity = toint(d.Fault.Severity)\n    | extend Status = iff(Severity > 2, -1, Severity)\n    | summarize Status = max(Status) by VolumeId\n) on VolumeId\n| where Status != 0\n| project TimeGenerated, VolumeId, Status'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroupId
      ]
    }
    autoMitigate: true
  }
}

// ---------------------------------------------------------------------------
// Premium only: enhanced proactive monitoring - spike in Error-level events across the cluster.
// This complements the 24/7 SLA response commitment with earlier/wider signal coverage.
// TIP: validate/tune the threshold against your own event volume baseline before go-live -
// see docs/service-tiers-and-alerts.md "Exploration commands" section.
// ---------------------------------------------------------------------------
resource errorEventRateAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = if (includePremiumAlerts) {
  name: 'alert-${clusterName}-error-event-rate'
  location: location
  properties: {
    displayName: 'Azure Local - Elevated Error event rate (${clusterName})'
    description: 'Premium enhanced monitoring: fires when Error-level Windows events across the cluster nodes exceed baseline volume within the evaluation window.'
    severity: severityPremium
    enabled: true
    scopes: [
      logAnalyticsWorkspaceResourceId
    ]
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    criteria: {
      allOf: [
        {
          query: 'Event\n| where _ResourceId has "${clusterName}" or Computer has "${clusterName}"\n| where EventLevelName == "Error"\n| summarize ErrorCount = count() by bin(TimeGenerated, 5m)\n| where ErrorCount > 20'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroupId
      ]
    }
    autoMitigate: true
  }
}

output nodeHeartbeatAlertId string = nodeHeartbeatAlert.id
output volumeHealthAlertId string = volumeHealthAlert.id
output errorEventRateAlertId string = includePremiumAlerts ? errorEventRateAlert.id : ''
