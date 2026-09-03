// Alert Processing Rules (Microsoft.AlertsManagement/actionRules), type "Suppression".
// Available at every service tier (Basic/Advanced/Premium) so maintenance windows can quiet
// notifications WITHOUT disabling or deleting the underlying alert rules - alerts still fire
// and remain visible in the portal/API, only the action-group notifications are suppressed for
// the scheduled window. This avoids configuration drift from manually snoozing/disabling alerts
// in the portal during planned maintenance.
//
// Matching is based on the AFFECTED resource of the fired alert instance, not the location of
// the alert rule itself - so scoping to the cluster resource ID correctly suppresses metric
// alerts, log alerts, AND (Premium) the subscription-wide activity-log/Resource Health alert,
// as long as the fired alert's target resource is the cluster (or a resource in additionalScopes).
//
// Reference: https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-action-rules

@description('ARM resource ID of the Microsoft.AzureStackHCI/clusters resource these suppression rules protect. Always included in each rule\'s scopes.')
param clusterResourceId string

@description('Additional resource IDs to include in every rule\'s scopes (e.g. the resource group ID, or the subscription ID to also blanket-suppress the Premium subscription-wide Resource Health/Service Health alerts during the same window). Default: none - only the cluster itself is covered.')
param additionalScopes array = []

@description('''
Array of maintenance-window definitions. Each entry creates one Suppression alert-processing rule.
Shape per entry (see docs/service-tiers-and-alerts.md for worked examples):
{
  name: string                                   // required, unique per rule, used in the resource name (alphanumeric/dashes)
  description: string?                           // optional, defaults to a generic description
  enabled: bool?                                  // optional, default true
  effectiveFrom: string                          // required, ISO 8601 date-time WITHOUT timezone suffix, e.g. "2026-01-01T00:00:00"
  effectiveUntil: string                         // required, ISO 8601 date-time WITHOUT timezone suffix
  timeZone: string?                              // optional, Windows time zone name (e.g. "W. Europe Standard Time"), default "UTC"
  recurrenceType: "None" | "Daily" | "Weekly" | "Monthly"   // required. "None" = a single one-time window spanning effectiveFrom..effectiveUntil
  startTime: string?                             // "HH:mm:ss", required unless recurrenceType == "None"
  endTime: string?                               // "HH:mm:ss", required unless recurrenceType == "None"
  daysOfWeek: string[]?                          // required when recurrenceType == "Weekly", e.g. ["Saturday","Sunday"]
  daysOfMonth: int[]?                            // required when recurrenceType == "Monthly", e.g. [1, 15]
}
''')
param suppressionWindows array = []

var clusterName = last(split(clusterResourceId, '/'))
var ruleScopes = concat([clusterResourceId], additionalScopes)

resource suppressionRules 'Microsoft.AlertsManagement/actionRules@2021-08-08' = [for window in suppressionWindows: {
  name: 'apr-${clusterName}-${window.name}'
  location: 'global'
  properties: {
    description: window.?description ?? 'Maintenance-window suppression rule "${window.name}" for ${clusterResourceId}.'
    enabled: window.?enabled ?? true
    scopes: ruleScopes
    actions: [
      {
        actionType: 'RemoveAllActionGroups'
      }
    ]
    schedule: {
      effectiveFrom: window.effectiveFrom
      effectiveUntil: window.effectiveUntil
      timeZone: window.?timeZone ?? 'UTC'
      recurrences: window.recurrenceType == 'None' ? [] : [
        (window.recurrenceType == 'Weekly')
          ? {
              recurrenceType: 'Weekly'
              daysOfWeek: window.daysOfWeek
              startTime: window.startTime
              endTime: window.endTime
            }
          : (window.recurrenceType == 'Monthly')
              ? {
                  recurrenceType: 'Monthly'
                  daysOfMonth: window.daysOfMonth
                  startTime: window.startTime
                  endTime: window.endTime
                }
              : {
                  recurrenceType: 'Daily'
                  startTime: window.startTime
                  endTime: window.endTime
                }
      ]
    }
  }
}]

output suppressionRuleIds array = [for i in range(0, length(suppressionWindows)): suppressionRules[i].id]
