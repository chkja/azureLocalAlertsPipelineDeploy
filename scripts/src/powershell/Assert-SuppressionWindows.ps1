function Assert-SuppressionWindows {
    <#
        Validates -SuppressionWindowsJson up front (fails fast with a clear message instead of a
        deep ARM/discriminated-union error), then returns the parsed array. Mirrors the shape
        documented in bicep/modules/suppressionRules.bicep.

        Depends on Assert-JsonArray being dot-sourced/available in the caller's scope.
    #>
    param([string]$Json)

    Assert-JsonArray -Value $Json -ParamName 'SuppressionWindowsJson'
    $windows = @($Json | ConvertFrom-Json)

    foreach ($w in $windows) {
        foreach ($required in @('name', 'effectiveFrom', 'effectiveUntil', 'recurrenceType')) {
            if (-not ($w.PSObject.Properties.Name -contains $required) -or [string]::IsNullOrWhiteSpace($w.$required)) {
                throw "SuppressionWindowsJson entry is missing required property '$required': $($w | ConvertTo-Json -Compress)"
            }
        }
        if ($w.recurrenceType -notin @('None', 'Daily', 'Weekly', 'Monthly')) {
            throw "SuppressionWindowsJson entry '$($w.name)' has invalid recurrenceType '$($w.recurrenceType)' - must be None, Daily, Weekly, or Monthly."
        }
        if ($w.recurrenceType -ne 'None') {
            foreach ($required in @('startTime', 'endTime')) {
                if (-not ($w.PSObject.Properties.Name -contains $required) -or [string]::IsNullOrWhiteSpace($w.$required)) {
                    throw "SuppressionWindowsJson entry '$($w.name)' with recurrenceType '$($w.recurrenceType)' requires '$required' (format 'HH:mm:ss')."
                }
            }
        }
        if ($w.recurrenceType -eq 'Weekly' -and (-not ($w.PSObject.Properties.Name -contains 'daysOfWeek') -or @($w.daysOfWeek).Count -eq 0)) {
            throw "SuppressionWindowsJson entry '$($w.name)' with recurrenceType 'Weekly' requires a non-empty 'daysOfWeek' array."
        }
        if ($w.recurrenceType -eq 'Monthly' -and (-not ($w.PSObject.Properties.Name -contains 'daysOfMonth') -or @($w.daysOfMonth).Count -eq 0)) {
            throw "SuppressionWindowsJson entry '$($w.name)' with recurrenceType 'Monthly' requires a non-empty 'daysOfMonth' array."
        }
    }

    return $windows
}
