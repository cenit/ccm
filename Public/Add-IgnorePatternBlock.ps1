function Add-IgnorePatternBlock {
    <#
    .SYNOPSIS
      Idempotently maintains a sentinel-delimited block of ignore patterns
      inside a .gitignore/.dockerignore-style file.
    .DESCRIPTION
      Writes (or updates) a block of the form:
        # >>> <BlockId> (managed by <ManagedBy> - do not edit between sentinels) >>>
        <pattern 1>
        <pattern 2>
        # <<< <BlockId> (managed) <<<
      Re-running with the same BlockId only adds patterns that are not
      already present between the sentinels - the whole operation is a
      no-op (returns $false) when every requested pattern is already there.
    .PARAMETER Pattern
      One or more ignore patterns to ensure are present inside the block.
      Accepts a single string (wrapped into a one-element array) so every
      existing single-pattern caller keeps working unchanged, or an array
      to add several patterns in one call/one file rewrite instead of
      invoking this function once per pattern.
    .PARAMETER ManagedBy
      The name embedded in the start sentinel ("managed by <ManagedBy>").
      Defaults to 'Initialize-CcmLogging', the original and, for a long
      time, only caller - every block already written into a consumer's
      .gitignore/.dockerignore under BlockId 'CCM logs' has that exact text
      baked in. Do NOT change the default: doing so would stop this
      function from recognising those pre-existing blocks (the sentinel
      match is a literal string compare), causing a duplicate block to be
      appended instead of the existing one being updated in place. Callers
      introducing a new BlockId should pass their own name here so the
      sentinel accurately describes what wrote it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Pattern,
        [Parameter(Mandatory)][string]$BlockId,
        [bool]$CreateIfMissing = $false,
        [string]$ManagedBy = 'Initialize-CcmLogging'
    )

    # Drop null/empty entries defensively; a caller passing an empty array or
    # all-blank strings should be a no-op, not a block with a blank line in it.
    $patterns = @($Pattern | Where-Object { $_ })
    if ($patterns.Count -eq 0) { return $false }

    $startSentinel = "# >>> $BlockId (managed by $ManagedBy - do not edit between sentinels) >>>"
    $endSentinel   = "# <<< $BlockId (managed) <<<"

    if (-not (Test-Path -LiteralPath $Path)) {
        if (-not $CreateIfMissing) { return $false }
        $newline = [Environment]::NewLine
        $block = "$startSentinel$newline$($patterns -join $newline)$newline$endSentinel$newline"
        [IO.File]::WriteAllText($Path, $block)
        return $true
    }

    $raw = [IO.File]::ReadAllText($Path)
    $newline = if ($raw -match "`r`n") { "`r`n" } elseif ($raw -match "`n") { "`n" } else { [Environment]::NewLine }
    $lines = $raw -split "`r?`n"

    $startIdx = -1
    $endIdx   = -1
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -eq $startSentinel) { $startIdx = $i }
        elseif ($lines[$i] -eq $endSentinel) { $endIdx = $i }
    }

    if ($startIdx -ge 0 -and $endIdx -lt 0) {
        # Start sentinel found, end sentinel missing - salvage patterns and rewrite
        $salvaged = New-Object 'System.Collections.Generic.List[string]'
        for ($j = $startIdx + 1; $j -lt $lines.Length; $j++) {
            $line = $lines[$j].Trim()
            if ($line -eq '' -or $line.StartsWith('#')) { break }
            if (-not $salvaged.Contains($line)) { [void]$salvaged.Add($line) }
        }
        foreach ($p in $patterns) {
            if (-not $salvaged.Contains($p)) { [void]$salvaged.Add($p) }
        }
        $before = if ($startIdx -gt 0) { $lines[0..($startIdx - 1)] } else { @() }
        $blockLines = @($startSentinel) + $salvaged + @($endSentinel)
        $newRaw = (($before + $blockLines) -join $newline) + $newline
        [IO.File]::WriteAllText($Path, $newRaw)
        return $true
    }

    if ($startIdx -ge 0 -and $endIdx -gt $startIdx) {
        # Well-formed block exists; add whichever requested patterns aren't inside yet
        $insideLines = if ($endIdx - 1 -ge $startIdx + 1) { $lines[($startIdx + 1)..($endIdx - 1)] } else { @() }
        $missing = @($patterns | Where-Object { $insideLines -notcontains $_ })
        if ($missing.Count -eq 0) { return $false }
        $before = $lines[0..$startIdx]
        $inside = @($insideLines) + $missing
        $after  = $lines[$endIdx..($lines.Length - 1)]
        $newRaw = ($before + $inside + $after) -join $newline
        [IO.File]::WriteAllText($Path, $newRaw)
        return $true
    }

    # No block - append a fresh block at end
    $rawTrimmed = $raw -replace '\s+$', ''
    $separator = if ($rawTrimmed -ne '') { $newline + $newline } else { '' }
    $block = "$separator$startSentinel$newline$($patterns -join $newline)$newline$endSentinel$newline"
    [IO.File]::WriteAllText($Path, $rawTrimmed + $block)
    return $true
}
