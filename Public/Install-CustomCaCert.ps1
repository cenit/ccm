function Install-CustomCaCert {
    <#
    .SYNOPSIS
      Ensures a custom-ca.crt file exists in the target directory for Dockerfile COPY.
      TLS-intercepting corporate proxies re-sign traffic; the CA cert must be
      injected into the container so pip/npm/apk can fetch packages.

    .PARAMETER TargetDir
      Directory where custom-ca.crt will be created or copied to.
      Typically the project root containing the Dockerfile.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetDir
    )

    $customCaCertPath = Join-Path $TargetDir 'custom-ca.crt'
    $certSource = $null

    # 1. Try the SSL_CERT_FILE environment variable (set per setup_podman.md)
    if ($env:SSL_CERT_FILE -and (Test-Path $env:SSL_CERT_FILE)) {
        $certSource = $env:SSL_CERT_FILE
    }
    # 2. Fallback: the default location documented in setup_podman.md
    elseif (Test-Path "$env:USERPROFILE\corporate-root-ca.pem") {
        $certSource = "$env:USERPROFILE\corporate-root-ca.pem"
    }
    elseif (Test-Path "$env:USERPROFILE\corporate-root-ca.crt") {
        $certSource = "$env:USERPROFILE\corporate-root-ca.crt"
    }

    if ($certSource) {
        Copy-Item -Path $certSource -Destination $customCaCertPath -Force
        Write-Host "Copied CA certificate from $certSource for container build." -ForegroundColor Cyan
    }
    else {
        # Create empty file so Dockerfile COPY does not fail
        if (-not (Test-Path $customCaCertPath)) {
            New-Item -Path $customCaCertPath -ItemType File -Force | Out-Null
        }
        Write-Host "No custom CA certificate found. Using default trust store." -ForegroundColor Yellow
        Write-Host "Tip: Set SSL_CERT_FILE or place corporate-root-ca.pem in $env:USERPROFILE (see CCM/setup_podman.md)." -ForegroundColor Yellow
    }
}
