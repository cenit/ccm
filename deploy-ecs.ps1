#! /usr/bin/env pwsh

<#

.SYNOPSIS
    deploy-ecs
    Created By: Stefano Sinigardi
    Created Date: January 27, 2026
    Last Modified Date: March 21, 2026

.DESCRIPTION
    Generic script for deploying containerized applications to AWS ECS.
    Supports version management, image building, migrations, and service updates.

    Prerequisites:
      - AWS CLI configured with proper credentials
      - Docker/Podman available for building images
      - Task definition files in deploy/ecs/ directory

.PARAMETER ProjectName
    Base name for all AWS resources (cluster, service, ECR repository)
    Example: "my-app" will create "my-app-cluster", "my-app-service"

.PARAMETER ImageTag
    Override the image tag/version to deploy (e.g., "v1.0.0")
    If not specified, version is read from VersionFile

.PARAMETER BumpVersion
    Bump the version before deploying. Valid values: "patch", "minor", "major"
    Example: patch bumps 1.0.9 -> 1.0.10

.PARAMETER AwsRegion
    AWS region for deployment. Default: "eu-central-1"

.PARAMETER AwsAccountId
    AWS account ID. Default: reads from $env:AWS_ACCOUNT_ID or "000123456789"

.PARAMETER ClusterName
    ECS cluster name. Default: "$ProjectName-cluster"

.PARAMETER ServiceName
    ECS service name. Default: "$ProjectName-service"

.PARAMETER TargetGroupArn
    Override the primary target group attached to the ECS service. Used by
    preview deployments that create PR-specific target groups. Marks the service
    as ephemeral: shared ExposedTargetGroups from infrastructure-config.json are
    NOT attached, so preview side-cars never register into production NLB/ALB
    target groups.

.PARAMETER WebUiUrl
    Override the URL printed in the "Web UI available at" summary. Preview
    deployments pass the full PR preview URL (including the /_pr/<id> path
    prefix) so the summary reflects the real address instead of the bare host.

.PARAMETER VersionFile
    File containing version string. Default: "frontend/src/App.jsx"

.PARAMETER VersionPattern
    Regex pattern to extract version from VersionFile
    Default: "APP_VERSION\s*=\s*'v([\d.]+)'"

.PARAMETER DeployDir
    Directory containing ecs/ subfolder with task definitions
    Default: auto-detected as ../deploy from script location

.PARAMETER TaskDefinitionFile
    Task definition template file
    Default: "$DeployDir/ecs/task-definition-live.json"

.PARAMETER MigrationsTaskDefFile
    Migrations task definition file
    Default: "$DeployDir/ecs/migrations-task-definition.json"

.PARAMETER DockerfilePath
    Path to Dockerfile. Default: "Dockerfile"

.PARAMETER SkipBuild
    Skip building the Docker image, use existing image in ECR

.PARAMETER SkipDeploy
    Skip the deploy phase (task-definition registration and service update).
    Build and push the image to ECR, then exit. Useful for splitting build
    and deploy into separate CI stages: build with -SkipDeploy, then later
    call -SkipBuild against the same image tag from a deploy stage.
    Mutually exclusive with -SkipBuild.

.PARAMETER RunMigrations
    Run database migrations before deploying the new version

.PARAMETER MigrationsOnly
    Run database migrations and exit 0 without registering a new task definition
    or updating the ECS service. Implies -RunMigrations. Intended for pipelines
    that run migrations in a dedicated stage before the deploy stage so migration
    failures are visible as a distinct stage failure. When combined with -SkipBuild
    and -ImageTag, runs migrations using the already-built image identified by
    the given tag.

.PARAMETER UseWslc
    Force wslc (WSL Container CLI) for building and pushing images. Windows-only. Fails if wslc is not found (no fallback).
    When no -Use* switch and no ContainerTool config is given, auto-detect prefers wslc, then docker, then podman.

.PARAMETER UsePodman
    Force Podman for building and pushing images. Fails if Podman is not found (no fallback to Docker).

.PARAMETER UseDocker
    Force Docker for building and pushing images. Fails if Docker is not found (no fallback to Podman).

.PARAMETER SkipLatestTag
    Skip tagging the pushed image as 'latest' in ECR.
    By default, each pushed image is also tagged as 'latest'.

.PARAMETER DesiredCount
    Number of task instances when creating a new ECS service. Default: 1
    Only used during initial service creation; ignored for service updates.

.PARAMETER ContainerPort
    Port the container exposes, used for ALB registration during service creation. Default: 8000

.PARAMETER HealthCheckGracePeriodSeconds
    ECS health-check grace period (seconds) the service allows a task to become healthy
    before ELB health checks can mark it unhealthy. Applied on both create-service and
    update-service, so ecs-config.json's HealthCheckGracePeriodSeconds is the single source
    of truth and never drifts. When unset, create-service uses 180 and update-service leaves
    the existing value untouched. Raise it for slow-starting tasks (e.g. sidecars with long
    startPeriods) to avoid deploys flapping.

.PARAMETER ContainerName
    Container name for ALB target group registration. Default: same as ProjectName.
    Must match the "name" field in the task definition's containerDefinitions.

.PARAMETER EnvironmentOverride
    Environment variable overrides applied to the selected container in the task
    definition. Values use KEY=VALUE syntax and update or append entries.

.PARAMETER SecretOverride
    ECS secret overrides applied to the selected container in the task definition.
    Values use KEY=VALUE_FROM syntax and update or append entries.

.PARAMETER CorsAllowedOrigins
    Explicit value for ${CORS_ALLOWED_ORIGINS} and ${ALLOWED_ORIGINS}
    placeholders in task definitions.

.PARAMETER BuildTarget
    Target stage to build in a multi-stage Dockerfile (passed as --target).
    Leave empty (default) for single-stage Dockerfiles or to build the final stage.
    Example: -BuildTarget "runtime"

.PARAMETER UseTarContext
    Pipe the build context through tar to exclude .git and other large directories.
    Useful for repos where Podman hits "io: read/write on closed pipe" errors.
    Default: false. Can also be set via "UseTarContext": true in ecs-config.json.

.PARAMETER NoCache
    Build the image from scratch, ignoring every cached layer (passed as --no-cache).
    Default: false.

    Use this when a self-hosted agent's local layer store has gone bad. A layer can
    be silently corrupted (most often by the build disk filling up mid-write), and
    the damage only surfaces at push time, when the layer is read back to be
    uploaded:

        Error: reading blob sha256:<digest>: file integrity checksum failed for "<path>"

    That error is local, not a registry problem, and it is not transient - the push
    retries cannot recover it, because every build reuses the same damaged cached
    layer. -NoCache rebuilds the layer from scratch and unblocks the push without
    needing a session on the agent. To clear the damaged layer for good, run
    'podman image prune -a -f' on the agent.

.PARAMETER BuildArgs
    Additional docker/podman build arguments as key=value strings.
    Example: -BuildArgs "REACT_APP_API_URL=https://api.example.com","NODE_ENV=production"

    APP_VERSION is injected automatically from the resolved version, so an image
    declaring 'ARG APP_VERSION' can report the same version its tag carries
    without configuring anything. Images that do not declare it are unaffected:
    an unconsumed build arg is a warning, never an error. Passing your own
    APP_VERSION here overrides the injected one.

.PARAMETER ConfigFile
    Path to ecs-config.json project configuration file.
    Default: auto-detected as ecs-config.json in the project root (parent of CCM/).
    If found, parameters from the config file are used as defaults.
    CLI parameters always take precedence over config file values.

.PARAMETER ExternalImage
    Full image reference (registry/repo:tag or registry/repo@sha256:...) for
    deployments that source the container image from an external / cross-account
    registry that is NOT mirrored into the project's own ECR.

    When set:
      - the build phase is skipped (Dockerfile / podman / docker not required)
      - the script does NOT verify the image against the project's ECR
      - in the rendered task definition, any container whose image points at the
        project's canonical ECR path
        ("$AwsAccountId.dkr.ecr.$AwsRegion.amazonaws.com/$ProjectName:...") is
        rewritten to $ExternalImage. Containers that already reference a
        different registry (e.g. supplier-hardcoded literals) are left alone.
      - the same override is applied to the migrations task definition when
        -RunMigrations is used
      - the image tag for logging is derived from the ref (text after the last
        ':' if it is a tag, or "latest" / the digest fragment otherwise)

    The execution role must already have ecr:BatchGetImage /
    ecr:GetDownloadUrlForLayer / ecr:BatchCheckLayerAvailability on the
    external repository ARN, and the external registry's repository policy
    must permit pull from this account. Neither is created by this script.

    Mutually exclusive with -BumpVersion and -SkipDeploy. Build-time flags
    (-BuildArgs, -BuildTarget, -UseTarContext, -UsePodman, -UseDocker,
    -SkipLatestTag) are ignored when this flag is set.

.EXAMPLE
    .\CCM\deploy-ecs.ps1
    Deploy using all parameters from ecs-config.json in the project root

.EXAMPLE
    .\CCM\deploy-ecs.ps1 -ProjectName "my-project"
    Deploy current version of project

.EXAMPLE
    .\CCM\deploy-ecs.ps1 -ProjectName "my-app" -BumpVersion patch
    Bump patch version (1.0.9 -> 1.0.10) and deploy

.EXAMPLE
    .\CCM\deploy-ecs.ps1 -ProjectName "my-app" -BumpVersion minor
    Bump minor version (1.0.9 -> 1.1.0) and deploy

.EXAMPLE
    .\CCM\deploy-ecs.ps1 -ProjectName "my-app" -BumpVersion major
    Bump major version (1.0.9 -> 2.0.0) and deploy

.EXAMPLE
    .\CCM\deploy-ecs.ps1 -ProjectName "my-app" -ImageTag "v1.0.0"
    Deploy specific version without bumping

.EXAMPLE
    .\CCM\deploy-ecs.ps1 -ProjectName "my-app" -SkipBuild
    Skip build step, deploy existing image from ECR

.EXAMPLE
    .\CCM\deploy-ecs.ps1 -ProjectName "my-app" -SkipDeploy -ImageTag "v1.0.0"
    Build and push image only; do not register a task definition or update the service.
    Pair with a follow-up "-SkipBuild -ImageTag v1.0.0" call to deploy from a separate CI stage.

.EXAMPLE
    .\CCM\deploy-ecs.ps1 -ProjectName "my-app" -RunMigrations
    Run database migrations before deployment

.EXAMPLE
    .\CCM\deploy-ecs.ps1 -ProjectName "my-app" -SkipBuild -ImageTag "v1.2.3-abc1234" -MigrationsOnly
    Run migrations only using the given already-built image, exit without touching the service

.EXAMPLE
    .\CCM\deploy-ecs.ps1 -ProjectName "my-app" -BumpVersion patch -RunMigrations -UsePodman
    Bump version, run migrations, and use Podman for build

.EXAMPLE
    .\CCM\deploy-ecs.ps1 -ProjectName "my-app" -VersionFile "package.json" -VersionPattern '"version":\s*"([\d.]+)"'
    Deploy using version from package.json with custom pattern

.EXAMPLE
    .\CCM\deploy-ecs.ps1 -ProjectName "my-app" -BuildArgs "REACT_APP_API_URL=https://api.example.com"
    Deploy with custom Docker build arguments

.EXAMPLE
    .\CCM\deploy-ecs.ps1 -ProjectName "my-app" -DesiredCount 2 -ContainerPort 80
    Create a new service with 2 instances listening on port 80

.EXAMPLE
    .\CCM\deploy-ecs.ps1 -ProjectName "my-app" -ExternalImage "123456789012.dkr.ecr.eu-central-1.amazonaws.com/my-app:latest"
    Deploy using an image from an external (cross-account) registry without mirroring it
    into the project's own ECR. Build phase is skipped; only task-def register and
    service update run.

.EXAMPLE
    .\CCM\deploy-ecs.ps1 -ProjectName "my-app" -ExternalImage "ghcr.io/vendor/app@sha256:abc123..." -RunMigrations
    Deploy a digest-pinned upstream image and run its migrations container first.

.NOTES
    This is a generic reusable script. The CCM folder can be shared across projects
    as a git submodule. Each project needs its own task definition files in deploy/ecs/.

    Parameters can be provided via:
      1. CLI arguments (highest priority)
      2. ecs-config.json in the project root (loaded automatically)
      3. Built-in defaults (lowest priority)

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
    [string]$ProjectName,  # Base name for AWS resources

    [Parameter(Mandatory = $false)]
    [string]$ImageTag,

    [Parameter(Mandatory = $false)]
    [ValidateSet("patch", "minor", "major")]
    [string]$BumpVersion,

    [Parameter(Mandatory = $false)]
    [string]$AwsRegion,

    [Parameter(Mandatory = $false)]
    [string]$AwsAccountId = $(if ($env:AWS_ACCOUNT_ID) { $env:AWS_ACCOUNT_ID } else { "000123456789" }),

    [Parameter(Mandatory = $false)]
    [string]$ClusterName,  # Defaults to "$ProjectName-cluster"

    [Parameter(Mandatory = $false)]
    [string]$ServiceName,  # Defaults to "$ProjectName-service"

    [Parameter(Mandatory = $false)]
    [string]$TargetGroupArn,  # Override primary target group for preview services

    [Parameter(Mandatory = $false)]
    [string]$WebUiUrl,  # Override the URL shown in the "Web UI available at" summary (e.g. PR preview URL with path prefix)

    [Parameter(Mandatory = $false)]
    [string]$VersionFile,  # File containing version string

    [Parameter(Mandatory = $false)]
    [string]$VersionPattern,  # Regex to extract version

    [Parameter(Mandatory = $false)]
    [string]$DeployDir,  # Directory containing ecs/ subfolder (auto-detected from script location)

    [Parameter(Mandatory = $false)]
    [string]$TaskDefinitionFile,  # Defaults to $DeployDir/ecs/task-definition-live.json

    [Parameter(Mandatory = $false)]
    [string]$MigrationsTaskDefFile,  # Defaults to $DeployDir/ecs/migrations-task-definition.json,

    [Parameter(Mandatory = $false)]
    [string]$DockerfilePath,

    [Parameter(Mandatory = $false)]
    [switch]$SkipBuild,

    [Parameter(Mandatory = $false)]
    [switch]$SkipDeploy,

    [Parameter(Mandatory = $false)]
    [switch]$RunMigrations,

    [Parameter(Mandatory = $false)]
    [switch]$MigrationsOnly,

    [Parameter(Mandatory = $false)]
    [switch]$UseWslc,

    [Parameter(Mandatory = $false)]
    [switch]$UsePodman,

    [Parameter(Mandatory = $false)]
    [switch]$UseDocker,

    [Parameter(Mandatory = $false)]
    [switch]$SkipLatestTag,

    [Parameter(Mandatory = $false)]
    [int]$DesiredCount,

    [Parameter(Mandatory = $false)]
    [switch]$DrainBeforeReplace,  # Use drain-and-replace deploy strategy (0/100) instead of overlap (100/200)

    [Parameter(Mandatory = $false)]
    [int]$ContainerPort,

    [Parameter(Mandatory = $false)]
    [string]$HealthCheckPath,

    [Parameter(Mandatory = $false)]
    [int]$HealthCheckGracePeriodSeconds,

    [Parameter(Mandatory = $false)]
    [string]$ContainerName,

    [Parameter(Mandatory = $false)]
    [string]$BuildTarget,  # Target stage in multi-stage Dockerfile (omit for single-stage)

    [Parameter(Mandatory = $false)]
    [string[]]$BuildArgs,

    [Parameter(Mandatory = $false)]
    [string[]]$EnvironmentOverride,

    [Parameter(Mandatory = $false)]
    [string[]]$SecretOverride,

    [Parameter(Mandatory = $false)]
    [string]$CorsAllowedOrigins,

    [Parameter(Mandatory = $false)]
    [switch]$UseTarContext,

    [Parameter(Mandatory = $false)]
    [switch]$NoCache,

    [Parameter(Mandatory = $false)]
    [string]$SecretsPrefix,  # Prefix for secrets in Secrets Manager (defaults to ProjectName)

    [Parameter(Mandatory = $false)]
    [string]$ExternalImage,  # Full image ref for non-mirrored / cross-account deploys (skips build + ECR verify)

    [Parameter(Mandatory = $false)]
    [string]$ConfigFile  # Path to ecs-config.json (auto-detected from project root)
)

$ErrorActionPreference = "Stop"

$deploy_ecs_ps1_version = "1.8.0"
$script_name = $MyInvocation.MyCommand.Name

# Auto-detect script directory and project root
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Import shared utilities
if (Test-Path $ScriptDir/utils.psm1) {
    Import-Module -Name $ScriptDir/utils.psm1 -Force
}
if (Test-Path (Join-Path $ScriptDir "CCM.psd1")) {
    Import-Module -Name (Join-Path $ScriptDir "CCM.psd1") -Force
}
$ProjectRoot = Split-Path -Parent $ScriptDir

$ccmLog = Initialize-CcmLogging
trap { Stop-CcmLogging $ccmLog; break }

$ErrorActionPreference = "Stop"

Write-Host "Deploy ECS script version ${deploy_ecs_ps1_version}"
Write-Host "Script name: $script_name"
Write-Host "Working directory: $ScriptDir"
Write-Host "Project root: $ProjectRoot"
Write-Host "Log file: $($ccmLog.LogPath)"
Write-Host -NoNewLine "PowerShell version: "
$PSVersionTable.PSVersion
Write-Host ""

# Default init so the variable is always defined, even when ecs-config.json
# is absent, since it is read later during runtime selection.
$PreferredContainerTool = ''

# ---------------------------------------------------------------------------
# Load project config file (ecs-config.json)
# CLI parameters always take precedence over config file values.
# ---------------------------------------------------------------------------
if (-not $ConfigFile) {
    $ConfigFile = Join-Path $ProjectRoot "ecs-config.json"
}

if (Test-Path $ConfigFile) {
    Write-Host "Loading project configuration from $ConfigFile" -ForegroundColor Cyan
    $fileConfig = Get-Content $ConfigFile -Raw | ConvertFrom-Json

    # Apply config values only where CLI parameter was not explicitly provided
    if (-not $PSBoundParameters.ContainsKey('ProjectName')    -and $fileConfig.ProjectName)    { $ProjectName    = $fileConfig.ProjectName }
    if (-not $PSBoundParameters.ContainsKey('AwsRegion')       -and $fileConfig.AwsRegion)       { $AwsRegion       = $fileConfig.AwsRegion }
    if (-not $PSBoundParameters.ContainsKey('ContainerPort')   -and $fileConfig.ContainerPort)   { $ContainerPort   = $fileConfig.ContainerPort }
    if (-not $PSBoundParameters.ContainsKey('SecretsPrefix')   -and $fileConfig.SecretsPrefix)   { $SecretsPrefix   = $fileConfig.SecretsPrefix }
    if (-not $PSBoundParameters.ContainsKey('ContainerName')   -and $fileConfig.ContainerName)   { $ContainerName   = $fileConfig.ContainerName }
    if (-not $PSBoundParameters.ContainsKey('DesiredCount')    -and $fileConfig.DesiredCount)    { $DesiredCount    = $fileConfig.DesiredCount }
    if (-not $PSBoundParameters.ContainsKey('DrainBeforeReplace') -and $fileConfig.DrainBeforeReplace) { $DrainBeforeReplace = [switch]::new($true) }
    if (-not $PSBoundParameters.ContainsKey('VersionFile')     -and $fileConfig.VersionFile)     { $VersionFile     = $fileConfig.VersionFile }
    if (-not $PSBoundParameters.ContainsKey('VersionPattern')  -and $fileConfig.VersionPattern)  { $VersionPattern  = $fileConfig.VersionPattern }
    if (-not $PSBoundParameters.ContainsKey('DockerfilePath')  -and $fileConfig.DockerfilePath)  { $DockerfilePath  = $fileConfig.DockerfilePath }
    if (-not $PSBoundParameters.ContainsKey('BuildTarget')     -and $fileConfig.BuildTarget)     { $BuildTarget     = $fileConfig.BuildTarget }
    if (-not $PSBoundParameters.ContainsKey('DeployDir')       -and $fileConfig.DeployDir)       { $DeployDir       = $fileConfig.DeployDir }
    if (-not $PSBoundParameters.ContainsKey('HealthCheckPath') -and $fileConfig.HealthCheckPath) { $HealthCheckPath = $fileConfig.HealthCheckPath }
    if (-not $PSBoundParameters.ContainsKey('HealthCheckGracePeriodSeconds') -and $fileConfig.HealthCheckGracePeriodSeconds) { $HealthCheckGracePeriodSeconds = $fileConfig.HealthCheckGracePeriodSeconds }
    if (-not $PSBoundParameters.ContainsKey('UseTarContext')   -and $fileConfig.UseTarContext)   { $UseTarContext   = [switch]::new($true) }
    if ($fileConfig.ContainerTool) { $PreferredContainerTool = $fileConfig.ContainerTool }
    if (-not $PSBoundParameters.ContainsKey('ExternalImage')   -and $fileConfig.ExternalImage)   { $ExternalImage   = $fileConfig.ExternalImage }

    # Route 53 / HTTPS settings
    if ($fileConfig.CustomDomainName)    { $CustomDomainName = $fileConfig.CustomDomainName }
    if ($fileConfig.ParentDomain)        { $ParentDomain = $fileConfig.ParentDomain }
    # Auto-derive CustomDomainName if ParentDomain is set but CustomDomainName is not
    if (-not $CustomDomainName -and $ParentDomain -and $ProjectName) {
        $CustomDomainName = "$ProjectName.$ParentDomain"
    }

    Write-Host "  Config loaded successfully" -ForegroundColor Green
} else {
    Write-Host "No ecs-config.json found at $ConfigFile - using CLI parameters only" -ForegroundColor Yellow
}

# Apply built-in defaults for any values still not set
if (-not $AwsRegion)      { $AwsRegion      = "eu-central-1" }
if (-not $ContainerPort -or $ContainerPort -eq 0) { $ContainerPort = 8000 }
if (-not $DesiredCount -or $DesiredCount -eq 0)    { $DesiredCount  = 1 }
if (-not $DockerfilePath) { $DockerfilePath = "Dockerfile" }
if (-not $BuildTarget)    { $BuildTarget    = "" }
if (-not $VersionFile)    { $VersionFile    = "frontend/src/components/AppLayout.jsx" }
if (-not $VersionPattern) { $VersionPattern = "APP_VERSION\s*=\s*'v([\d.]+)'" }

# Validate required parameters
if (-not $ProjectName) {
    Write-Host "" -ForegroundColor Red
    Write-Host "=========================================" -ForegroundColor Red
    Write-Host "  MISSING REQUIRED PARAMETER: ProjectName" -ForegroundColor Red
    Write-Host "  Provide via CLI or ecs-config.json" -ForegroundColor Red
    Write-Host "=========================================" -ForegroundColor Red
    throw "Missing required parameter: ProjectName. Provide via CLI or ecs-config.json."
}

# Default deploy directory is ../deploy relative to script location (CCM -> deploy)
if (-not $DeployDir) {
    $DeployDir = Join-Path $ProjectRoot "deploy"
}

# Set default paths relative to deploy directory
if (-not $TaskDefinitionFile) {
    $TaskDefinitionFile = Join-Path $DeployDir "ecs/task-definition-live.json"
}
if (-not $MigrationsTaskDefFile) {
    $MigrationsTaskDefFile = Join-Path $DeployDir "ecs/migrations-task-definition.json"
}

# Set defaults for derived resource names
if (-not $ClusterName) {
    $ClusterName = "$ProjectName-cluster"
}
if (-not $ServiceName) {
    $ServiceName = "$ProjectName-service"
}
if (-not $ContainerName) {
    $ContainerName = $ProjectName
}

# Auto-resolve SecretsPrefix from infrastructure config, or default to ProjectName
if (-not $SecretsPrefix) {
    $infraConfigForSecrets = Join-Path $DeployDir "ecs/infrastructure-config.json"
    if (Test-Path $infraConfigForSecrets) {
        $infraJson = Get-Content $infraConfigForSecrets -Raw | ConvertFrom-Json
        if ($infraJson.SecretsPrefix) {
            $SecretsPrefix = $infraJson.SecretsPrefix
            Write-Host "Resolved SecretsPrefix from infrastructure config: $SecretsPrefix" -ForegroundColor Cyan
        }
    }
    if (-not $SecretsPrefix) {
        $SecretsPrefix = $ProjectName
        Write-Host "Using default SecretsPrefix: $SecretsPrefix" -ForegroundColor Cyan
    }
}

# Auto-detect version file if default doesn't exist and user didn't specify one
if (-not $PSBoundParameters.ContainsKey('VersionFile') -and -not (Test-Path $VersionFile)) {
    $autoDetectFiles = @(
        @{ Path = "web/index.html"; Pattern = "APP_VERSION\s*=\s*'v([\d.]+)'" },
        @{ Path = "frontend/src/components/common/Layout.tsx"; Pattern = "APP_VERSION\s*=\s*'v([\d.]+)'" },
        @{ Path = "frontend/src/components/Layout.tsx"; Pattern = "APP_VERSION\s*=\s*'v([\d.]+)'" },
        @{ Path = "frontend/src/components/AppLayout.jsx"; Pattern = "APP_VERSION\s*=\s*'v([\d.]+)'" },
        @{ Path = "frontend/src/App.jsx"; Pattern = "APP_VERSION\s*=\s*'v([\d.]+)'" },
        @{ Path = "version.json"; Pattern = '"version":\s*"([\d.]+)"' },
        @{ Path = "package.json"; Pattern = '"version":\s*"([\d.]+)"' },
        @{ Path = "pyproject.toml"; Pattern = '(?m)^version\s*=\s*"([\d.]+)"' }
    )
    foreach ($candidate in $autoDetectFiles) {
        if (Test-Path $candidate.Path) {
            $VersionFile = $candidate.Path
            $VersionPattern = $candidate.Pattern
            Write-Host "Auto-detected version file: $VersionFile" -ForegroundColor Cyan
            break
        }
    }
}

$EcrRepository = "$AwsAccountId.dkr.ecr.$AwsRegion.amazonaws.com/$ProjectName"

# Resolve container tool: explicit flag > ecs-config ContainerTool > auto-detect (wslc, then docker, then podman)
$SelectedRuntimeSwitches = @($UseWslc, $UseDocker, $UsePodman) | Where-Object { $_ }
if ($SelectedRuntimeSwitches.Count -gt 1) {
    Write-Error "Specify at most one of -UseWslc, -UseDocker, -UsePodman"
    exit 1
}

if ($SkipBuild -and $SkipDeploy) {
    Write-Error "Cannot specify both -SkipBuild and -SkipDeploy: nothing would happen."
    exit 1
}

if ($SkipDeploy -and $MigrationsOnly) {
    Write-Error "Cannot specify both -SkipDeploy and -MigrationsOnly: -SkipDeploy exits before migrations run."
    exit 1
}

if ($SkipDeploy -and $RunMigrations) {
    Write-Error "Cannot specify both -SkipDeploy and -RunMigrations: -SkipDeploy exits before migrations run."
    exit 1
}

if ($ExternalImage -and $BumpVersion) {
    Write-Error "Cannot specify both -ExternalImage and -BumpVersion: external images are not versioned by this script."
    exit 1
}

if ($ExternalImage -and $SkipDeploy) {
    Write-Error "Cannot specify both -ExternalImage and -SkipDeploy: there is no build to run, and the deploy is the only step."
    exit 1
}

# -ExternalImage implies -SkipBuild for all downstream logic. The container
# tool selection below is skipped entirely when external, since no build runs.
$EffectiveSkipBuild = $SkipBuild -or [bool]$ExternalImage

if ($ExternalImage) {
    Write-Host "ExternalImage mode: build phase will be skipped (image source: $ExternalImage)" -ForegroundColor Cyan
}

if ($ExternalImage) {
    # External image: no container build tool is needed.
    $ContainerTool = $null
} else {
    # CLI switch wins; then ecs-config ContainerTool; then auto-detect (wslc -> docker -> podman).
    $PreferRuntime = ''
    if ($UseWslc)                       { $PreferRuntime = 'wslc' }
    elseif ($UseDocker)                 { $PreferRuntime = 'docker' }
    elseif ($UsePodman)                 { $PreferRuntime = 'podman' }
    elseif ($PreferredContainerTool)    { $PreferRuntime = $PreferredContainerTool }

    try {
        $runtime = Resolve-CcmContainerRuntime -Prefer $PreferRuntime
    } catch {
        Write-Error $_.Exception.Message
        exit 1
    }
    $ContainerTool = $runtime.Command
    Write-Host "Using container runtime: $ContainerTool" -ForegroundColor Cyan
}

# Validate AWS credentials before starting any work
Assert-AwsSsoSession -AwsRegion $AwsRegion

# Resolve AWS account id safely (avoid deploying to a placeholder account id)
if (-not $AwsAccountId -or $AwsAccountId -eq "000123456789") {
    $AwsAccountId = aws sts get-caller-identity --query Account --output text --region $AwsRegion
}

$EcrRegistry = "$AwsAccountId.dkr.ecr.$AwsRegion.amazonaws.com"
$EcrRepository = "$EcrRegistry/$ProjectName"

# Function to read version from version file
function Get-AppVersion {
    if (-not (Test-Path $VersionFile)) {
        Write-Warning "Version file not found: $VersionFile"
        return "1.0.0"
    }
    $content = Get-Content $VersionFile -Raw
    if ($content -match $VersionPattern) {
        return $matches[1]
    }
    Write-Warning "Could not find version pattern in $VersionFile, using default"
    return "1.0.0"
}

# Function to update version in version file
function Set-AppVersion {
    param([string]$Version)
    if (-not (Test-Path $VersionFile)) {
        Write-Warning "Version file not found, cannot update version: $VersionFile"
        return
    }
    $content = Get-Content $VersionFile -Raw

    # Use the original VersionPattern which has the version in a capture group
    # We match the full pattern and rebuild with the new version
    if ($content -match $VersionPattern) {
        $oldVersionMatch = $matches[0]  # Full match including version
        $oldVersion = $matches[1]        # Just the captured version number

        # Replace the old version with new version in the matched string
        $newVersionMatch = $oldVersionMatch -replace [regex]::Escape($oldVersion), $Version

        # Replace in content
        $newContent = $content -replace [regex]::Escape($oldVersionMatch), $newVersionMatch
        $newContent | Set-Content $VersionFile -NoNewline
        Write-Host "Updated $VersionFile to v$Version" -ForegroundColor Cyan
    } else {
        Write-Warning "Could not find version pattern in $VersionFile to update"
    }
}

# Function to bump version
function Get-BumpedVersion {
    param(
        [string]$CurrentVersion,
        [string]$BumpType
    )
    $parts = $CurrentVersion.Split('.')
    $major = [int]$parts[0]
    $minor = [int]$parts[1]
    $patch = [int]$parts[2]

    switch ($BumpType) {
        "major" { $major++; $minor = 0; $patch = 0 }
        "minor" { $minor++; $patch = 0 }
        "patch" { $patch++ }
    }

    return "$major.$minor.$patch"
}

# Determine the version to deploy
if ($ExternalImage) {
    # External images are not versioned by this script. Derive a display-only
    # tag from the ref so subsequent log lines and the placeholder substitution
    # in the task definition have something to work with. The ImageTag is NOT
    # used to construct the image path when -ExternalImage is set.
    if ($ExternalImage -match '@sha256:([0-9a-fA-F]{6,})') {
        $ImageTag = "sha-" + $matches[1].Substring(0, [Math]::Min(12, $matches[1].Length))
    } elseif ($ExternalImage -match ':([^:/@]+)$') {
        $ImageTag = $matches[1]
    } else {
        $ImageTag = "latest"
    }
    $Version = $ImageTag -replace '^v', ''
    Write-Host "External image tag (display): $ImageTag" -ForegroundColor Cyan
} elseif ($ImageTag) {
    # Preserve explicit image tags verbatim. Some CI flows use non-version tags
    # such as pr-<id>-<sha>; only Version is normalized for display/fallbacks.
    $Version = $ImageTag -replace '^v', ''
    Write-Host "Using explicit image tag: $ImageTag" -ForegroundColor Cyan
} else {
    # Read current version from version file
    $Version = Get-AppVersion
    Write-Host "Current version in $($VersionFile): v$Version" -ForegroundColor Cyan

    if ($BumpVersion) {
        $Version = Get-BumpedVersion -CurrentVersion $Version -BumpType $BumpVersion
        Write-Host "Bumping $BumpVersion version to: v$Version" -ForegroundColor Cyan
        Set-AppVersion -Version $Version
    }
}

if (-not $ExternalImage -and -not $ImageTag) {
    $ImageTag = "v$Version"
}

Write-Host "=== $ProjectName ECS Deployment ===" -ForegroundColor Cyan
Write-Host "Project: $ProjectName"
Write-Host "Region: $AwsRegion"
Write-Host "Account: $AwsAccountId"
if ($ExternalImage) {
    Write-Host "External Image: $ExternalImage"
} else {
    Write-Host "Image Tag: $ImageTag"
}
Write-Host "Cluster: $ClusterName"
Write-Host "Service: $ServiceName"
if ($TargetGroupArn) { Write-Host "Target Group Override: $TargetGroupArn" }
if ($ContainerTool) { Write-Host "Container Tool: $ContainerTool" }
Write-Host ""

# Run project-specific pre-build hook if present.
#
# Only when an image is actually going to be built. The hook exists to prepare
# the build context -- fetch weights, generate assets, stage a large artifact --
# so running it on a deploy-only invocation (-SkipBuild, or -ExternalImage, both
# of which the PR-preview and Deploy stages use) does work whose output is
# immediately discarded, and fails outright whenever that work needs something
# only the build stage is given. A repo whose hook fetches a model with a
# credential passed via `extraEnv` deployed fine and then died in PreviewDeploy,
# which gets no such credential and had no reason to.
$preBuildScript = Join-Path $ProjectRoot "pre-build.ps1"
if (-not $EffectiveSkipBuild -and (Test-Path $preBuildScript)) {
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

# Step 1: Build and Push Image
if (-not $EffectiveSkipBuild) {
    Write-Host "Step 1: Building container image..." -ForegroundColor Yellow

    # Build the image. APP_VERSION is injected from the version already resolved
    # above, so an application can report the same number its image carries
    # without every project wiring that up for itself. See
    # Get-CcmImageBuildArgs for why this happens here and not in a pipeline.
    $buildArgList = Get-CcmImageBuildArgs -Version $Version -BuildArgs $BuildArgs
    if ($buildArgList) {
        Write-Host "Build args: $($buildArgList -join ' ')" -ForegroundColor Cyan
    }

    # Ensure custom-ca.crt exists for Dockerfile COPY
    Install-CustomCaCert -TargetDir $ProjectRoot

    $targetArgs = @()
    if ($BuildTarget) { $targetArgs = @("--target", $BuildTarget) }

    # Wrapped in a local function so the corrupted-layer recovery path below can
    # rebuild identically with --no-cache, without duplicating the tar-context branch.
    function Invoke-CcmImageBuild {
        param([switch]$ForceNoCache)

        $cacheArgs = @()
        if ($NoCache -or $ForceNoCache) { $cacheArgs = @("--no-cache") }

        # Optional tar pipe workaround for "io: read/write on closed pipe" errors with Podman.
        # Enable per-repo with -UseTarContext or "UseTarContext": true in ecs-config.json.
        if ($UseTarContext -and $ContainerTool -eq "podman") {
            Write-Host "  Using tar pipe to exclude .git and transient files from build context..." -ForegroundColor Gray
            # Excluding deploy-ecs*.log is critical: the current run's transcript target
            # grows while tar streams it, triggering "archive/tar: write too long" from podman.
            tar.exe -c `
                --exclude=.git `
                --exclude=.vs `
                --exclude=.idea `
                --exclude=.vscode `
                --exclude='deploy-ecs*.log' `
                --exclude='*.log' `
                -f - . |
                & $ContainerTool build @targetArgs @cacheArgs -t "${ProjectName}:${ImageTag}" -f $DockerfilePath @buildArgList -
        } else {
            & $ContainerTool build @targetArgs @cacheArgs -t "${ProjectName}:${ImageTag}" -f $DockerfilePath @buildArgList .
        }
    }

    if ($NoCache) { Write-Host "  -NoCache: ignoring all cached layers." -ForegroundColor Gray }
    Invoke-CcmImageBuild
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to build container image"
        exit 1
    }

    # Tag for ECR
    & $ContainerTool tag "${ProjectName}:${ImageTag}" "${EcrRepository}:${ImageTag}"

    # Login to ECR (clear stale credentials first to avoid 403 errors)
    Write-Host "Logging in to ECR..." -ForegroundColor Yellow
    if ($ContainerTool -eq "podman") {
        $authFileCandidates = @()
        if ($env:XDG_RUNTIME_DIR) {
            $authFileCandidates += [IO.Path]::Combine($env:XDG_RUNTIME_DIR, 'containers', 'auth.json')
        }
        if ($HOME) {
            $authFileCandidates += [IO.Path]::Combine($HOME, '.config', 'containers', 'auth.json')
        }
        foreach ($authFile in $authFileCandidates) {
            if (Test-Path $authFile) {
                Remove-Item $authFile -Force -ErrorAction SilentlyContinue
                Write-Host "Cleared stale Podman credentials ($authFile)" -ForegroundColor Gray
            }
        }
    }
    $ecrPassword = aws ecr get-login-password --region $AwsRegion
    $ecrPassword | & $ContainerTool login --username AWS --password-stdin $EcrRegistry
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to login to ECR"
        exit 1
    }

    # Push to ECR (use gzip compression with Podman to avoid blob reuse issues)
    Write-Host "Pushing image to ECR..." -ForegroundColor Yellow

    # Output is captured (while still streaming to the log) so the corrupted-layer
    # signature can be detected below. The exit code is stashed inside the function:
    # reading $LASTEXITCODE after the caller's pipeline is not reliable.
    function Invoke-CcmImagePush {
        if ($ContainerTool -eq "podman") {
            & $ContainerTool push --compression-format gzip --force-compression --retry 5 --retry-delay 10s "${EcrRepository}:${ImageTag}" 2>&1
        } else {
            & $ContainerTool push "${EcrRepository}:${ImageTag}" 2>&1
        }
        $script:pushExitCode = $LASTEXITCODE
    }

    $pushOutput = @()
    Invoke-CcmImagePush | ForEach-Object { Write-Host $_; $pushOutput += "$_" }

    # A corrupted local layer surfaces only here, when the layer is read back to be
    # uploaded ("reading blob ...: file integrity checksum failed for <path>"). It is
    # local rather than a registry error, and deterministic - podman's own --retry
    # cannot recover it, because every attempt reuses the same damaged cached layer.
    # Rebuilding without the cache produces a fresh layer, so retry exactly once
    # instead of failing the pipeline over agent-side damage.
    if ($pushExitCode -ne 0 -and ($pushOutput -match 'file integrity checksum failed') -and -not $NoCache) {
        Write-Warning "Push failed while reading a local layer - this agent's image cache is corrupted (typically a disk-full event), not a registry problem."
        Write-Warning "Rebuilding with --no-cache and retrying the push once. To clear the damaged layer for good, run 'podman image prune -a -f' on the agent."
        Invoke-CcmImageBuild -ForceNoCache
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to rebuild container image with --no-cache"
            exit 1
        }
        & $ContainerTool tag "${ProjectName}:${ImageTag}" "${EcrRepository}:${ImageTag}"
        $pushOutput = @()
        Invoke-CcmImagePush | ForEach-Object { Write-Host $_; $pushOutput += "$_" }
    }

    if ($pushExitCode -ne 0) {
        if ($pushOutput -match 'file integrity checksum failed') {
            Write-Error "Failed to push image to ECR: a local layer is still corrupted after a --no-cache rebuild. Clear the agent's image store with 'podman image prune -a -f'."
        } else {
            Write-Error "Failed to push image to ECR"
        }
        exit 1
    }

    Write-Host "Image pushed successfully: ${EcrRepository}:${ImageTag}" -ForegroundColor Green

    # Tag as 'latest' in ECR (unless skipped)
    if (-not $SkipLatestTag) {
        Write-Host "Tagging image as 'latest'..." -ForegroundColor Yellow
        $manifest = aws ecr batch-get-image `
            --repository-name $ProjectName `
            --image-ids "imageTag=$ImageTag" `
            --region $AwsRegion `
            --query 'images[0].imageManifest' `
            --output text

        $tempManifest = [System.IO.Path]::GetTempFileName()
        $manifest | Set-Content $tempManifest -NoNewline
        aws ecr put-image `
            --repository-name $ProjectName `
            --image-tag "latest" `
            --image-manifest "file://$tempManifest" `
            --region $AwsRegion | Out-Null
        Remove-Item $tempManifest -ErrorAction SilentlyContinue

        if ($LASTEXITCODE -eq 0) {
            Write-Host "Image also tagged as 'latest'" -ForegroundColor Green
        } else {
            Write-Warning "Failed to tag image as 'latest' (non-fatal)"
        }
    } else {
        Write-Host "Skipping 'latest' tag (use without -SkipLatestTag to tag)" -ForegroundColor Yellow
    }
}
elseif ($ExternalImage) {
    # External image: nothing to build, nothing to verify in the project ECR.
    # The image must be pullable from the configured external registry at
    # task-start time. The execution role's cross-account ECR policy + the
    # external registry's repository policy are caller-managed (out of scope).
    Write-Host "Step 1: Skipping build (using external image: $ExternalImage)" -ForegroundColor Yellow
}
else {
    Write-Host "Step 1: Skipping build (using existing image)" -ForegroundColor Yellow

    # Verify the image exists in ECR when skipping build
    Write-Host "Verifying image exists in ECR: ${ImageTag}..." -ForegroundColor Yellow
    $imageExists = aws ecr describe-images `
        --repository-name $ProjectName `
        --image-ids "imageTag=$ImageTag" `
        --region $AwsRegion 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Red
        Write-Host "Image not found in ECR: ${ImageTag}" -ForegroundColor Red
        Write-Host "========================================" -ForegroundColor Red
        Write-Host ""
        Write-Host "Available images in ECR:" -ForegroundColor Yellow
        aws ecr describe-images --repository-name $ProjectName --region $AwsRegion --query 'imageDetails[*].imageTags[]' --output text
        Write-Host ""
        Write-Host "Options:" -ForegroundColor Yellow
        Write-Host "  1. Use an existing tag: -ImageTag v1.1.1" -ForegroundColor Cyan
        Write-Host "  2. Remove -SkipBuild to build and push the image" -ForegroundColor Cyan
        Write-Host ""
        exit 1
    }
    Write-Host "Image verified: ${EcrRepository}:${ImageTag}" -ForegroundColor Green
}

if ($SkipDeploy) {
    Write-Host ""
    Write-Host "=== Build complete (deploy skipped) ===" -ForegroundColor Green
    Write-Host "Image: ${EcrRepository}:${ImageTag}"
    Write-Host "Use this tag in a follow-up deploy: -SkipBuild -ImageTag ${ImageTag}"
    exit 0
}

# Step 2: Run Database Migrations (if requested).
# -MigrationsOnly implies -RunMigrations: pipelines can pass a single switch.
if ($MigrationsOnly) {
    $RunMigrations = $true
}
if ($RunMigrations) {
    Write-Host "Step 2: Running database migrations..." -ForegroundColor Yellow

    if (-not (Test-Path $MigrationsTaskDefFile)) {
        if ($MigrationsOnly) {
            Write-Error "Migrations task definition not found: $MigrationsTaskDefFile (required by -MigrationsOnly)"
                exit 1
        }
        Write-Warning "Migrations task definition not found: $MigrationsTaskDefFile"
        Write-Warning "Skipping migrations..."
    } else {
        # Read and substitute variables in migrations task definition
        $migrationsTaskDef = Get-Content $MigrationsTaskDefFile -Raw
        $migrationsTaskDef = $migrationsTaskDef -replace '\$\{AWS_ACCOUNT_ID\}', $AwsAccountId
        $migrationsTaskDef = $migrationsTaskDef -replace '\$\{AWS_REGION\}', $AwsRegion
        $migrationsTaskDef = $migrationsTaskDef -replace '\$\{IMAGE_TAG\}', $ImageTag
        $migrationsTaskDef = $migrationsTaskDef -replace '\$\{PROJECT_NAME\}', $ProjectName
        $migrationsTaskDef = $migrationsTaskDef -replace '\$\{SECRETS_PREFIX\}', $SecretsPrefix

        # Resolve ${..._SECRET_ARN} placeholders the same way the main task definition
        # does (see Step 3 below). Without this, a migrations task def that references
        # a secret (e.g. DATABASE_URL) ships an unresolved placeholder to
        # register-task-definition, which AWS rejects as an invalid parameter name.
        $migrationsTaskDef = Resolve-CcmEcsSecretArns -TaskDefinitionJson $migrationsTaskDef -SecretsPrefix $SecretsPrefix -AwsRegion $AwsRegion

        # External-image override: any container whose image now points at the
        # project's canonical ECR path is redirected to $ExternalImage.
        # Containers that reference a different registry are left untouched.
        if ($ExternalImage) {
            $canonicalPrefix = "$AwsAccountId.dkr.ecr.$AwsRegion.amazonaws.com/$ProjectName" + ":"
            $mObj = $migrationsTaskDef | ConvertFrom-Json
            foreach ($c in $mObj.containerDefinitions) {
                if ($c.image -and $c.image.StartsWith($canonicalPrefix)) {
                    Write-Host "  Migrations: redirecting container '$($c.name)' image to external ref" -ForegroundColor Cyan
                    $c.image = $ExternalImage
                }
            }
            $migrationsTaskDef = $mObj | ConvertTo-Json -Depth 20
        }

        # Apply the same environment/secret overrides to the migrations task that
        # are applied to the service task further below. Without this, a preview
        # that redirects DATABASE_URL via -SecretOverride would still run its
        # migrations against the BASE (e.g. production) database: the migrations
        # task is registered here, BEFORE the service-task override block. Loop
        # over every container by name (migration task defs are typically single-
        # container, but stay general) so the override lands wherever it is used.
        if (($EnvironmentOverride -and $EnvironmentOverride.Count -gt 0) -or ($SecretOverride -and $SecretOverride.Count -gt 0)) {
            $migContainers = @(($migrationsTaskDef | ConvertFrom-Json).containerDefinitions | ForEach-Object { $_.name })
            foreach ($migContainerName in $migContainers) {
                $migrationsTaskDef = Set-CcmEcsTaskDefinitionOverrides `
                    -TaskDefinitionJson $migrationsTaskDef `
                    -ContainerName $migContainerName `
                    -EnvironmentOverride $EnvironmentOverride `
                    -SecretOverride $SecretOverride
            }
            Write-Host "  Applied env/secret overrides to migrations task ($($migContainers.Count) container(s))" -ForegroundColor Cyan
        }

        # Write temp file
        $tempMigrationsFile = [System.IO.Path]::GetTempFileName()
        $migrationsTaskDef | Set-Content $tempMigrationsFile

        # Register task definition
        $migrationsTaskArn = aws ecs register-task-definition `
            --cli-input-json "file://$tempMigrationsFile" `
            --region $AwsRegion `
            --query 'taskDefinition.taskDefinitionArn' `
            --output text

        Remove-Item $tempMigrationsFile

        Write-Host "Registered migrations task: $migrationsTaskArn"

        # Resolve network configuration: prefer existing service, fallback to deploy/ecs/infrastructure-config.json
        $subnets = @()
        $securityGroups = @()

        try {
            $serviceConfig = aws ecs describe-services `
                --cluster $ClusterName `
                --services $ServiceName `
                --region $AwsRegion `
                --query 'services[0].networkConfiguration.awsvpcConfiguration' `
                --output json | ConvertFrom-Json

            if ($serviceConfig -and $serviceConfig.subnets -and $serviceConfig.securityGroups) {
                $subnets = @($serviceConfig.subnets)
                $securityGroups = @($serviceConfig.securityGroups)
            }
        } catch {
            # ignore and fall through
        }

        if ($subnets.Count -eq 0 -or $securityGroups.Count -eq 0) {
            $infraConfigPath = Join-Path $DeployDir "ecs/infrastructure-config.json"
            if (-not (Test-Path $infraConfigPath)) {
                Write-Error "Service network config not available and infra config not found: $infraConfigPath"
                exit 1
            }

            $infra = Get-Content $infraConfigPath -Raw | ConvertFrom-Json
            $subnets = @($infra.Subnets | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
            $securityGroups = @($infra.EcsSecurityGroup)
        }

        if ($subnets.Count -eq 0 -or $securityGroups.Count -eq 0) {
            Write-Error "Could not resolve subnets/security groups for migrations task"
            exit 1
        }

        # Run the migrations task (use the registered task definition ARN)
        $runTaskOutput = aws ecs run-task `
            --cluster $ClusterName `
            --task-definition $migrationsTaskArn `
            --launch-type FARGATE `
            --network-configuration "awsvpcConfiguration={subnets=[$($subnets -join ',')],securityGroups=[$($securityGroups -join ',')],assignPublicIp=DISABLED}" `
            --region $AwsRegion `
            --output json 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Host ""
            Write-Host "Failed to start migrations task!" -ForegroundColor Red
            Write-Host "Error: $runTaskOutput" -ForegroundColor Red
            Write-Host ""
            Write-Host "Common causes:" -ForegroundColor Yellow
            Write-Host "  - IAM role trust relationship not configured correctly" -ForegroundColor Yellow
            Write-Host "  - Task execution role missing required permissions" -ForegroundColor Yellow
            Write-Host "  - Check that 'ecs-tasks.amazonaws.com' is in the role's trust policy" -ForegroundColor Yellow
            Write-Host ""
                exit 1
        }

        $runTaskJson = $runTaskOutput | ConvertFrom-Json
        $taskArn = $runTaskJson.tasks[0].taskArn

        if (-not $taskArn -or $taskArn -eq "None") {
            Write-Host ""
            Write-Host "Failed to start migrations task - no task ARN returned!" -ForegroundColor Red
            if ($runTaskJson.failures) {
                Write-Host "Failures:" -ForegroundColor Red
                $runTaskJson.failures | ForEach-Object {
                    Write-Host "  - $($_.reason)" -ForegroundColor Red
                }
            }
                exit 1
        }

        Write-Host "Started migrations task: $taskArn"

        # Wait for migrations to complete
        Write-Host "Waiting for migrations to complete..."
        aws ecs wait tasks-stopped --cluster $ClusterName --tasks $taskArn --region $AwsRegion

        # Check exit code and get detailed status
        $taskDetails = aws ecs describe-tasks `
            --cluster $ClusterName `
            --tasks $taskArn `
            --region $AwsRegion `
            --output json | ConvertFrom-Json

        $taskStatus = $taskDetails.tasks[0].containers[0].exitCode
        $stoppedReason = $taskDetails.tasks[0].stoppedReason
        $containerReason = $taskDetails.tasks[0].containers[0].reason

        if ($taskStatus -ne 0) {
            Write-Host ""
            Write-Host "========================================" -ForegroundColor Red
            Write-Host "Migrations failed!" -ForegroundColor Red
            Write-Host "========================================" -ForegroundColor Red
            Write-Host "Exit code: $taskStatus" -ForegroundColor Red
            if ($stoppedReason) {
                Write-Host "Stopped reason: $stoppedReason" -ForegroundColor Red
            }
            if ($containerReason) {
                Write-Host "Container reason: $containerReason" -ForegroundColor Red
            }
            Write-Host ""
            Write-Host "Check CloudWatch logs for details:" -ForegroundColor Yellow
            Write-Host "  Log group: /ecs/$ProjectName-migrations" -ForegroundColor Cyan
            Write-Host ""
                exit 1
        }

        Write-Host "Migrations completed successfully!" -ForegroundColor Green
    }

    if ($MigrationsOnly) {
        Write-Host ""
        Write-Host "-MigrationsOnly specified; exiting without updating the ECS service." -ForegroundColor Cyan
        exit 0
    }
}
else {
    Write-Host "Step 2: Skipping migrations (use -RunMigrations to run)" -ForegroundColor Yellow
}

# Step 3: Update Task Definition
Write-Host "Step 3: Registering task definition..." -ForegroundColor Yellow

if (-not (Test-Path $TaskDefinitionFile)) {
    Write-Error "Task definition file not found: $TaskDefinitionFile"
    exit 1
}

# Read task-definition file
$taskDef = Get-Content $TaskDefinitionFile -Raw

# Resolve secret ARNs from Secrets Manager (ECS requires full ARN with random suffix)
$taskDef = Resolve-CcmEcsSecretArns -TaskDefinitionJson $taskDef -SecretsPrefix $SecretsPrefix -AwsRegion $AwsRegion

# Update the image tag (handles various image name patterns)
$imagePattern = "(" + [regex]::Escape($ProjectName) + ":)v[\d.]+"
$taskDef = $taskDef -replace $imagePattern, "`${1}${ImageTag}"
# Also handle generic image tag placeholder
$taskDef = $taskDef -replace '\$\{IMAGE_TAG\}', $ImageTag
$taskDef = $taskDef -replace '\$\{AWS_ACCOUNT_ID\}', $AwsAccountId
$taskDef = $taskDef -replace '\$\{AWS_REGION\}', $AwsRegion
$taskDef = $taskDef -replace '\$\{PROJECT_NAME\}', $ProjectName
$taskDef = $taskDef -replace '\$\{SECRETS_PREFIX\}', $SecretsPrefix

# External-image override: after placeholders are rendered, any container whose
# image now resolves to the project's canonical ECR path is redirected to
# $ExternalImage. Containers that reference a different registry (e.g. a
# supplier hardcoded literal, or a sidecar from another repo) are left alone.
# This runs only when -ExternalImage is set, so default behaviour is unchanged.
if ($ExternalImage) {
    $canonicalPrefix = "$AwsAccountId.dkr.ecr.$AwsRegion.amazonaws.com/$ProjectName" + ":"
    $tdObj = $taskDef | ConvertFrom-Json
    $rewroteAny = $false
    foreach ($c in $tdObj.containerDefinitions) {
        if ($c.image -and $c.image.StartsWith($canonicalPrefix)) {
            Write-Host "  External image override: container '$($c.name)' -> $ExternalImage" -ForegroundColor Cyan
            $c.image = $ExternalImage
            $rewroteAny = $true
        }
    }
    if (-not $rewroteAny) {
        Write-Host "  External image mode: task definition already references a non-project registry; no override needed." -ForegroundColor Gray
    }
    $taskDef = $tdObj | ConvertTo-Json -Depth 20
}

# Resolve EFS, EFS Access Point, and S3 placeholders from infrastructure config
$infraConfigForEfs = Join-Path $DeployDir "ecs/infrastructure-config.json"
if ((Test-Path $infraConfigForEfs) -and ($taskDef -match '\$\{EFS_' -or $taskDef -match '\$\{S3_BUCKET_NAME\}')) {
    $infraEfs = Get-Content $infraConfigForEfs -Raw | ConvertFrom-Json
    if ($infraEfs.EfsFileSystemId) {
        $taskDef = $taskDef -replace '\$\{EFS_FILE_SYSTEM_ID\}', $infraEfs.EfsFileSystemId
        Write-Host "  Resolved EFS_FILE_SYSTEM_ID: $($infraEfs.EfsFileSystemId)" -ForegroundColor Cyan
    }
    # Resolve EFS access point placeholders dynamically.
    # Convention: infrastructure-config.json key "shared-content" -> placeholder ${EFS_AP_SHARED_CONTENT}
    # (key is uppercased, hyphens replaced with underscores, prefixed with EFS_AP_)
    if ($infraEfs.EfsAccessPoints) {
        foreach ($prop in $infraEfs.EfsAccessPoints.PSObject.Properties) {
            $placeholder = 'EFS_AP_' + ($prop.Name.ToUpper() -replace '-', '_')
            $pattern = '\$\{' + $placeholder + '\}'
            if ($taskDef -match $pattern) {
                $taskDef = $taskDef -replace $pattern, $prop.Value
                Write-Host "  Resolved ${placeholder}: $($prop.Value)" -ForegroundColor Cyan
            }
        }
    }
    if ($infraEfs.S3BucketName) {
        $taskDef = $taskDef -replace '\$\{S3_BUCKET_NAME\}', $infraEfs.S3BucketName
        Write-Host "  Resolved S3_BUCKET_NAME: $($infraEfs.S3BucketName)" -ForegroundColor Cyan
    }
}

# Resolve CORS_ALLOWED_ORIGINS from infrastructure config (protocol-aware)
if ($CorsAllowedOrigins) {
    $taskDef = $taskDef -replace '\$\{CORS_ALLOWED_ORIGINS\}', $CorsAllowedOrigins
    $taskDef = $taskDef -replace '\$\{ALLOWED_ORIGINS\}', $CorsAllowedOrigins
    Write-Host "  Resolved CORS placeholders from -CorsAllowedOrigins: $CorsAllowedOrigins" -ForegroundColor Cyan
} elseif ($taskDef -match '\$\{CORS_ALLOWED_ORIGINS\}') {
    $infraConfigForCors = Join-Path $DeployDir "ecs/infrastructure-config.json"
    $corsOrigin = ""
    if (Test-Path $infraConfigForCors) {
        $infraCors = Get-Content $infraConfigForCors -Raw | ConvertFrom-Json
        $protocol = if ($infraCors.ListenerProtocol -eq "HTTPS") { "https" } else { "http" }
        # Prefer custom domain name over raw ALB DNS
        $hostname = if ($CustomDomainName) { $CustomDomainName } elseif ($infraCors.CustomDomainName) { $infraCors.CustomDomainName } elseif ($infraCors.NlbDns) { $infraCors.NlbDns } else { $infraCors.AlbDns }
        if ($hostname) {
            $corsOrigin = "${protocol}://${hostname}"
        }
    }
    if ($corsOrigin) {
        $taskDef = $taskDef -replace '\$\{CORS_ALLOWED_ORIGINS\}', $corsOrigin
        Write-Host "  Resolved CORS_ALLOWED_ORIGINS: $corsOrigin" -ForegroundColor Cyan
    } else {
        Write-Host "  WARNING: Could not resolve CORS_ALLOWED_ORIGINS (no AlbDns in infrastructure config)" -ForegroundColor Yellow
        $taskDef = $taskDef -replace '\$\{CORS_ALLOWED_ORIGINS\}', '*'
    }
}

if (($EnvironmentOverride -and $EnvironmentOverride.Count -gt 0) -or ($SecretOverride -and $SecretOverride.Count -gt 0)) {
    Write-Host "  Applying task definition overrides for container '$ContainerName'" -ForegroundColor Cyan
    $taskDef = Set-CcmEcsTaskDefinitionOverrides `
        -TaskDefinitionJson $taskDef `
        -ContainerName $ContainerName `
        -EnvironmentOverride $EnvironmentOverride `
        -SecretOverride $SecretOverride
}

# Write temp file
$tempFile = [System.IO.Path]::GetTempFileName()
$taskDef | Set-Content $tempFile

# Register task definition
$taskDefArn = aws ecs register-task-definition `
    --cli-input-json "file://$tempFile" `
    --region $AwsRegion `
    --query 'taskDefinition.taskDefinitionArn' `
    --output text

Remove-Item $tempFile

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to register task definition"
    exit 1
}

Write-Host "Registered task definition: $taskDefArn" -ForegroundColor Green

# Step 4: Update or Create ECS Service
Write-Host "Step 4: Updating ECS service..." -ForegroundColor Yellow

# Health-check grace period. ecs-config.json's HealthCheckGracePeriodSeconds (or the
# -HealthCheckGracePeriodSeconds param) is the single source of truth, applied on BOTH
# create and update so it never drifts. When unset, create uses the historical 180s
# default and update leaves the service's existing value untouched (unchanged behaviour
# for projects that don't configure it).
$createGraceSeconds = if ($HealthCheckGracePeriodSeconds -gt 0) { $HealthCheckGracePeriodSeconds } else { 180 }
$graceUpdateArgs = @()
if ($HealthCheckGracePeriodSeconds -gt 0) {
    $graceUpdateArgs = @('--health-check-grace-period-seconds', "$HealthCheckGracePeriodSeconds")
    Write-Host "  Health-check grace period: ${HealthCheckGracePeriodSeconds}s (applied on create + update)" -ForegroundColor Cyan
}

# An explicit -TargetGroupArn marks an ephemeral (PR preview) service. Capture the
# flag BEFORE the create path below, which reassigns $targetGroupArn — PowerShell
# variable names are case-insensitive, so that assignment clobbers the parameter.
$isTargetGroupOverride = [bool]$TargetGroupArn

# Read ExposedTargetGroups from infra config (used by both create and update paths)
$exposedTargetGroups = @()
$infraConfigPathForLb = Join-Path $DeployDir "ecs/infrastructure-config.json"
if (Test-Path $infraConfigPathForLb) {
    $infraForLb = Get-Content $infraConfigPathForLb -Raw | ConvertFrom-Json
    if ($infraForLb.ExposedTargetGroups) {
        $exposedTargetGroups = @($infraForLb.ExposedTargetGroups)
    }
}
if ($isTargetGroupOverride -and $exposedTargetGroups.Count -gt 0) {
    Write-Host "  TargetGroupArn override: skipping $($exposedTargetGroups.Count) shared ExposedTargetGroups (ephemeral service isolation)" -ForegroundColor Cyan
}

# Check if service exists and is active
$serviceActive = $false
try {
    $serviceDescribe = aws ecs describe-services `
        --cluster $ClusterName `
        --services $ServiceName `
        --region $AwsRegion `
        --output json 2>$null | ConvertFrom-Json
    $activeService = $serviceDescribe.services | Where-Object { $_.status -eq "ACTIVE" }
    if ($activeService) {
        $serviceActive = $true
    }
} catch {
    # Service doesn't exist or describe failed
}

if ($serviceActive) {
    # Build optional --deployment-configuration / --availability-zone-rebalancing
    # args. DrainBeforeReplace forces 0/100 (single task drained before the next
    # is started) — required for stateful single-instance services with shared
    # storage where two concurrent tasks would conflict (e.g. mongodb on EFS).
    # AWS rejects maximumPercent <= 100 unless AZ rebalancing is disabled.
    $deployStrategyArgs = @()
    if ($DrainBeforeReplace) {
        $deployStrategyArgs = @(
            '--availability-zone-rebalancing', 'DISABLED',
            '--deployment-configuration', 'minimumHealthyPercent=0,maximumPercent=100'
        )
        Write-Host "  DrainBeforeReplace=true: enforcing 0/100 deployment strategy + AZ rebalancing OFF" -ForegroundColor Cyan
    }

    # Update existing service. When ExposedTargetGroups or an explicit target
    # group override are configured we also pass --load-balancers to keep the
    # service's attachment list in sync. A TargetGroupArn override marks an
    # ephemeral (PR preview) service: it must attach ONLY its own target group —
    # the shared ExposedTargetGroups belong to the primary service, and attaching
    # them would register the preview's side-cars into production target groups.
    if ($TargetGroupArn -or $exposedTargetGroups.Count -gt 0) {
        $primaryTargetGroupArn = if ($TargetGroupArn) { $TargetGroupArn } else { $infraForLb.TargetGroupArn }
        if (-not $primaryTargetGroupArn) {
            Write-Error "Cannot reconcile load balancers: TargetGroupArn missing from infra config"
                exit 1
        }
        $lbSpecs = Get-CcmEcsLoadBalancerSpecs `
            -PrimaryTargetGroupArn $primaryTargetGroupArn `
            -ContainerName $ContainerName `
            -ContainerPort $ContainerPort `
            -ExposedTargetGroups $exposedTargetGroups `
            -ExcludeExposedTargetGroups:$isTargetGroupOverride
        Write-Host "  Reconciling $($lbSpecs.Count) target group attachment(s) via --load-balancers" -ForegroundColor Cyan
        aws ecs update-service `
            --cluster $ClusterName `
            --service $ServiceName `
            --task-definition $taskDefArn `
            --force-new-deployment `
            --load-balancers @lbSpecs `
            @deployStrategyArgs `
            @graceUpdateArgs `
            --region $AwsRegion `
            --output text | Out-Null
    }
    else {
        aws ecs update-service `
            --cluster $ClusterName `
            --service $ServiceName `
            --task-definition $taskDefArn `
            --force-new-deployment `
            @deployStrategyArgs `
            @graceUpdateArgs `
            --region $AwsRegion `
            --output text | Out-Null
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to update ECS service"
        exit 1
    }

    Write-Host "Service update initiated" -ForegroundColor Green
} else {
    # Service doesn't exist - create it
    Write-Host "Service '$ServiceName' not found in cluster '$ClusterName'." -ForegroundColor Yellow
    Write-Host "Creating new ECS service..." -ForegroundColor Yellow

    # Read infrastructure config for networking and load balancer settings
    $infraConfigPath = Join-Path $DeployDir "ecs/infrastructure-config.json"
    if (-not (Test-Path $infraConfigPath)) {
        Write-Error "Cannot create service: infrastructure config not found at $infraConfigPath"
        Write-Error "Run setup-aws-infrastructure.ps1 first to create AWS infrastructure."
        exit 1
    }

    $infra = Get-Content $infraConfigPath -Raw | ConvertFrom-Json
    $subnets = @($infra.Subnets | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    $securityGroups = @($infra.EcsSecurityGroup)
    $targetGroupArn = if ($TargetGroupArn) { $TargetGroupArn } else { $infra.TargetGroupArn }

    if ($subnets.Count -eq 0 -or $securityGroups.Count -eq 0) {
        Write-Error "Could not resolve subnets/security groups from infrastructure config"
        exit 1
    }

    if (-not $targetGroupArn) {
        Write-Error "Target group ARN not found in infrastructure config"
        exit 1
    }

    # Build the full load-balancers spec list: primary ALB target group plus any
    # ExposedTargetGroups (NLB extras for side-car containers, configured via
    # ecs-config.json's ExposeContainerPorts). Ephemeral services created with a
    # TargetGroupArn override (PR previews) attach ONLY their own target group —
    # see the update path above for why.
    $lbSpecs = Get-CcmEcsLoadBalancerSpecs `
        -PrimaryTargetGroupArn $targetGroupArn `
        -ContainerName $ContainerName `
        -ContainerPort $ContainerPort `
        -ExposedTargetGroups $exposedTargetGroups `
        -ExcludeExposedTargetGroups:$isTargetGroupOverride

    # Optional drain-before-replace deployment strategy (see update-service path
    # above for context).
    $createDeployStrategyArgs = @()
    if ($DrainBeforeReplace) {
        $createDeployStrategyArgs = @(
            '--availability-zone-rebalancing', 'DISABLED',
            '--deployment-configuration', 'minimumHealthyPercent=0,maximumPercent=100'
        )
        Write-Host "  DrainBeforeReplace=true: creating service with 0/100 strategy + AZ rebalancing OFF" -ForegroundColor Cyan
    }

    $createServiceOutput = aws ecs create-service `
        --cluster $ClusterName `
        --service-name $ServiceName `
        --task-definition $taskDefArn `
        --desired-count $DesiredCount `
        --launch-type FARGATE `
        --network-configuration "awsvpcConfiguration={subnets=[$($subnets -join ',')],securityGroups=[$($securityGroups -join ',')],assignPublicIp=DISABLED}" `
        --load-balancers @lbSpecs `
        @createDeployStrategyArgs `
        --health-check-grace-period-seconds $createGraceSeconds `
        --region $AwsRegion `
        --output json 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "Failed to create ECS service!" -ForegroundColor Red
        Write-Host "Error: $createServiceOutput" -ForegroundColor Red
        Write-Host ""
        Write-Host "Common causes:" -ForegroundColor Yellow
        Write-Host "  - IAM role permissions insufficient" -ForegroundColor Yellow
        Write-Host "  - Container name '$ContainerName' does not match task definition" -ForegroundColor Yellow
        Write-Host "  - Target group or subnets not configured correctly" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }

    Write-Host "Service created successfully" -ForegroundColor Green
}

# Step 5: Wait for service stability
# Manual poll loop instead of `aws ecs wait services-stable` because the AWS
# CLI waiter has a hard-coded 40-poll x 15s = 10-minute ceiling with no flag
# to extend it. With DrainBeforeReplace=true the old task drains fully before
# the new one starts, so a normal cold start (image pull + EFS mount + 6
# containers + healthcheck startPeriods) can routinely exceed 10 minutes,
# producing false-failure timeouts on otherwise-healthy deploys.
Write-Host "Step 5: Waiting for service to stabilize (up to 20 min)..." -ForegroundColor Yellow

$stableMaxAttempts = 80   # 80 * 15s = 20 min
$stableDelaySec    = 15
$stable = $false
for ($i = 1; $i -le $stableMaxAttempts; $i++) {
    $svc = aws ecs describe-services `
        --cluster $ClusterName --services $ServiceName --region $AwsRegion `
        --output json 2>$null | ConvertFrom-Json
    $s = $svc.services[0]
    $primary = $s.deployments | Where-Object { $_.status -eq 'PRIMARY' } | Select-Object -First 1
    $rollout = if ($primary) { $primary.rolloutState } else { 'unknown' }
    $running = [int]$s.runningCount
    $desired = [int]$s.desiredCount
    $pending = [int]$s.pendingCount

    Write-Host "  [$i/$stableMaxAttempts] running=$running/$desired pending=$pending rollout=$rollout" -ForegroundColor Gray

    if ($running -eq $desired -and $pending -eq 0 -and $rollout -eq 'COMPLETED') {
        $stable = $true
        break
    }
    Start-Sleep -Seconds $stableDelaySec
}

if (-not $stable) {
    # NB: $ErrorActionPreference is 'Stop', so a Write-Error here would terminate
    # immediately and skip the diagnostics below. Print the service events first,
    # then fail with a clean single-line message and a non-zero exit code (callers
    # such as deploy-ecs-preview.ps1 detect the failure via $LASTEXITCODE).
    Write-Host "Last service events:" -ForegroundColor Yellow
    aws ecs describe-services --cluster $ClusterName --services $ServiceName --region $AwsRegion `
        --query 'services[0].events[0:5]' --output table 2>$null
    Write-Host ""
    Write-Host "ERROR: Service '$ServiceName' failed to stabilize after $($stableMaxAttempts * $stableDelaySec) seconds." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== Deployment Complete ===" -ForegroundColor Green
Write-Host "Image: ${EcrRepository}:${ImageTag}"
Write-Host "Task Definition: $taskDefArn"
Write-Host "Cluster: $ClusterName"
Write-Host "Service: $ServiceName"

# Show the web address. A caller (e.g. preview deploys) can pass an explicit
# -WebUiUrl to surface the full URL including any path prefix (/_pr/<id>);
# otherwise derive the base URL from the infrastructure config.
$infraConfigFinal = Join-Path $DeployDir "ecs/infrastructure-config.json"
$resolvedWebUiUrl = Resolve-CcmEcsWebUiUrl `
    -WebUiUrl $WebUiUrl `
    -InfrastructureConfigPath $infraConfigFinal `
    -CustomDomainName $CustomDomainName

Write-Host ""
if ($resolvedWebUiUrl) {
    Write-Host "Web UI available at:" -ForegroundColor Cyan
    Write-Host "  $resolvedWebUiUrl" -ForegroundColor Green
}
else {
    # Say so instead of printing nothing. This block used to be silent, which made
    # a deploy look like it had no web address at all -- the usual cause is that
    # infrastructure-config.json (written by setup-aws-infrastructure.ps1) was
    # gitignored, so a CI agent's fresh clone never had it.
    Write-Host "Web UI address: could not be resolved" -ForegroundColor Yellow
    if (-not (Test-Path $infraConfigFinal)) {
        Write-Host "  No infrastructure config at $infraConfigFinal" -ForegroundColor Yellow
        Write-Host "  Generate it with setup-aws-infrastructure.ps1 and commit it so CI can read it," -ForegroundColor Yellow
        Write-Host "  or set CustomDomainName in ecs-config.json." -ForegroundColor Yellow
    }
    else {
        Write-Host "  $infraConfigFinal has no CustomDomainName, NlbDns or AlbDns." -ForegroundColor Yellow
    }
}

Stop-CcmLogging $ccmLog
