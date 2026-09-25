function Install-RequirementsWithRetry {
    [CmdletBinding()]
    param(
        [string]$PythonPath   = 'python',
        [string]$FilePath     = 'requirements.txt',
        [int]   $MaxRetries   = 5,
        [int]   $DelaySeconds = 5
    )
    $attempt = 0
    do {
        $attempt++
        Write-Host "[$attempt/$MaxRetries] Installing from $FilePath ..."
        # pip writes the retryable 'HTTP Error 403' to stderr; under the module's
        # $ErrorActionPreference = 'Stop' a 2>&1 merge on Windows PowerShell 5.1
        # would throw on attempt 1 instead of entering the retry loop.
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $output = & $PythonPath -m pip install --upgrade -r $FilePath 2>&1
        $ErrorActionPreference = $prevEAP
        $exit   = $LASTEXITCODE
        if ($exit -eq 0) {
            Write-Host "Success on attempt $attempt." -ForegroundColor Green
            return
        }
        if ($output -match 'HTTP Error 403') {
            Write-Host "Received 403 - proxy is probably throttling.  Waiting $DelaySeconds s before retry..." -ForegroundColor Yellow
            Start-Sleep -Seconds $DelaySeconds
        } else {
            Write-Host "pip failed with an unexpected error (exit code $exit):" -ForegroundColor Red
            Write-Host $output -ForegroundColor Red
            return
        }
    } while ($attempt -lt $MaxRetries)
    Write-Host "Failed to install after $MaxRetries attempts." -ForegroundColor Red
}
