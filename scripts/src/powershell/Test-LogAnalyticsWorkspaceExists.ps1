function Test-LogAnalyticsWorkspaceExists {
    <#
        Confirms the Log Analytics workspace referenced by -LogAnalyticsWorkspaceResourceId
        actually exists (and is reachable with the current credentials) before deploying any
        log-based alert rules against it. A scheduledQueryRules resource deploys successfully
        even if its target workspace ID is wrong or doesn't exist - it just silently never
        retrieves data, so this check turns that into a fast, clear failure instead of a
        "why are my alerts never firing" support ticket later.
    #>
    param([string]$WorkspaceResourceId)

    Write-Host "==> Verifying Log Analytics workspace exists: $WorkspaceResourceId" -ForegroundColor Cyan

    if ($WorkspaceResourceId -notmatch '(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$') {
        throw "LogAnalyticsWorkspaceResourceId '$WorkspaceResourceId' is not a valid Log Analytics workspace resource ID (expected .../providers/Microsoft.OperationalInsights/workspaces/<name>)."
    }

    $workspaceJson = az resource show --ids $WorkspaceResourceId -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($workspaceJson)) {
        throw "Log Analytics workspace '$WorkspaceResourceId' was not found (or is not accessible with the current credentials). Advanced/Premium log-based alert rules would deploy successfully but never retrieve data against a missing workspace - fix -LogAnalyticsWorkspaceResourceId before retrying."
    }

    $workspace = $workspaceJson | ConvertFrom-Json
    if ($workspace.properties.provisioningState -ne 'Succeeded') {
        Write-Warning "Log Analytics workspace '$WorkspaceResourceId' exists but provisioningState is '$($workspace.properties.provisioningState)' (expected 'Succeeded')."
    }

    Write-Host "==> Log Analytics workspace confirmed (provisioningState: $($workspace.properties.provisioningState))." -ForegroundColor Green
}
