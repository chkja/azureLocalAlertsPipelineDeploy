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

@description('Whether alerts auto-resolve when the condition clears. Ignored (forced to false) when muteActionsDuration is set.')
param autoMitigate bool = true

@description('''
Optional throttle: ISO 8601 duration (e.g. "PT1H", "PT30M") for which repeat notifications are
suppressed after an alert fires, while the condition remains true. See metricAlerts.bicep for the
full explanation - same semantics apply here. Default: '' (disabled - stateful, single notification).
''')
param muteActionsDuration string = ''

@description('''
Substrings to match against the Windows Service Control Manager event message (System log,
EventID 7031/7034/7036) for the critical-service-down watchdog alert. Includes both the short
service name and a plausible display-name substring for each service, since the SCM event
message shows the DisplayName, not the short name, and exact display names can vary slightly
by Azure Local build. VERIFY against your own nodes before relying on this in production:
`Get-Service -Name HciSvc, mochostagent, wssdcloudagent, wssdagent | Select-Object Name, DisplayName`
and adjust this list if your DisplayNames differ. Requires the "System" Windows Event Log
channel to be collected by the Data Collection Rule - see docs/service-tiers-and-alerts.md.
''')
param criticalServiceNames array = [
  'HciSvc'
  'Health Service'
  'mochostagent'
  'MOC HostAgent'
  'wssdcloudagent'
  'WSSD Cloud Agent'
  'wssdagent'
  'WSSD Agent'
]

@description('Severity for the cluster quorum-loss / node-isolation and Hyper-V availability alerts.')
param severityCluster int = 1

@description('Severity for the critical-service-down watchdog alert.')
param severityServiceWatchdog int = 1

var clusterName = last(split(clusterResourceId, '/'))
var criticalServiceNamesKql = join(map(criticalServiceNames, n => '\'${n}\''), ', ')
var useMuteActionsDuration = !empty(muteActionsDuration)
var effectiveAutoMitigate = useMuteActionsDuration ? false : autoMitigate

// ---------------------------------------------------------------------------
// Advanced + Premium: node heartbeat / connectivity loss
// ---------------------------------------------------------------------------
resource nodeHeartbeatAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'insqr-${clusterName}-node-heartbeat-missing'
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
          query: 'Heartbeat\n| summarize LastHeartbeat = max(TimeGenerated) by Computer\n| where LastHeartbeat < ago(${heartbeatMissingMinutes}m)\n| project Computer, LastHeartbeat'
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
    autoMitigate: effectiveAutoMitigate
    muteActionsDuration: useMuteActionsDuration ? muteActionsDuration : null
  }
}

// ---------------------------------------------------------------------------
// Advanced + Premium: volume / storage health (Microsoft-Windows-Health event correlation)
// Adapted from the KQL published in "Azure Local - Insights and Logging - Part 2 - Log Alerts":
// https://chkja.dk/blog/azure-local-insights-part2-logalert
// ---------------------------------------------------------------------------
resource volumeHealthAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'insqr-${clusterName}-volume-health'
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
    autoMitigate: effectiveAutoMitigate
    muteActionsDuration: useMuteActionsDuration ? muteActionsDuration : null
  }
}

// ---------------------------------------------------------------------------
// Premium only: enhanced proactive monitoring - spike in Error-level events across the cluster.
// This complements the 24/7 SLA response commitment with earlier/wider signal coverage.
// TIP: validate/tune the threshold against your own event volume baseline before go-live -
// see docs/service-tiers-and-alerts.md "Exploration commands" section.
// ---------------------------------------------------------------------------
resource errorEventRateAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = if (includePremiumAlerts) {
  name: 'insqr-${clusterName}-error-event-rate'
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
          query: 'Event\n| where EventLevelName == "Error"\n| summarize ErrorCount = count() by bin(TimeGenerated, 5m)\n| where ErrorCount > 20'
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
    autoMitigate: effectiveAutoMitigate
    muteActionsDuration: useMuteActionsDuration ? muteActionsDuration : null
  }
}

// ---------------------------------------------------------------------------
// Advanced + Premium: general Health Service fault, any object type OTHER than Volume
// (Volume is already covered by volumeHealthAlert above - excluded here to avoid double-firing
// for the same underlying fault). Widens coverage to PhysicalDisk, StoragePool, Server, Cluster,
// Network, VirtualMachine, VHD, etc. without needing any new Data Collection Rule changes - this
// reuses the "Microsoft-Windows-Health/Operational" channel already collected for volumeHealthAlert.
// Per Microsoft docs, the built-in Health Service tracks 80+ fault types across these categories:
// https://learn.microsoft.com/azure/azure-local/manage/health-service-faults
// ---------------------------------------------------------------------------
resource generalHealthFaultAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'insqr-${clusterName}-general-health-fault'
  location: location
  properties: {
    displayName: 'Azure Local - Health Service fault detected (${clusterName})'
    description: 'Fires when the built-in Health Service reports a non-Volume fault (PhysicalDisk, StoragePool, Server, Cluster, Network, VM, etc.) via Microsoft-Windows-Health/Operational.'
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
          query: 'Event\n| where EventLog == "Microsoft-Windows-Health/Operational"\n| extend d = parse_json(RenderedDescription)\n| where tostring(d.Fault.ObjectType) != "Microsoft.Health.EntityType.Volume"\n| extend Severity = toint(d.Fault.Severity)\n| extend Status = iff(Severity > 2, -1, Severity)\n| summarize arg_max(TimeGenerated, Status) by ObjectId = tostring(d.Fault.ObjectId), ObjectType = tostring(d.Fault.ObjectType)\n| where Status != 0\n| project TimeGenerated, ObjectType, ObjectId, Status'
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
    autoMitigate: effectiveAutoMitigate
    muteActionsDuration: useMuteActionsDuration ? muteActionsDuration : null
  }
}

// ---------------------------------------------------------------------------
// Advanced + Premium: cluster quorum loss / node isolation. NOT a Health Service fault type -
// these are native Failover Clustering events and matter specifically because they can occur
// even when the Health Service itself is degraded or unreachable (e.g. the cluster losing
// quorum can also stop the Health Service from functioning/reporting).
// REQUIRES the Data Collection Rule to collect "Microsoft-Windows-FailoverClustering/Operational"
// (EventID 1205, 1573) - not collected by the default Azure Local Insights DCR. See
// docs/service-tiers-and-alerts.md "Extended event log collection (DCR)" section.
// ---------------------------------------------------------------------------
resource clusterQuorumIsolationAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'insqr-${clusterName}-quorum-node-isolation'
  location: location
  properties: {
    displayName: 'Azure Local - Cluster quorum loss or node isolation (${clusterName})'
    description: 'Fires on Failover Clustering EventID 1205 (quorum lost) or 1573 (node forcibly removed / isolated - split-brain). Requires the FailoverClustering event channel to be collected by the DCR.'
    severity: severityCluster
    enabled: true
    scopes: [
      logAnalyticsWorkspaceResourceId
    ]
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    criteria: {
      allOf: [
        {
          query: 'Event\n| where EventLog == "Microsoft-Windows-FailoverClustering/Operational"\n| where EventID == 1205 or EventID == 1573\n| project TimeGenerated, Computer, EventID, RenderedDescription'
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
    autoMitigate: effectiveAutoMitigate
    muteActionsDuration: useMuteActionsDuration ? muteActionsDuration : null
  }
}

// ---------------------------------------------------------------------------
// Advanced + Premium: critical platform service down/crashing watchdog - HciSvc (the Health
// Service itself - if this stops, all Health Service based alerts above go silent), plus the
// MOC/Arc Resource Bridge agents (mochostagent, wssdcloudagent, wssdagent) used for Arc VM/AKS
// hybrid workload management. Matches Service Control Manager EventID 7031 (crashed and
// restarted), 7034 (terminated unexpectedly), 7036 (entered stopped state).
// REQUIRES the "System" event log channel to be collected by the DCR (Service Control Manager
// source) - not collected by the default Azure Local Insights DCR. See
// docs/service-tiers-and-alerts.md "Extended event log collection (DCR)" section.
// TIP: verify criticalServiceNames matches your nodes' exact DisplayName - see param description.
// ---------------------------------------------------------------------------
resource criticalServiceDownAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'insqr-${clusterName}-critical-service-down'
  location: location
  properties: {
    displayName: 'Azure Local - Critical platform service down (${clusterName})'
    description: 'Fires when HciSvc (Health Service) or a MOC/Arc Resource Bridge agent service (mochostagent, wssdcloudagent, wssdagent) crashes or stops unexpectedly, per Service Control Manager events.'
    severity: severityServiceWatchdog
    enabled: true
    scopes: [
      logAnalyticsWorkspaceResourceId
    ]
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    criteria: {
      allOf: [
        {
          query: 'Event\n| where EventLog == "System"\n| where EventID in (7031, 7034, 7036)\n| where Source == "Service Control Manager"\n| where RenderedDescription has_any (dynamic([${criticalServiceNamesKql}]))\n| project TimeGenerated, Computer, EventID, RenderedDescription'
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
    autoMitigate: effectiveAutoMitigate
    muteActionsDuration: useMuteActionsDuration ? muteActionsDuration : null
  }
}

// ---------------------------------------------------------------------------
// Advanced + Premium: Hyper-V compute availability - VMMS service errors (10650) and
// high-availability live-migration failures (12400). Complements the Health Service VM/VHD
// fault category with Hyper-V's own operational signals.
// REQUIRES the Data Collection Rule to collect "Microsoft-Windows-Hyper-V-VMMS-Admin" and
// "Microsoft-Windows-Hyper-V-High-Availability-Admin" - not collected by the default Azure Local
// Insights DCR. See docs/service-tiers-and-alerts.md "Extended event log collection (DCR)" section.
// ---------------------------------------------------------------------------
resource hyperVAvailabilityAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'insqr-${clusterName}-hyperv-availability'
  location: location
  properties: {
    displayName: 'Azure Local - Hyper-V VM availability issue (${clusterName})'
    description: 'Fires on Hyper-V VMMS Admin EventID 10650 (VM Management Service error) or Hyper-V High-Availability Admin EventID 12400 (live migration failed / lost network connectivity).'
    severity: severityCluster
    enabled: true
    scopes: [
      logAnalyticsWorkspaceResourceId
    ]
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    criteria: {
      allOf: [
        {
          query: 'Event\n| where EventLog in ("Microsoft-Windows-Hyper-V-VMMS-Admin", "Microsoft-Windows-Hyper-V-High-Availability-Admin")\n| where EventID == 10650 or EventID == 12400\n| project TimeGenerated, Computer, EventLog, EventID, RenderedDescription'
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
    autoMitigate: effectiveAutoMitigate
    muteActionsDuration: useMuteActionsDuration ? muteActionsDuration : null
  }
}

output nodeHeartbeatAlertId string = nodeHeartbeatAlert.id
output volumeHealthAlertId string = volumeHealthAlert.id
output errorEventRateAlertId string = includePremiumAlerts ? errorEventRateAlert.id : ''
output generalHealthFaultAlertId string = generalHealthFaultAlert.id
output clusterQuorumIsolationAlertId string = clusterQuorumIsolationAlert.id
output criticalServiceDownAlertId string = criticalServiceDownAlert.id
output hyperVAvailabilityAlertId string = hyperVAvailabilityAlert.id
