function Write-CcmInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ("[{0:HH:mm:ss}] [INFO ] {1}" -f (Get-Date), $Message) -ForegroundColor Cyan
}
