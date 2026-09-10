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

@description('Suppress action-group notifications outside the committed service/working-hours window for Basic/Advanced (ignored for Premium, which commits to 24/7 response). Default: true.')
param enableOffHoursSuppression bool = true

@description('Daily start of the committed service/working-hours window, "HH:mm:ss", Monday-Friday. Used only when enableOffHoursSuppression is true and the tier is not Premium.')
param activeMonitoringHoursStart string = '07:00:00'

@description('Daily end of the committed service/working-hours window, "HH:mm:ss".')
param activeMonitoringHoursEnd string = '17:00:00'

@description('Windows time zone name the active-monitoring-hours window is evaluated in.')
param activeMonitoringHoursTimeZone string = 'Romance Standard Time'

@description('''
Optional throttle for the Advanced/Premium log-based alerts (heartbeat, volume health, and the
Premium error-rate alert): ISO 8601 duration (e.g. "PT1H") for which repeat notifications are
suppressed after firing, while the condition remains true. When set, this switches from the
default "one Fired notification, then silent until Resolved" (stateful) behavior to periodic
re-notification every muteActionsDuration for as long as the issue persists. Not supported by
Azure Monitor metric alerts (Microsoft.Insights/metricAlerts has no equivalent property - those
remain purely stateful regardless of this setting). Default: '' (disabled).
''')
param logAlertsMuteActionsDuration string = ''

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
    serviceTier: serviceTier
    // Deliberately NOT passing `location` here - metricAlerts.bicep defaults it to 'global',
    // which is required for single-resource ("resource-level") static-threshold metric alerts.
    // Passing the deployment's actual Azure region instead causes ARM to classify these as
    // "Regional" (multi-resource) alert rules, which only support custom metrics and fail with
    // "A Regional alert rule can only be created on a custom metric" for platform metrics like
    // Microsoft.AzureStackHCI/clusters - confirmed via a live failed deployment.
    actionGroupId: actionGroup.outputs.actionGroupId
    // CPU / memory / volume-capacity metric alerts are pure metric alerts (no Log Analytics
    // dependency), so per the service description ("Basic level is only using metric alert")
    // they are included from Basic upward. Network in/out defaults are very high and less
    // universally useful, so they stay gated to Advanced/Premium.
    includeCapacityMetrics: true
    includeNetworkMetrics: isAdvancedOrPremium
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
    serviceTier: serviceTier
    location: location
    actionGroupId: actionGroup.outputs.actionGroupId
    heartbeatMissingMinutes: heartbeatMissingMinutes
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    severityHealth: severityHealth
    severityStorage: severityHealth
    includePremiumAlerts: isPremium
    severityPremium: severityPremium
    muteActionsDuration: logAlertsMuteActionsDuration
    severityCluster: severityHealth
    severityServiceWatchdog: severityHealth
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
// Log-based alerts (scheduledQueryRules, Advanced/Premium only) are scoped to
// logAnalyticsWorkspaceResourceId, not clusterResourceId - Alert Processing Rules match on the
// alert's actual target resource, so the workspace must also be included in scopes or none of
// the log alerts (heartbeat, volume health, general health fault, quorum, service watchdog,
// Hyper-V) will ever actually be suppressed by these rules. Confirmed live: a log alert showed
// "Suppression status: None" in the portal despite an active suppression rule, because its
// scopes list only contained the cluster resource ID.
module suppressionRules 'suppressionRules.bicep' = {
  name: 'deploy-suppression-rules'
  params: {
    clusterResourceId: clusterResourceId
    additionalScopes: isAdvancedOrPremium ? [logAnalyticsWorkspaceResourceId] : []
    suppressionWindows: suppressionWindows
  }
}

// Basic/Advanced only: standing weekly suppression of action-group notifications outside the
// committed service/working-hours window (Premium commits to 24/7 response, so it never applies
// here regardless of enableOffHoursSuppression).
module offHoursSuppression 'offHoursSuppression.bicep' = if (!isPremium && enableOffHoursSuppression) {
  name: 'deploy-offhours-suppression'
  params: {
    clusterResourceId: clusterResourceId
    // See the comment on suppressionRules above - same fix applies here (Advanced-tier log
    // alerts are scoped to the workspace, not the cluster).
    additionalScopes: isAdvancedOrPremium ? [logAnalyticsWorkspaceResourceId] : []
    activeMonitoringHoursStart: activeMonitoringHoursStart
    activeMonitoringHoursEnd: activeMonitoringHoursEnd
    activeMonitoringHoursTimeZone: activeMonitoringHoursTimeZone
  }
}

output actionGroupId string = actionGroup.outputs.actionGroupId
output deployedTier string = serviceTier
