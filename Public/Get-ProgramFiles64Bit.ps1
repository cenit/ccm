function Get-ProgramFiles64Bit {
    [CmdletBinding()]
    param()
    $out = ${env:ProgramFiles}
    if ($null -eq $out) {
        Write-CcmFatalError "Could not find [Program Files 64-bit]"
    }
    return $out
}
