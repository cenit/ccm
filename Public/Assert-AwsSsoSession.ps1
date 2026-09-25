function Assert-AwsSsoSession {
    <#
    .SYNOPSIS
        Validates that the current AWS credentials (typically SSO-based) are valid.
        If they are expired or missing, prints clear instructions asking the user
        to run 'aws sso login' and then exits with code 1.
    .PARAMETER AwsRegion
        AWS region passed to aws sts get-caller-identity. Default: "eu-central-1"
    .PARAMETER StopTranscript
        If $true, calls Stop-Transcript before exiting on failure.
    .OUTPUTS
        Returns the parsed JSON identity object on success.
    #>
    [CmdletBinding()]
    param(
        [string]$AwsRegion = "eu-central-1",
        [switch]$StopTranscript
    )

    Write-Host "Validating AWS credentials..." -ForegroundColor Yellow
    # The module sets $ErrorActionPreference = 'Stop'; on Windows PowerShell 5.1
    # that turns native stderr merged via 2>&1 into a terminating error, which
    # would throw here instead of reaching the friendly guidance below.
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $awsIdentity = aws sts get-caller-identity --region $AwsRegion 2>&1
    $ErrorActionPreference = $prevEAP
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Red
        Write-Host "AWS credentials are invalid or expired!" -ForegroundColor Red
        Write-Host "========================================" -ForegroundColor Red
        Write-Host ""
        Write-Host "Please run the following command to refresh your SSO session:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "    aws sso login" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "After completing the SSO login, run this script again." -ForegroundColor Yellow
        Write-Host ""
        if ($StopTranscript) { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null }
        exit 1
    }
    Write-Host "AWS credentials validated successfully" -ForegroundColor Green
    Write-Host ""
    return $awsIdentity
}
