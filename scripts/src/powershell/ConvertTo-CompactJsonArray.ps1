function ConvertTo-CompactJsonArray {
    <#
        Serializes $Items (already normalized to an array by the caller, e.g. via @(...)) to a
        compact single-line JSON array string, including the correct "[]" for an empty array.
        Deliberately uses -InputObject (not the pipeline) and omits -AsArray: piping an empty
        array to ConvertTo-Json never invokes its process block (zero objects to enumerate), so
        it silently returns $null instead of "[]" - and combining -InputObject with -AsArray on a
        *non-empty* array double-wraps the result (e.g. "[[{...}]]"). Passing the array directly
        via -InputObject with neither pipe nor -AsArray handles empty/one/many items correctly.
    #>
    param([array]$Items)
    return (ConvertTo-Json -InputObject $Items -Compress)
}
