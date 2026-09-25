#! /usr/bin/env pwsh

<#
.SYNOPSIS
    Diagnose ECR connectivity issues for IT support
.DESCRIPTION
    This script helps diagnose why ECR login might fail on corporate networks.
    Run this and share the output with IT support.
.PARAMETER AwsRegion
    AWS region. Default: eu-central-1
.PARAMETER AwsAccountId
    AWS account ID.
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$AwsRegion = "eu-central-1",

    [Parameter(Mandatory = $true)]
    [string]$AwsAccountId
)

$EcrHost = "$AwsAccountId.dkr.ecr.$AwsRegion.amazonaws.com"
$EcrEndpoint = "https://$EcrHost/v2/"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "ECR Connectivity Diagnostic Report" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Target: $EcrHost"
Write-Host "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host "User: $env:USERNAME"
Write-Host ""

# Section 1: System Proxy Settings
Write-Host "--- SECTION 1: System Proxy Settings ---" -ForegroundColor Yellow
Write-Host ""

# Windows Internet Settings
$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
$proxyEnabled = (Get-ItemProperty -Path $regPath -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
$proxyServer = (Get-ItemProperty -Path $regPath -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer
$proxyOverride = (Get-ItemProperty -Path $regPath -Name ProxyOverride -ErrorAction SilentlyContinue).ProxyOverride

Write-Host "Windows Proxy Enabled: $proxyEnabled"
Write-Host "Windows Proxy Server: $proxyServer"
Write-Host "Windows Proxy Bypass: $proxyOverride"
Write-Host ""

# Environment variables
Write-Host "HTTP_PROXY: $env:HTTP_PROXY"
Write-Host "HTTPS_PROXY: $env:HTTPS_PROXY"
Write-Host "NO_PROXY: $env:NO_PROXY"
Write-Host "http_proxy: $env:http_proxy"
Write-Host "https_proxy: $env:https_proxy"
Write-Host "no_proxy: $env:no_proxy"
Write-Host ""

# Section 2: Docker/Podman Configuration
Write-Host "--- SECTION 2: Container Runtime Configuration ---" -ForegroundColor Yellow
Write-Host ""

# Detect container runtime
$containerTool = $null
if (Get-Command wslc -ErrorAction SilentlyContinue) {
    $containerTool = "wslc"
    Write-Host "wslc detected"
    wslc version 2>&1 | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
}
elseif (Get-Command docker -ErrorAction SilentlyContinue) {
    $containerTool = "docker"
    Write-Host "Docker detected"

    # Docker version
    docker version 2>&1 | ForEach-Object { Write-Host "  $_" }
    Write-Host ""

    # Docker info (proxy settings)
    Write-Host "Docker system info (proxy-related):"
    $dockerInfo = docker info 2>&1
    $dockerInfo | Where-Object { $_ -match "Proxy|proxy|HTTP|http" } | ForEach-Object { Write-Host "  $_" }
    Write-Host ""

    # Docker config file
    $dockerConfigPath = "$env:USERPROFILE\.docker\config.json"
    if (Test-Path $dockerConfigPath) {
        Write-Host "Docker config file found: $dockerConfigPath"
        $dockerConfig = Get-Content $dockerConfigPath -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($dockerConfig.proxies) {
            Write-Host "Docker proxy configuration:"
            $dockerConfig.proxies | ConvertTo-Json | Write-Host
        } else {
            Write-Host "No proxy configuration in Docker config"
        }
    } else {
        Write-Host "No Docker config file at $dockerConfigPath"
    }
    Write-Host ""

    # Docker Desktop settings (Windows)
    $dockerDesktopSettings = "$env:APPDATA\Docker\settings.json"
    if (Test-Path $dockerDesktopSettings) {
        Write-Host "Docker Desktop settings found: $dockerDesktopSettings"
        $settings = Get-Content $dockerDesktopSettings -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($settings.proxyHttpMode) {
            Write-Host "  proxyHttpMode: $($settings.proxyHttpMode)"
        }
        if ($settings.overrideProxyHttp) {
            Write-Host "  overrideProxyHttp: $($settings.overrideProxyHttp)"
        }
        if ($settings.overrideProxyHttps) {
            Write-Host "  overrideProxyHttps: $($settings.overrideProxyHttps)"
        }
    }
}
elseif (Get-Command podman -ErrorAction SilentlyContinue) {
    $containerTool = "podman"
    Write-Host "Podman detected"
    podman version 2>&1 | ForEach-Object { Write-Host "  $_" }
}
else {
    Write-Host "WARNING: No container runtime (wslc, Docker, or Podman) found!" -ForegroundColor Red
}
Write-Host ""

# Section 3: DNS Resolution
Write-Host "--- SECTION 3: DNS Resolution ---" -ForegroundColor Yellow
Write-Host ""

Write-Host "Resolving $EcrHost..."
try {
    $dns = Resolve-DnsName $EcrHost -ErrorAction Stop
    Write-Host "  SUCCESS - Resolved to: $($dns.IPAddress -join ', ')" -ForegroundColor Green
} catch {
    Write-Host "  FAILED - DNS resolution error: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Section 4: TCP Connectivity
Write-Host "--- SECTION 4: TCP Connectivity (Port 443) ---" -ForegroundColor Yellow
Write-Host ""

Write-Host "Testing TCP connection to ${EcrHost}:443..."
try {
    $tcpClient = New-Object System.Net.Sockets.TcpClient
    $connectTask = $tcpClient.ConnectAsync($EcrHost, 443)
    if ($connectTask.Wait(10000)) {
        Write-Host "  SUCCESS - TCP connection established" -ForegroundColor Green
        $tcpClient.Close()
    } else {
        Write-Host "  FAILED - Connection timed out after 10 seconds" -ForegroundColor Red
    }
} catch {
    Write-Host "  FAILED - $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Section 5: HTTPS Connectivity (PowerShell)
Write-Host "--- SECTION 5: HTTPS Connectivity (PowerShell) ---" -ForegroundColor Yellow
Write-Host ""

Write-Host "Testing HTTPS to $EcrEndpoint (PowerShell)..."
try {
    # This should fail with 401 Unauthorized (no auth), but that's OK - it means HTTPS works
    $response = Invoke-WebRequest -Uri $EcrEndpoint -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    Write-Host "  SUCCESS (unexpected) - Status: $($response.StatusCode)" -ForegroundColor Green
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    if ($statusCode -eq 401 -or $statusCode -eq 403) {
        Write-Host "  SUCCESS - Got HTTP $statusCode (expected, HTTPS connectivity works)" -ForegroundColor Green
    } else {
        Write-Host "  FAILED - $($_.Exception.Message)" -ForegroundColor Red

        # Check for SSL/TLS errors
        if ($_.Exception.Message -match "SSL|TLS|certificate|trust") {
            Write-Host ""
            Write-Host "  LIKELY CAUSE: SSL/TLS interception or certificate issue" -ForegroundColor Yellow
            Write-Host "  Corporate proxies often intercept HTTPS traffic." -ForegroundColor Yellow
        }
    }
}
Write-Host ""

# Section 6: HTTPS via curl (if available)
Write-Host "--- SECTION 6: HTTPS Connectivity (curl) ---" -ForegroundColor Yellow
Write-Host ""

if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
    Write-Host "Testing HTTPS via curl.exe..."
    $curlOutput = curl.exe -v --connect-timeout 10 $EcrEndpoint 2>&1
    $curlOutput | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "curl.exe not found, skipping"
}
Write-Host ""

# Section 7: AWS CLI Connectivity
Write-Host "--- SECTION 7: AWS CLI Connectivity ---" -ForegroundColor Yellow
Write-Host ""

Write-Host "Testing AWS STS (identity)..."
$stsResult = aws sts get-caller-identity --region $AwsRegion 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  SUCCESS - AWS credentials working" -ForegroundColor Green
    $stsResult | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "  FAILED - $stsResult" -ForegroundColor Red
}
Write-Host ""

Write-Host "Testing AWS ECR get-login-password..."
$ecrPassword = aws ecr get-login-password --region $AwsRegion 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  SUCCESS - ECR password retrieved (length: $($ecrPassword.Length) chars)" -ForegroundColor Green
} else {
    Write-Host "  FAILED - $ecrPassword" -ForegroundColor Red
}
Write-Host ""

# Section 8: Container Runtime ECR Test
Write-Host "--- SECTION 8: Container Runtime ECR Login Test ---" -ForegroundColor Yellow
Write-Host ""

if ($containerTool) {
    Write-Host "Testing $containerTool login to ECR..."
    Write-Host "Command: aws ecr get-login-password | $containerTool login --username AWS --password-stdin $EcrHost"
    Write-Host ""

    $ecrPassword = aws ecr get-login-password --region $AwsRegion 2>&1
    if ($LASTEXITCODE -eq 0) {
        $loginResult = $ecrPassword | & $containerTool login --username AWS --password-stdin $EcrHost 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  SUCCESS - Container runtime logged in to ECR" -ForegroundColor Green
        } else {
            Write-Host "  FAILED - $loginResult" -ForegroundColor Red
            Write-Host ""
            Write-Host "  This is likely the issue! The container runtime cannot reach ECR." -ForegroundColor Yellow

            # Suggest fixes
            Write-Host ""
            Write-Host "  POSSIBLE FIXES:" -ForegroundColor Cyan
            Write-Host "  1. Configure Docker/Podman to use corporate proxy:" -ForegroundColor White
            Write-Host "     - Docker Desktop: Settings > Resources > Proxies" -ForegroundColor Gray
            Write-Host "     - Or add to ~/.docker/config.json:" -ForegroundColor Gray
            Write-Host '       {"proxies":{"default":{"httpProxy":"http://proxy:port","httpsProxy":"http://proxy:port"}}}' -ForegroundColor Gray
            Write-Host ""
            Write-Host "  2. Add ECR to proxy bypass list (if proxy causes SSL issues):" -ForegroundColor White
            Write-Host "     NO_PROXY=*.amazonaws.com" -ForegroundColor Gray
            Write-Host ""
            Write-Host "  3. Corporate firewall may need to allowlist:" -ForegroundColor White
            Write-Host "     - $EcrHost (port 443)" -ForegroundColor Gray
            Write-Host "     - *.dkr.ecr.$AwsRegion.amazonaws.com (port 443)" -ForegroundColor Gray
            Write-Host ""
            Write-Host "  4. If SSL inspection is enabled, IT may need to:" -ForegroundColor White
            Write-Host "     - Add *.amazonaws.com to SSL inspection bypass" -ForegroundColor Gray
            Write-Host "     - Or install corporate CA cert in Docker/Podman" -ForegroundColor Gray
        }
    }
}
Write-Host ""

# Section 9: Certificate Chain
Write-Host "--- SECTION 9: TLS Certificate Chain ---" -ForegroundColor Yellow
Write-Host ""

Write-Host "Checking TLS certificate for $EcrHost..."
try {
    $tcpClient = New-Object System.Net.Sockets.TcpClient($EcrHost, 443)
    $sslStream = New-Object System.Net.Security.SslStream($tcpClient.GetStream(), $false, { $true })
    $sslStream.AuthenticateAsClient($EcrHost)
    $cert = $sslStream.RemoteCertificate

    Write-Host "  Certificate Subject: $($cert.Subject)" -ForegroundColor Green
    Write-Host "  Certificate Issuer: $($cert.Issuer)"
    Write-Host "  Valid From: $($cert.GetEffectiveDateString())"
    Write-Host "  Valid To: $($cert.GetExpirationDateString())"

    # Check if it's a corporate proxy cert (indicates SSL inspection)
    if ($cert.Issuer -notmatch "Amazon|AWS|DigiCert|Starfield") {
        Write-Host ""
        Write-Host "  WARNING: Certificate issuer is not Amazon/AWS!" -ForegroundColor Yellow
        Write-Host "  This indicates SSL/TLS inspection by corporate proxy." -ForegroundColor Yellow
        Write-Host "  The certificate is issued by: $($cert.Issuer)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  IT ACTION REQUIRED: Add *.amazonaws.com to SSL inspection bypass" -ForegroundColor Red
    }

    $sslStream.Close()
    $tcpClient.Close()
} catch {
    Write-Host "  FAILED - $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Summary
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "SUMMARY FOR IT SUPPORT" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "The user is experiencing ECR login failures with this error:"
Write-Host '  "pinging container registry ... Get https://...: EOF"'
Write-Host ""
Write-Host "This typically indicates one of:"
Write-Host "  1. SSL/TLS interception breaking Docker's HTTPS connections"
Write-Host "  2. Firewall blocking Docker's outbound HTTPS to AWS"
Write-Host "  3. Docker not configured to use corporate proxy"
Write-Host ""
Write-Host "Please ensure:"
Write-Host "  - Port 443 outbound is allowed to *.dkr.ecr.*.amazonaws.com"
Write-Host "  - SSL inspection bypasses *.amazonaws.com OR"
Write-Host "  - Corporate CA certificate is installed in Docker/container runtime"
Write-Host ""
Write-Host "Share this output with IT support for troubleshooting."
Write-Host ""
