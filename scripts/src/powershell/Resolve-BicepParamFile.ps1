function Resolve-BicepParamFile {
    <#
        Compiles a .bicepparam file via `az bicep build-params` and returns the subset of values
        (serviceTier, resourceGroupName, location, clusterResourceId,
        logAnalyticsWorkspaceResourceId) this script needs for its own pre-flight checks (Log
        Analytics workspace existence, DCR event-log auto-extension) and deployment-stack
        naming/description. Deliberately does NOT re-validate every parameter the way ByValue
        mode does (e.g. Assert-JsonArray on email/webhook receivers) - the .bicepparam file
        itself is passed straight through to `az stack sub create/validate --parameters`
        unchanged, so any other malformed value surfaces as a Bicep/ARM error from that command
        instead.
    #>
    param([string]$Path)

    if (-not (Test-Path -Path $Path)) {
        throw "BicepParamFile '$Path' does not exist."
    }
    $resolvedPath = (Resolve-Path -Path $Path).Path

    Write-Host "==> Compiling Bicep parameter file: $resolvedPath" -ForegroundColor Cyan
    $buildOutput = az bicep build-params --file $resolvedPath --stdout 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($buildOutput)) {
        throw "Failed to compile Bicep parameter file '$resolvedPath' (az bicep build-params). Run 'az bicep build-params --file $resolvedPath' directly to see the underlying error."
    }

    $compiledParametersJson = ($buildOutput | ConvertFrom-Json).parametersJson
    $compiledParameters = ($compiledParametersJson | ConvertFrom-Json).parameters

    function Get-CompiledParamValue {
        param($Parameters, [string]$Name, [string]$Default = '')
        if ($Parameters.PSObject.Properties.Name -contains $Name) {
            return $Parameters.$Name.value
        }
        return $Default
    }

    $result = [pscustomobject]@{
        ResolvedPath                    = $resolvedPath
        ServiceTier                     = Get-CompiledParamValue -Parameters $compiledParameters -Name 'serviceTier'
        ResourceGroupName               = Get-CompiledParamValue -Parameters $compiledParameters -Name 'resourceGroupName'
        Location                        = Get-CompiledParamValue -Parameters $compiledParameters -Name 'location' -Default 'westeurope'
        ClusterResourceId               = Get-CompiledParamValue -Parameters $compiledParameters -Name 'clusterResourceId'
        LogAnalyticsWorkspaceResourceId = Get-CompiledParamValue -Parameters $compiledParameters -Name 'logAnalyticsWorkspaceResourceId'
    }

    if ($result.ServiceTier -notin @('Basic', 'Advanced', 'Premium')) {
        throw "Bicep parameter file '$resolvedPath' has an invalid or missing 'serviceTier' value ('$($result.ServiceTier)') - must be Basic, Advanced, or Premium."
    }
    if ([string]::IsNullOrWhiteSpace($result.ResourceGroupName)) {
        throw "Bicep parameter file '$resolvedPath' is missing a value for 'resourceGroupName'."
    }
    if ([string]::IsNullOrWhiteSpace($result.ClusterResourceId)) {
        throw "Bicep parameter file '$resolvedPath' is missing a value for 'clusterResourceId'."
    }

    return $result
}
