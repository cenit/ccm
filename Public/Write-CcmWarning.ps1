function Write-CcmWarning {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ("[{0:HH:mm:ss}] [WARN ] {1}" -f (Get-Date), $Message) -ForegroundColor Yellow
}
