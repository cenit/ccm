#! /usr/bin/env pwsh

<#

.SYNOPSIS
    local-build
    Created By: Stefano Sinigardi
    Created Date: January 27, 2026
    Last Modified Date: January 28, 2026

.DESCRIPTION
    Generic script for building and running containerized applications locally.
    Works with any project having a compose.yaml file.
    Project-specific service names can be customized via parameters.

.PARAMETER AppService
    Name of the main application service in compose.yaml. Default: "app"

.PARAMETER DevService
    Name of the dev service (with hot-reload) in compose.yaml. Default: "app-dev"

.PARAMETER DbService
    Name of the database service in compose.yaml. Default: "db"

.PARAMETER AppPort
    Port the main application/API listens on. Default: 8000

.PARAMETER FrontendPort
    Port the frontend listens on. Set to 0 (default) if no separate frontend,
    or if the app is a single service. When set, the script shows both
    Frontend and API URLs in the output.

.PARAMETER Dev
    Start in development mode with hot-reload enabled

.PARAMETER Build
    Force rebuild of container images before starting

.PARAMETER Down
    Stop all services and remove volumes

.PARAMETER Logs
    Follow service logs (Ctrl+C to exit)

.PARAMETER ProjectDir
    Override the project root directory where compose.yaml is located.
    Default: auto-detected as parent of script location (CCM -> parent)
    Use this when the compose.yaml is in a subdirectory of the main repository.

.PARAMETER UseWslc
    Not supported here: wslc has no `compose` command yet, and local-build is compose-based. Passing -UseWslc fails fast. Use -UseDocker or -UsePodman. (tracking: https://github.com/clystian/WSL/pull/1)

.PARAMETER UseDocker
    Force Docker for building and running containers. Fails if Docker is not found (no fallback to Podman).

.PARAMETER UsePodman
    Force Podman for building and running containers. Fails if Podman is not found (no fallback to Docker).

.EXAMPLE
    ./CCM/local-build.ps1
    Build and start all services

.EXAMPLE
    ./CCM/local-build.ps1 -Dev
    Start with hot-reload for development

.EXAMPLE
    ./CCM/local-build.ps1 -Build
    Force rebuild containers

.EXAMPLE
    ./CCM/local-build.ps1 -Down
    Stop all services

.EXAMPLE
    ./CCM/local-build.ps1 -Logs
    Follow service logs

.EXAMPLE
    ./CCM/local-build.ps1 -AppService "api"
    Use custom service name

.EXAMPLE
    ./CCM/local-build.ps1 -ProjectDir webapp -AppService app
    Run compose from a subdirectory of the repository

.EXAMPLE
    ./CCM/local-build.ps1 -AppPort 8000 -FrontendPort 3000
    Use with separate frontend and API services on different ports

.NOTES
    This is a generic reusable script. The CCM folder can be shared across projects
    as a git submodule. Each project needs its own compose.yaml file.

#>

<#
Copyright (c) Stefano Sinigardi

MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED *AS IS*, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$AppService = "app",  # Name of the main application service in compose.yaml

    [Parameter(Mandatory = $false)]
    [string]$DevService = "app-dev",  # Name of the dev service (with hot-reload)

    [Parameter(Mandatory = $false)]
    [string]$DbService = "db",  # Name of the database service (optional)

    [Parameter(Mandatory = $false)]
    [int]$AppPort = 8000,  # Port the main application/API listens on

    [Parameter(Mandatory = $false)]
    [int]$FrontendPort = 0,  # Port the frontend listens on (0 = no separate frontend)

    [Parameter(Mandatory = $false)]
    [switch]$Dev,

    [Parameter(Mandatory = $false)]
    [switch]$Build,

    [Parameter(Mandatory = $false)]
    [switch]$Down,

    [Parameter(Mandatory = $false)]
    [switch]$Logs,

    [Parameter(Mandatory = $false)]
    [string]$ProjectDir,  # Override the project root directory (where compose.yaml lives)

    [Parameter(Mandatory = $false)]
    [switch]$UseDocker,

    [Parameter(Mandatory = $false)]
    [switch]$UsePodman,

    [Parameter(Mandatory = $false)]
    [switch]$UseWslc
)

$ErrorActionPreference = "Stop"

$local_build_ps1_version = "1.3.0"
$script_name = $MyInvocation.MyCommand.Name

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Import shared utilities
if (Test-Path $ScriptDir/utils.psm1) {
    Import-Module -Name $ScriptDir/utils.psm1 -Force
}
$ProjectRoot = Split-Path -Parent $ScriptDir

$ccmLog = Initialize-CcmLogging
trap { Pop-Location -StackName 'ccm-localbuild' -ErrorAction SilentlyContinue; Stop-CcmLogging $ccmLog; break }

$ErrorActionPreference = "Stop"

Write-Host "Local Build script version ${local_build_ps1_version}"
Write-Host "Script name: $script_name"
Write-Host "Working directory: $ScriptDir"
Write-Host "Project root: $ProjectRoot"
Write-Host "Log file: $($ccmLog.LogPath)"
Write-Host -NoNewLine "PowerShell version: "
$PSVersionTable.PSVersion
Write-Host ""

function Invoke-Compose {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Runner,
        [Parameter(Mandatory = $true)][string[]]$Args
    )

    switch ($Runner.Kind) {
        "docker" { & $Runner.Command compose @Args | Out-Host }
        "podman" { & $Runner.Command compose @Args | Out-Host }
        default { throw "Unknown compose runner kind: $($Runner.Kind)" }
    }

    # Return the exit code from the compose command
    return $LASTEXITCODE
}

# Compose-based: wslc is excluded (no `compose` yet). CLI switch wins; else auto-detect docker -> podman.
$SelectedRuntimeSwitches = @($UseWslc, $UseDocker, $UsePodman) | Where-Object { $_ }
if ($SelectedRuntimeSwitches.Count -gt 1) {
    throw "Specify at most one of -UseWslc, -UseDocker, -UsePodman"
}
$PreferRuntime = ''
if ($UseWslc)       { $PreferRuntime = 'wslc' }
elseif ($UseDocker) { $PreferRuntime = 'docker' }
elseif ($UsePodman) { $PreferRuntime = 'podman' }
$ComposeRunner = Resolve-CcmContainerRuntime -Prefer $PreferRuntime -RequireCompose

# Use ProjectDir override if specified, otherwise default to ProjectRoot
$EffectiveProjectDir = if ($ProjectDir) {
    # Resolve relative to ProjectRoot if not absolute
    if ([System.IO.Path]::IsPathRooted($ProjectDir)) { $ProjectDir }
    else { Join-Path $ProjectRoot $ProjectDir }
} else {
    $ProjectRoot
}

Write-Host "Project directory: $EffectiveProjectDir"

Push-Location $EffectiveProjectDir -StackName 'ccm-localbuild'

if ($Down) {
        Write-Host "Stopping all services..." -ForegroundColor Yellow
        Invoke-Compose -Runner $ComposeRunner -Args @("down", "-v")
        Write-Host "Services stopped." -ForegroundColor Green
        exit 0
    }

    if ($Logs) {
        Write-Host "Following logs (Ctrl+C to exit)..." -ForegroundColor Yellow
        if ($Dev) {
            # Dev profile is optional; fall back to non-profile logs if not available
            try {
                Invoke-Compose -Runner $ComposeRunner -Args @("--profile", "dev", "logs", "-f", $DevService)
            } catch {
                Invoke-Compose -Runner $ComposeRunner -Args @("logs", "-f", $DevService)
            }
        }
        else {
            Invoke-Compose -Runner $ComposeRunner -Args @("logs", "-f", $AppService)
        }
        exit 0
    }

    # Load environment variables from .env if it exists
    if (Test-Path ".env") {
        Write-Host "Loading environment from .env file..." -ForegroundColor Cyan
        Get-Content ".env" | ForEach-Object {
            if ($_ -match '^([^#=]+)=(.*)$') {
                $name = $matches[1].Trim()
                $value = $matches[2].Trim()
                [Environment]::SetEnvironmentVariable($name, $value, "Process")
            }
        }
    }
    else {
        Write-Host "No .env file found. Using defaults." -ForegroundColor Yellow
        Write-Host "Tip: Copy .env.example to .env and configure your settings." -ForegroundColor Yellow
    }

    # Ensure custom-ca.crt exists for Dockerfile COPY
    Install-CustomCaCert -TargetDir $EffectiveProjectDir

    # Run project-specific pre-build hook if present
    $preBuildScript = Join-Path $EffectiveProjectDir "pre-build.ps1"
    if (Test-Path $preBuildScript) {
        Write-Host "Running pre-build hook: $preBuildScript" -ForegroundColor Cyan
        try {
            & $preBuildScript
            if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
                Write-Error "Pre-build hook failed with exit code $LASTEXITCODE"
                exit 1
            }
        } catch {
            Write-Error "Pre-build hook failed: $_"
            exit 1
        }
        Write-Host "Pre-build hook completed." -ForegroundColor Green
        Write-Host ""
    }

    # Build arguments
    $buildArgs = @()
    if ($Build) {
        $buildArgs += "--build"
    }

    Write-Host ""
    Write-Host "=== Tool Local Development ===" -ForegroundColor Cyan
    Write-Host "Compose Tool: $($ComposeRunner.Kind)"
    Write-Host "Mode: $(if ($Dev) { 'Development (hot-reload)' } else { 'Production' })"
    Write-Host ""

    # Clean up stale resources that may cause compose to fail
    # (e.g., networks with incorrect labels from previous runs)
    function Remove-StaleComposeResources {
        param([hashtable]$Runner)

        # Get project name from compose (defaults to directory name)
        $projectName = (Get-Item $EffectiveProjectDir).Name.ToLower()

        # Find networks that might have label mismatches
        $networkName = "${projectName}-network"

        try {
            $networkExists = & $Runner.Command network exists $networkName 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Cleaning up existing network '$networkName'..." -ForegroundColor Yellow

                # Stop and remove any containers using this network
                $containersOnNetwork = & $Runner.Command network inspect $networkName --format "{{range .Containers}}{{.Name}} {{end}}" 2>$null
                if ($containersOnNetwork) {
                    $containerList = $containersOnNetwork.Trim() -split '\s+'
                    foreach ($container in $containerList) {
                        if ($container) {
                            Write-Host "  Stopping container: $container" -ForegroundColor Gray
                            & $Runner.Command stop $container 2>$null | Out-Null
                            & $Runner.Command rm $container 2>$null | Out-Null
                        }
                    }
                }

                # Remove the network
                & $Runner.Command network rm $networkName 2>$null | Out-Null
                Write-Host "  Network removed." -ForegroundColor Gray
            }
        } catch {
            # Network doesn't exist or other non-fatal error, continue
        }
    }

    # Perform cleanup before starting
    Remove-StaleComposeResources -Runner $ComposeRunner

    # Ensure network exists with proper DNS configuration for corporate environments
    # This is required for containers to resolve external hostnames (e.g., Azure OpenAI endpoints)
    function Ensure-NetworkWithDns {
        param(
            [hashtable]$Runner,
            [string]$NetworkName,
            [string[]]$DnsServers = @()
        )

        # Check if network exists
        $networkExists = $false
        try {
            & $Runner.Command network exists $NetworkName 2>$null | Out-Null
            $networkExists = ($LASTEXITCODE -eq 0)
        } catch {
            $networkExists = $false
        }

        if ($networkExists) {
            # Check if network has correct DNS configuration
            $networkInfo = & $Runner.Command network inspect $NetworkName 2>$null | ConvertFrom-Json
            $currentDns = $networkInfo.network_dns_servers

            $dnsMatches = $true
            if ($DnsServers.Count -gt 0) {
                if (-not $currentDns -or $currentDns.Count -ne $DnsServers.Count) {
                    $dnsMatches = $false
                } else {
                    for ($i = 0; $i -lt $DnsServers.Count; $i++) {
                        if ($currentDns[$i] -ne $DnsServers[$i]) {
                            $dnsMatches = $false
                            break
                        }
                    }
                }
            }

            if (-not $dnsMatches -and $DnsServers.Count -gt 0) {
                Write-Host "Network '$NetworkName' exists but DNS configuration doesn't match. Recreating..." -ForegroundColor Yellow

                # Stop containers on this network
                $containersOnNetwork = & $Runner.Command network inspect $NetworkName --format "{{range .Containers}}{{.Name}} {{end}}" 2>$null
                if ($containersOnNetwork) {
                    $containerList = $containersOnNetwork.Trim() -split '\s+'
                    foreach ($container in $containerList) {
                        if ($container) {
                            & $Runner.Command stop $container 2>$null | Out-Null
                            & $Runner.Command rm $container 2>$null | Out-Null
                        }
                    }
                }

                & $Runner.Command network rm $NetworkName 2>$null | Out-Null
                $networkExists = $false
            }
        }

        if (-not $networkExists -and $DnsServers.Count -gt 0) {
            Write-Host "Creating network '$NetworkName' with DNS servers: $($DnsServers -join ', ')..." -ForegroundColor Yellow
            $dnsArgs = @()
            foreach ($dns in $DnsServers) {
                $dnsArgs += "--dns=$dns"
            }
            & $Runner.Command network create @dnsArgs $NetworkName 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Network created with custom DNS configuration." -ForegroundColor Green
            } else {
                Write-Warning "Failed to create network with custom DNS. Compose will create it with default settings."
            }
        }
    }

    # Get project name and network name from compose.yaml
    $projectName = (Get-Item $EffectiveProjectDir).Name.ToLower()
    $networkName = "${projectName}-network"

    # Detect DNS servers to use (corporate DNS + fallback)
    # Try to get the primary DNS server from the system
    $dnsServers = @()
    try {
        $primaryDns = (Get-DnsClientServerAddress -AddressFamily IPv4 |
                       Where-Object { $_.ServerAddresses } |
                       Select-Object -First 1).ServerAddresses |
                       Select-Object -First 1
        if ($primaryDns -and $primaryDns -notmatch '^(127\.|::1)') {
            $dnsServers += $primaryDns
        }
    } catch {
        # Fallback to common corporate DNS if detection fails
    }

    # Add Google DNS as fallback
    $dnsServers += "8.8.8.8"

    # Remove duplicates
    $dnsServers = $dnsServers | Select-Object -Unique

    Write-Host "Detected DNS servers: $($dnsServers -join ', ')" -ForegroundColor Cyan
    Ensure-NetworkWithDns -Runner $ComposeRunner -NetworkName $networkName -DnsServers $dnsServers

    if ($Dev) {
        Write-Host "Starting in development mode..." -ForegroundColor Yellow
        # Build the list of services to start in dev mode
        $devServices = @($DevService)
        if ($DbService) {
            # Only include the db service if it is defined in the compose file
            $availableServices = @()
            try {
                $serviceOutput = & $ComposeRunner.Command compose --profile dev config --services 2>$null
                if ($LASTEXITCODE -eq 0 -and $serviceOutput) {
                    $availableServices = @($serviceOutput -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                }
            } catch {}
            if ($availableServices -contains $DbService) {
                $devServices = @($DbService) + $devServices
            }
        }
        # Prefer a dev profile if present, otherwise fall back to normal up.
        try {
            $exitCode = Invoke-Compose -Runner $ComposeRunner -Args (@("--profile", "dev", "up", "-d") + $buildArgs + $devServices)
        } catch {
            $exitCode = Invoke-Compose -Runner $ComposeRunner -Args (@("up", "-d") + $buildArgs)
        }
    }
    else {
        Write-Host "Starting in production mode..." -ForegroundColor Yellow
        $exitCode = Invoke-Compose -Runner $ComposeRunner -Args (@("up", "-d") + $buildArgs)
    }

    if ($exitCode -ne 0) {
        Write-Error "Compose command failed with exit code $exitCode"
        exit 1
    }

    # Verify containers are actually running
    Write-Host ""
    Write-Host "Verifying services..." -ForegroundColor Yellow
    Start-Sleep -Seconds 2

    $psOutput = & $ComposeRunner.Command compose ps --format json 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to check container status"
        exit 1
    }

    # Check if any containers are running
    $runningContainers = @()
    try {
        # podman compose ps --format json outputs one JSON object per line
        $psOutput | ForEach-Object {
            if ($_ -match '^\{') {
                $container = $_ | ConvertFrom-Json
                if ($container.State -eq "running" -or $container.Status -match "^Up") {
                    $runningContainers += $container.Name
                }
            }
        }
    } catch {
        Write-Warning "Could not parse container status, continuing..."
    }

    if ($runningContainers.Count -eq 0) {
        Write-Error "No containers are running. Build or startup may have failed."
        Write-Host ""
        Write-Host "Troubleshooting steps:" -ForegroundColor Yellow
        Write-Host "  1. Check logs: ./CCM/local-build.ps1 -Logs"
        Write-Host "  2. Clean up:   podman compose down -v; podman pod rm -f pod_<project-name>"
        Write-Host "  3. Rebuild:    ./CCM/local-build.ps1 -Build"
        exit 1
    }

    Write-Host "Running containers: $($runningContainers -join ', ')" -ForegroundColor Green

    Write-Host ""
    Write-Host "=== Services Started ===" -ForegroundColor Green
    Write-Host ""
    if ($FrontendPort -gt 0) {
        # Separate frontend and backend configuration
        Write-Host "Frontend:    http://localhost:$FrontendPort" -ForegroundColor Cyan
        Write-Host "API:         http://localhost:$AppPort" -ForegroundColor Cyan
        Write-Host "API Docs:    http://localhost:$AppPort/api/docs" -ForegroundColor Cyan
        Write-Host "Health:      http://localhost:$AppPort/api/health" -ForegroundColor Cyan
    }
    else {
        # Single application endpoint (API serves frontend or no frontend)
        Write-Host "Application: http://localhost:$AppPort" -ForegroundColor Cyan
        Write-Host "API Docs:    http://localhost:$AppPort/api/docs" -ForegroundColor Cyan
        Write-Host "Health:      http://localhost:$AppPort/api/health" -ForegroundColor Cyan
    }
    Write-Host ""
    if ($DbService) {
        Write-Host "Database:    See compose.yaml for connection details" -ForegroundColor Cyan
        Write-Host ""
    }
    Write-Host "Commands:" -ForegroundColor Yellow
    Write-Host "  View logs:    ./CCM/local-build.ps1 -Logs"
    Write-Host "  Stop:         ./CCM/local-build.ps1 -Down"
    Write-Host "  Rebuild:      ./CCM/local-build.ps1 -Build"

Pop-Location -StackName 'ccm-localbuild'
Stop-CcmLogging $ccmLog
