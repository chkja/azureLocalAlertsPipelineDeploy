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

@description('Include Network In/Out throughput alerts (Advanced/Premium only - defaults are very high and less universally useful than the other capacity metrics).')
param includeNetworkMetrics bool = false

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

@description('Available memory (bytes) below which an alert fires. This is the Microsoft-recommended "Available Memory Bytes" alert (metric "Memory\\Available Bytes"), distinct from the percentage-based memoryThresholdPercent alert above - both are deployed. Microsoft\'s documented default is "less than 1 GB"; default here is 1 GiB (1073741824).')
param memoryAvailableBytesThreshold int = 1073741824

@description('Volume read latency (seconds, as a numeric string so a sub-1 value can be expressed - Bicep int params cannot hold decimals) above which an alert fires. Metric "Cluster CSVFS\\Avg. sec/Read" is reported in seconds; Microsoft\'s documented recommended default is "greater than 500 ms" = 0.5 seconds.')
param volumeLatencyReadThresholdSeconds string = '0.5'

@description('Volume write latency (seconds, numeric string) above which an alert fires. Metric "Cluster CSVFS\\Avg. sec/Write"; Microsoft\'s documented recommended default is "greater than 500 ms" = 0.5 seconds.')
param volumeLatencyWriteThresholdSeconds string = '0.5'

@description('Inbound network throughput (bytes/sec) above which an alert fires. Metric "Network Adapter\\Bytes Received/sec"; Microsoft\'s documented recommended default is "greater than 500 GB/s" = 500,000,000,000 bytes/sec. Note this default is very high for most clusters - tune per environment/NIC speed.')
param networkInThresholdBytesPerSecond int = 500000000000

@description('Outbound network throughput (bytes/sec) above which an alert fires. Metric "Network Adapter\\Bytes Sent/sec"; Microsoft\'s documented recommended default is "greater than 200 GB/s" = 200,000,000,000 bytes/sec. Note this default is very high for most clusters - tune per environment/NIC speed.')
param networkOutThresholdBytesPerSecond int = 200000000000

@description('Whether alerts auto-resolve when the condition clears.')
param autoMitigate bool = true

var clusterName = last(split(clusterResourceId, '/'))

// ---------------------------------------------------------------------------
// Basic + Advanced + Premium: baseline cluster health / storage degradation
// ---------------------------------------------------------------------------
resource storageDegradedAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'inma-${clusterName}-storage-degraded'
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
  name: 'inma-${clusterName}-cpu-high'
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
  name: 'inma-${clusterName}-memory-high'
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
  name: 'inma-${clusterName}-storage-capacity-low'
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

// ---------------------------------------------------------------------------
// Advanced + Premium only: Microsoft's officially documented "recommended alert rules"
// for Azure Local (see https://learn.microsoft.com/azure/azure-local/manage/set-up-recommended-alert-rules).
// These 4 alerts (available-memory-bytes, volume-latency read/write, network in/out) round out
// the full recommended set alongside the existing Percentage CPU alert above. Evaluated as
// cluster-wide aggregates (no dimension splitting), matching Microsoft's out-of-the-box defaults.
// ---------------------------------------------------------------------------
resource memoryAvailableBytesAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (includeCapacityMetrics) {
  name: 'inma-${clusterName}-memory-available-bytes-low'
  location: location
  properties: {
    description: 'Fires when available memory drops below ${memoryAvailableBytesThreshold} bytes for the evaluation window. Microsoft-recommended alert (metric "Memory\\Available Bytes"), complementary to the percentage-based memory alert.'
    severity: severityCapacity
    enabled: true
    scopes: [
      clusterResourceId
    ]
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    autoMitigate: autoMitigate
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'LowAvailableMemoryBytes'
          metricName: 'Memory\\Available Bytes'
          metricNamespace: 'Microsoft.AzureStackHCI/clusters'
          operator: 'LessThan'
          threshold: memoryAvailableBytesThreshold
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

resource volumeLatencyReadAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (includeCapacityMetrics) {
  name: 'inma-${clusterName}-volume-latency-read-high'
  location: location
  properties: {
    description: 'Fires when average volume read latency exceeds ${volumeLatencyReadThresholdSeconds}s for the evaluation window. Microsoft-recommended alert (metric "Cluster CSVFS\\Avg. sec/Read"; documented default: 500 ms).'
    severity: severityCapacity
    enabled: true
    scopes: [
      clusterResourceId
    ]
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    autoMitigate: autoMitigate
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighVolumeLatencyRead'
          metricName: 'Cluster CSVFS\\Avg. sec/Read'
          metricNamespace: 'Microsoft.AzureStackHCI/clusters'
          operator: 'GreaterThan'
          threshold: json(volumeLatencyReadThresholdSeconds)
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

resource volumeLatencyWriteAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (includeCapacityMetrics) {
  name: 'inma-${clusterName}-volume-latency-write-high'
  location: location
  properties: {
    description: 'Fires when average volume write latency exceeds ${volumeLatencyWriteThresholdSeconds}s for the evaluation window. Microsoft-recommended alert (metric "Cluster CSVFS\\Avg. sec/Write"; documented default: 500 ms).'
    severity: severityCapacity
    enabled: true
    scopes: [
      clusterResourceId
    ]
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    autoMitigate: autoMitigate
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighVolumeLatencyWrite'
          metricName: 'Cluster CSVFS\\Avg. sec/Write'
          metricNamespace: 'Microsoft.AzureStackHCI/clusters'
          operator: 'GreaterThan'
          threshold: json(volumeLatencyWriteThresholdSeconds)
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

resource networkInAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (includeNetworkMetrics) {
  name: 'inma-${clusterName}-network-in-high'
  location: location
  properties: {
    description: 'Fires when inbound network throughput exceeds ${networkInThresholdBytesPerSecond} bytes/sec for the evaluation window. Microsoft-recommended alert (metric "Network Adapter\\Bytes Received/sec"; documented default: 500 GB/s).'
    severity: severityCapacity
    enabled: true
    scopes: [
      clusterResourceId
    ]
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    autoMitigate: autoMitigate
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighNetworkIn'
          metricName: 'Network Adapter\\Bytes Received/sec'
          metricNamespace: 'Microsoft.AzureStackHCI/clusters'
          operator: 'GreaterThan'
          threshold: networkInThresholdBytesPerSecond
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

resource networkOutAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (includeNetworkMetrics) {
  name: 'inma-${clusterName}-network-out-high'
  location: location
  properties: {
    description: 'Fires when outbound network throughput exceeds ${networkOutThresholdBytesPerSecond} bytes/sec for the evaluation window. Microsoft-recommended alert (metric "Network Adapter\\Bytes Sent/sec"; documented default: 200 GB/s).'
    severity: severityCapacity
    enabled: true
    scopes: [
      clusterResourceId
    ]
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    autoMitigate: autoMitigate
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighNetworkOut'
          metricName: 'Network Adapter\\Bytes Sent/sec'
          metricNamespace: 'Microsoft.AzureStackHCI/clusters'
          operator: 'GreaterThan'
          threshold: networkOutThresholdBytesPerSecond
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

output storageDegradedAlertId string = storageDegradedAlert.id
output cpuAlertId string = includeCapacityMetrics ? cpuAlert.id : ''
output memoryAlertId string = includeCapacityMetrics ? memoryAlert.id : ''
output storageCapacityAlertId string = includeCapacityMetrics ? storageCapacityAlert.id : ''
output memoryAvailableBytesAlertId string = includeCapacityMetrics ? memoryAvailableBytesAlert.id : ''
output volumeLatencyReadAlertId string = includeCapacityMetrics ? volumeLatencyReadAlert.id : ''
output volumeLatencyWriteAlertId string = includeCapacityMetrics ? volumeLatencyWriteAlert.id : ''
output networkInAlertId string = includeNetworkMetrics ? networkInAlert.id : ''
output networkOutAlertId string = includeNetworkMetrics ? networkOutAlert.id : ''
