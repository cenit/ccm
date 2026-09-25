function Get-ProgramFiles32Bit {
    [CmdletBinding()]
    param()
    $out = ${env:PROGRAMFILES(X86)}
    if ($null -eq $out) { $out = ${env:PROGRAMFILES} }
    if ($null -eq $out) {
        Write-CcmFatalError "Could not find [Program Files 32-bit]"
    }
    return $out
}
