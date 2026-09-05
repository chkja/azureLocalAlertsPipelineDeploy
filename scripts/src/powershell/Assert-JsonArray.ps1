function Assert-JsonArray {
    <#
        Validates that $Value is JSON-array syntax (starts with '[').
        NOTE: deliberately does NOT type-check the *parsed* result - PowerShell's
        ConvertFrom-Json collapses a JSON array containing exactly one element into a bare
        PSCustomObject (not IEnumerable), so a naive "-isnot [System.Collections.IEnumerable]"
        check incorrectly rejects perfectly valid single-item arrays like
        '[{"name":"ops","emailAddress":"ops@example.com"}]'. All call sites already wrap the
        parsed value in @(...) to re-normalize it back to an array, so only the JSON *shape*
        needs validating here.
    #>
    param([string]$Value, [string]$ParamName)
    try {
        $null = $Value | ConvertFrom-Json
    }
    catch {
        throw "Parameter '$ParamName' is not valid JSON: $Value"
    }
    if ($Value.Trim() -notmatch '^\[.*\]$') {
        throw "Parameter '$ParamName' must be a JSON array, e.g. []"
    }
}
