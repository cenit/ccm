function Write-CcmStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ("[{0:HH:mm:ss}] [STEP ] {1}" -f (Get-Date), $Message) -ForegroundColor Blue
}
