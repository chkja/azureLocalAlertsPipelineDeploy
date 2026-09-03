// Metric alerts against the Microsoft.AzureStackHCI/clusters platform metrics namespace.
// These metrics are emitted by the cluster resource itself and do NOT require Log Analytics /
// Insights log collection to be enabled - which is why they are available even at Basic tier.
//
// Reference: https://learn.microsoft.com/en-us/azure/azure-monitor/reference/supported-metrics/microsoft-azurestackhci-clusters-metrics

@description('Resource ID of the Microsoft.AzureStackHCI/clusters resource to monitor.')
param clusterResourceId string

@description('Azure region for the alert rule metadata (must match, or be a region that supports, the target resource region).')
param location string = 'global'

@description('Action Group resource ID to notify.')
param actionGroupId string

@description('Include CPU / Memory capacity alerts. Basic = false (health-only). Advanced/Premium = true.')
param includeCapacityMetrics bool = false

@description('Evaluation frequency, ISO 8601 duration, e.g. PT5M.')
param evaluationFrequency string = 'PT5M'

@description('Window size, ISO 8601 duration, e.g. PT15M.')
param windowSize string = 'PT15M'

@description('Severity for the baseline cluster health alert (0=Critical .. 4=Verbose).')
param severityHealth int = 1

@description('Severity for capacity alerts.')
param severityCapacity int = 2

@description('CPU usage percent threshold that triggers an alert.')
param cpuThresholdPercent int = 85

@description('Memory usage percent threshold that triggers an alert.')
param memoryThresholdPercent int = 85

@description('Available volume space (bytes) below which a storage-capacity alert fires. Confirmed on a live cluster via the "Volume Size Available" platform metric (REST name "volume size available"). This is an absolute-bytes threshold, not a percentage - Azure Monitor metric alerts cannot compute a ratio between two metrics (Available/Total), so tune this per environment using the actual "Volume Size Total" values for your volumes (see scripts/Get-AzureLocalAlertExploration.ps1, section 1/2). Default: 200 GiB.')
param storageFreeBytesThreshold int = 214748364800

@description('Whether alerts auto-resolve when the condition clears.')
param autoMitigate bool = true

var clusterName = last(split(clusterResourceId, '/'))

// ---------------------------------------------------------------------------
// Basic + Advanced + Premium: baseline cluster health / storage degradation
// ---------------------------------------------------------------------------
resource storageDegradedAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${clusterName}-storage-degraded'
  location: location
  properties: {
    description: 'Fires when one or more physical drives in the storage pool are missing or have failed. Baseline cluster health signal - available in all service tiers.'
    severity: severityHealth
    enabled: true
    scopes: [
      clusterResourceId
    ]
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    targetResourceType: 'Microsoft.AzureStackHCI/clusters'
    autoMitigate: autoMitigate
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'StorageDegraded'
          metricName: 'Cluster Node Storage Degraded'
          metricNamespace: 'Microsoft.AzureStackHCI/clusters'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Maximum'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Advanced + Premium only: capacity monitoring (CPU / Memory)
// ---------------------------------------------------------------------------
resource cpuAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (includeCapacityMetrics) {
  name: 'alert-${clusterName}-cpu-high'
  location: location
  properties: {
    description: 'Fires when average cluster node CPU usage exceeds ${cpuThresholdPercent}% for the evaluation window.'
    severity: severityCapacity
    enabled: true
    scopes: [
      clusterResourceId
    ]
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    targetResourceType: 'Microsoft.AzureStackHCI/clusters'
    autoMitigate: autoMitigate
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighCpu'
          metricName: 'Hyper-V Hypervisor Logical Processor\\% Total Run Time'
          metricNamespace: 'Microsoft.AzureStackHCI/clusters'
          operator: 'GreaterThan'
          threshold: cpuThresholdPercent
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}

resource memoryAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (includeCapacityMetrics) {
  name: 'alert-${clusterName}-memory-high'
  location: location
  properties: {
    description: 'Fires when average cluster node memory usage exceeds ${memoryThresholdPercent}% for the evaluation window.'
    severity: severityCapacity
    enabled: true
    scopes: [
      clusterResourceId
    ]
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    targetResourceType: 'Microsoft.AzureStackHCI/clusters'
    autoMitigate: autoMitigate
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighMemory'
          metricName: 'ClusterNode Memory Usage'
          metricNamespace: 'Microsoft.AzureStackHCI/clusters'
          operator: 'GreaterThan'
          threshold: memoryThresholdPercent
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Advanced + Premium only: storage capacity (per-volume, via dimension splitting on LUN)
// Confirmed live on a real cluster: "Volume Size Available" (REST name "volume size available")
// is exposed as a platform metric with LUN as a dimension, so this alert fires independently
// per volume rather than only on a cluster-wide aggregate.
// ---------------------------------------------------------------------------
resource storageCapacityAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (includeCapacityMetrics) {
  name: 'alert-${clusterName}-storage-capacity-low'
  location: location
  properties: {
    description: 'Fires when a volume\'s available space drops below ${storageFreeBytesThreshold} bytes for the evaluation window. Threshold is absolute bytes - see param description for why (no ratio metric is available).'
    severity: severityCapacity
    enabled: true
    scopes: [
      clusterResourceId
    ]
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    targetResourceType: 'Microsoft.AzureStackHCI/clusters'
    autoMitigate: autoMitigate
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'LowStorageCapacity'
          metricName: 'volume size available'
          metricNamespace: 'Microsoft.AzureStackHCI/clusters'
          operator: 'LessThan'
          threshold: storageFreeBytesThreshold
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
          dimensions: [
            {
              name: 'LUN'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}

output storageDegradedAlertId string = storageDegradedAlert.id
output cpuAlertId string = includeCapacityMetrics ? cpuAlert.id : ''
output memoryAlertId string = includeCapacityMetrics ? memoryAlert.id : ''
output storageCapacityAlertId string = includeCapacityMetrics ? storageCapacityAlert.id : ''
