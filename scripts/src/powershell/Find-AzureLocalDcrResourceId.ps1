function Find-AzureLocalDcrResourceId {
    <#
        Auto-discovery of the Data Collection Rule associated with this cluster's nodes: lists
        Microsoft.HybridCompute/machines in the cluster's resource group, and returns the
        DataCollectionRuleId from the first node's DCR association.

        Throws if no DCR can be identified, instead of returning $null - a deployment that
        modifies a DCR's event collection to make Advanced/Premium log alerts work must be able
        to trust that update actually happened; silently deploying alert rules that will never
        receive data is worse than stopping the deployment with a clear, actionable error.
        Callers wanting to skip DCR handling entirely (e.g. for a quick -WhatIf/test run) should
        use -SkipDcrUpdate on Deploy-AzureLocalAlerts.ps1 instead of relying on this function to
        fail soft.
    #>
    param([string]$ClusterResourceId)

    if ($ClusterResourceId -notmatch '(?i)^/subscriptions/(?<sub>[^/]+)/resourceGroups/(?<rg>[^/]+)/providers/Microsoft\.AzureStackHCI/clusters/[^/]+$') {
        throw "Could not parse resource group from ClusterResourceId '$ClusterResourceId' - cannot auto-discover the Data Collection Rule. Supply -DcrResourceId explicitly, or -SkipDcrUpdate to bypass DCR handling entirely."
    }
    $clusterRg = $Matches['rg']

    $machinesJson = az resource list -g $clusterRg --resource-type 'Microsoft.HybridCompute/machines' -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($machinesJson)) {
        throw "Failed to list Microsoft.HybridCompute/machines resources in resource group '$clusterRg' - cannot auto-discover the Data Collection Rule. Supply -DcrResourceId explicitly, or -SkipDcrUpdate to bypass DCR handling entirely."
    }
    $machines = @($machinesJson | ConvertFrom-Json)
    if ($machines.Count -eq 0) {
        throw "No Arc-enabled node (Microsoft.HybridCompute/machines) found in resource group '$clusterRg' - cannot auto-discover the Data Collection Rule, so Advanced/Premium log-based alerts cannot be trusted to receive data. Supply -DcrResourceId explicitly, or -SkipDcrUpdate to bypass DCR handling entirely (not recommended for a real deployment)."
    }

    foreach ($machine in $machines) {
        $associationsJson = az monitor data-collection rule association list --resource $machine.id -o json 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($associationsJson)) {
            continue
        }
        $associations = @($associationsJson | ConvertFrom-Json)
        $dcrId = $associations | Where-Object { $_.dataCollectionRuleId } | Select-Object -First 1 -ExpandProperty dataCollectionRuleId
        if ($dcrId) {
            Write-Host "==> Auto-discovered DCR '$dcrId' via node '$($machine.name)'." -ForegroundColor Green
            return $dcrId
        }
    }

    throw "No Data Collection Rule association found on any node in resource group '$clusterRg' - cannot auto-discover the Data Collection Rule, so Advanced/Premium log-based alerts cannot be trusted to receive data. Supply -DcrResourceId explicitly, or -SkipDcrUpdate to bypass DCR handling entirely (not recommended for a real deployment)."
}

