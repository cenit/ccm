function Write-CcmError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ("[{0:HH:mm:ss}] [ERROR] {1}" -f (Get-Date), $Message) -ForegroundColor Red
}
