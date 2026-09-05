function Assert-IsoDuration {
    <#
        Validates an ISO 8601 duration string (e.g. "PT1H", "PT30M", "P1D") up front, so a
        malformed -LogAlertsMuteActionsDuration fails fast with a clear message instead of a
        deep ARM error. Empty string is allowed (means "disabled").
    #>
    param([string]$Value, [string]$ParamName)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }
    if ($Value -notmatch '^P(?!$)(\d+Y)?(\d+M)?(\d+D)?(T(?=\d)(\d+H)?(\d+M)?(\d+S)?)?$') {
        throw "$ParamName '$Value' is not a valid ISO 8601 duration (e.g. 'PT1H' for 1 hour, 'PT30M' for 30 minutes)."
    }
}
