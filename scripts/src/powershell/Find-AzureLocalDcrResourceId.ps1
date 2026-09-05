function Find-AzureLocalDcrResourceId {
    <#
        Best-effort auto-discovery of the Data Collection Rule associated with this cluster's
        nodes: lists Microsoft.HybridCompute/machines in the cluster's resource group, and
        returns the DataCollectionRuleId from the first node's DCR association. Returns $null
        (with a warning) if no Arc machines or no association is found - callers must treat this
        as non-fatal.
    #>
    param([string]$ClusterResourceId)

    if ($ClusterResourceId -notmatch '(?i)^/subscriptions/(?<sub>[^/]+)/resourceGroups/(?<rg>[^/]+)/providers/Microsoft\.AzureStackHCI/clusters/[^/]+$') {
        Write-Warning "Could not parse resource group from ClusterResourceId '$ClusterResourceId' - skipping DCR auto-discovery."
        return $null
    }
    $clusterRg = $Matches['rg']

    $machinesJson = az resource list -g $clusterRg --resource-type 'Microsoft.HybridCompute/machines' -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($machinesJson)) {
        Write-Warning "No Microsoft.HybridCompute/machines resources found in resource group '$clusterRg' - skipping DCR auto-discovery."
        return $null
    }
    $machines = @($machinesJson | ConvertFrom-Json)
    if ($machines.Count -eq 0) {
        Write-Warning "No Arc-enabled node (Microsoft.HybridCompute/machines) found in resource group '$clusterRg' - skipping DCR auto-discovery."
        return $null
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

    Write-Warning "No Data Collection Rule association found on any node in resource group '$clusterRg' - skipping DCR auto-discovery."
    return $null
}
