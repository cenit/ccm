function Write-CcmSuccess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ("[{0:HH:mm:ss}] [OK   ] {1}" -f (Get-Date), $Message) -ForegroundColor Green
}
