// Standing (permanent, recurring) Alert Processing Rule suppression covering all hours OUTSIDE
// the committed service/working-hours window for Basic and Advanced tiers. Per the service
// description, Basic alerts are only responded to "during agreed service hours" and Advanced
// alerts "during working hours" - only Premium commits to 24/7 response. Alert rules still
// evaluate around the clock in every tier (so nothing is ever silently missed and the full
// history remains visible/queryable), but action-group notifications (email/webhook/on-call
// paging) for Basic/Advanced are suppressed outside the agreed window, so nobody is paged for
// an SLA the customer isn't paying for.
//
// This is intentionally a SEPARATE construct from `suppressionRules.bicep` (ad hoc maintenance
// windows): this one is a standing weekly schedule derived from simple start/end/timezone
// parameters, not something an operator hand-authors as a one-off JSON window.
//
// Implementation note: Microsoft.AlertsManagement/actionRules Weekly recurrences DO support
// crossing midnight (startTime > endTime is a valid, documented pattern - the window then spans
// from startTime on the matched day(s) through endTime on the FOLLOWING calendar day). That
// still only covers weekday-evening -> next-weekday-morning; the two full non-working days
// (assumed Saturday/Sunday) and the small gap from Sunday midnight to Monday's service-hours
// start need their own explicit entries. See docs/service-tiers-and-alerts.md for the full
// week-coverage walkthrough.
//
// Reference: https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-action-rules

@description('ARM resource ID of the Microsoft.AzureStackHCI/clusters resource this suppression schedule protects. Always included in every rule\'s scopes.')
param clusterResourceId string

@description('Additional resource IDs to include in every rule\'s scopes (e.g. the subscription ID, to also cover the Premium-only subscription-wide Resource/Service Health alerts - not normally needed since this module is not used for Premium).')
param additionalScopes array = []

@description('Daily start of the committed service/working-hours window, "HH:mm:ss", assumed Monday-Friday. Notifications are suppressed before this time and after serviceHoursEnd.')
param serviceHoursStart string = '07:00:00'

@description('Daily end of the committed service/working-hours window, "HH:mm:ss".')
param serviceHoursEnd string = '17:00:00'

@description('Windows time zone name the service-hours window is evaluated in (e.g. "Romance Standard Time" for Copenhagen).')
param serviceHoursTimeZone string = 'Romance Standard Time'

@description('ISO 8601 date-time (no timezone suffix) from which this standing weekly schedule is effective.')
param effectiveFrom string = '2026-01-01T00:00:00'

@description('ISO 8601 date-time (no timezone suffix) until which this standing weekly schedule is effective. Defaults ~10 years out to act as a permanent schedule while still satisfying the required-property schema; extend/renew as needed.')
param effectiveUntil string = '2036-01-01T00:00:00'

var clusterName = last(split(clusterResourceId, '/'))
var ruleScopes = concat([clusterResourceId], additionalScopes)
var commonSchedule = {
  effectiveFrom: effectiveFrom
  effectiveUntil: effectiveUntil
  timeZone: serviceHoursTimeZone
}

// 1. Every weekday evening through the following morning's service-hours start (crosses
//    midnight). Covers Mon 17:00->Tue 07:00 ... Fri 17:00->Sat 07:00 (using the default hours).
resource weekdayEveningToMorning 'Microsoft.AlertsManagement/actionRules@2021-08-08' = {
  name: 'suppress-${clusterName}-offhours-weekday-evening'
  location: 'global'
  properties: {
    description: 'Standing off-hours suppression: every weekday evening (after ${serviceHoursEnd}) through the following morning (${serviceHoursStart}).'
    enabled: true
    scopes: ruleScopes
    actions: [
      {
        actionType: 'RemoveAllActionGroups'
      }
    ]
    schedule: union(commonSchedule, {
      recurrences: [
        {
          recurrenceType: 'Weekly'
          daysOfWeek: [
            'Monday'
            'Tuesday'
            'Wednesday'
            'Thursday'
            'Friday'
          ]
          startTime: serviceHoursEnd
          endTime: serviceHoursStart
        }
      ]
    })
  }
}

// 2. Monday early morning, before service-hours start - not covered by #1 because Sunday is not
//    in its daysOfWeek list, so the crossing-midnight window never fires into Monday.
resource mondayEarlyMorning 'Microsoft.AlertsManagement/actionRules@2021-08-08' = {
  name: 'suppress-${clusterName}-offhours-monday-morning'
  location: 'global'
  properties: {
    description: 'Standing off-hours suppression: Monday from midnight until service-hours start (${serviceHoursStart}).'
    enabled: true
    scopes: ruleScopes
    actions: [
      {
        actionType: 'RemoveAllActionGroups'
      }
    ]
    schedule: union(commonSchedule, {
      recurrences: [
        {
          recurrenceType: 'Weekly'
          daysOfWeek: [
            'Monday'
          ]
          startTime: '00:00:00'
          endTime: serviceHoursStart
        }
      ]
    })
  }
}

// 3. Saturday, all day.
resource saturdayAllDay 'Microsoft.AlertsManagement/actionRules@2021-08-08' = {
  name: 'suppress-${clusterName}-offhours-saturday'
  location: 'global'
  properties: {
    description: 'Standing off-hours suppression: all day Saturday (non-working day).'
    enabled: true
    scopes: ruleScopes
    actions: [
      {
        actionType: 'RemoveAllActionGroups'
      }
    ]
    schedule: union(commonSchedule, {
      recurrences: [
        {
          recurrenceType: 'Weekly'
          daysOfWeek: [
            'Saturday'
          ]
          startTime: '00:00:00'
          endTime: '23:59:59'
        }
      ]
    })
  }
}

// 4. Sunday, all day.
resource sundayAllDay 'Microsoft.AlertsManagement/actionRules@2021-08-08' = {
  name: 'suppress-${clusterName}-offhours-sunday'
  location: 'global'
  properties: {
    description: 'Standing off-hours suppression: all day Sunday (non-working day).'
    enabled: true
    scopes: ruleScopes
    actions: [
      {
        actionType: 'RemoveAllActionGroups'
      }
    ]
    schedule: union(commonSchedule, {
      recurrences: [
        {
          recurrenceType: 'Weekly'
          daysOfWeek: [
            'Sunday'
          ]
          startTime: '00:00:00'
          endTime: '23:59:59'
        }
      ]
    })
  }
}

output ruleIds array = [
  weekdayEveningToMorning.id
  mondayEarlyMorning.id
  saturdayAllDay.id
  sundayAllDay.id
]
