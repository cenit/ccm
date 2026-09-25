#! /usr/bin/env pwsh

<#

.SYNOPSIS
    setup-aws-infrastructure
    Created By: Stefano Sinigardi
    Created Date: January 27, 2026
    Last Modified Date: February 23, 2026

.DESCRIPTION
    Generic script for creating AWS infrastructure for ECS deployments.

    Creates:
      - ECR Repository
      - ECS Cluster
      - IAM Roles (execution and task roles)
      - CloudWatch Log Groups
      - Security Groups
      - Application Load Balancer (ALB)
      - Target Group

    When -EnableEfs is specified, also creates:
      - EFS Filesystem with mount targets in each subnet
      - EFS Security Group (NFS access from ECS tasks)

    When -EnableS3 is specified, also creates:
      - S3 Bucket for persistent document/file storage
      - IAM policy for ECS task role to access the bucket

    When -EnableDynamoDb is specified, also creates:
      - DynamoDB tables listed in DynamoDbTables (idempotent; never deleted)
      - IAM policy ('$ProjectName-dynamodb-access') granting the ECS task role
        scoped CRUD on those tables and their indexes

    When -EnableAurora is specified, also creates:
      - Aurora PostgreSQL Serverless v2 cluster (engine 15, pgvector-ready)
      - DB Subnet Group and Aurora Security Group
      - Database URL secret in Secrets Manager

    When -EnableNlb is specified, also creates:
      - Network Load Balancer (NLB) with optional Elastic IPs
      - NLB Target Group (type=alb, forwarding to the ALB)
      - NLB TCP Listener(s)
      - Route 53 DNS points to NLB instead of ALB

    Prerequisites:
      - AWS CLI configured with admin credentials
      - Existing VPC with private subnets

.PARAMETER ProjectName
    Base name for all AWS resources. Mandatory
    Example: "my-app" will create "my-app-cluster", "my-app-alb", etc.

.PARAMETER VpcId
    VPC ID where resources will be created (required)
    Example: "vpc-0123456789abcdef0"

.PARAMETER SubnetIds
    Comma-separated list of subnet IDs for ALB and ECS tasks (required)
    Example: "subnet-111,subnet-222,subnet-333"

.PARAMETER CertificateArn
    ACM certificate ARN for HTTPS on ALB (optional)
    Example: "arn:aws:acm:eu-central-1:123456789012:certificate/xxx"

.PARAMETER AwsRegion
    AWS region for deployment. Default: "eu-central-1"

.PARAMETER VpnCidr
    Comma-separated list of CIDR blocks allowed to reach the ALB. Each gets its
    own ingress rule on 443 and 80. Reconciled on every run, so adding a range
    here and re-running takes effect on an already-deployed project.
    Additive only: a range removed from this list is not revoked automatically.
    Default: "10.0.0.0/8"

.PARAMETER ContainerPort
    Port exposed by the application container. Default: 8000

.PARAMETER HealthCheckPath
    Health check endpoint path. Default: "/health"

.PARAMETER SecretsPrefix
    Prefix for secrets in AWS Secrets Manager. Default: same as ProjectName

.PARAMETER DeployDir
    Directory containing ecs/ subfolder for config output
    Default: auto-detected as ../deploy from script location

.PARAMETER ConfigFile
    Path to ecs-config.json project configuration file.
    Default: auto-detected as ecs-config.json in the project root (parent of CCM/).
    If found, parameters from the config file are used as defaults.
    CLI parameters always take precedence over config file values.

.PARAMETER EnableEfs
    Create an EFS filesystem with mount targets in each subnet and a security
    group allowing NFS (port 2049) from ECS tasks. Default: off

.PARAMETER EnableS3
    Create an S3 bucket for persistent document storage and grant the ECS task
    role read/write access to the bucket. Default: off

.PARAMETER S3BucketName
    Override the S3 bucket name. Default: "$ProjectName-documents-$AccountId"

.PARAMETER S3BucketVersioning
    Enable versioning on the S3 bucket when -EnableS3 is set. Default: true.
    Set to false for a bucket whose delete semantics are deliberately final.

.PARAMETER EnableDynamoDb
    Create the DynamoDB tables listed in -DynamoDbTables and grant the ECS task
    role scoped read/write access to them. Table names are saved to
    infrastructure-config.json. Default: off

.PARAMETER DynamoDbTables
    Array of table specs (usually supplied via ecs-config.json), each:
    { Name, PartitionKey:{Name,Type}, SortKey:{Name,Type}?, BillingMode? }.

.PARAMETER EnableAurora
    Create an Aurora PostgreSQL Serverless v2 cluster, security group, DB subnet
    group, and database URL secret in Secrets Manager. Default: off

.PARAMETER AuroraMasterPassword
    Master password for the Aurora cluster. If omitted, a random 30-character
    alphanumeric password is auto-generated and stored in Secrets Manager.

.PARAMETER AuroraEngineVersion
    Aurora PostgreSQL engine version. Default: "15.12"

.PARAMETER AuroraMinCapacity
    Serverless v2 minimum ACU capacity. Default: 0.5

.PARAMETER AuroraMaxCapacity
    Serverless v2 maximum ACU capacity. Default: 2

.PARAMETER AuroraMasterUsername
    Master username for the Aurora cluster. Default: "postgres"

.PARAMETER AuroraDatabaseName
    Database name created inside the cluster.
    Default: ProjectName with hyphens replaced by underscores.

.PARAMETER DatabaseUrlScheme
    Scheme prefix for the DATABASE_URL stored in Secrets Manager.
    Default: "postgresql://". Use "postgresql+asyncpg://" for async Python apps.

.PARAMETER AlbIdleTimeoutSeconds
    Override the ALB idle timeout (in seconds). When set, the script ensures
    the ALB idle timeout matches this value. Useful for projects with
    long-running requests such as large file uploads.
    Default: not set (AWS default of 60 s is left unchanged).

.PARAMETER AlbAccessLogsBucket
    Enable ALB access logging to this S3 bucket. The bucket is created if it
    does not exist, with public access blocked and the delivery policy that
    Elastic Load Balancing requires. Access logs give per-request forensics
    (elb_status_code, target_status_code, request/target processing times)
    that CloudWatch metrics cannot provide.
    Default: not set (access logging is left unchanged).

.PARAMETER AlbAccessLogsPrefix
    S3 key prefix for ALB access logs. Only used with -AlbAccessLogsBucket.
    Default: the project name.

.PARAMETER AlbAccessLogsRetentionDays
    Expire ALB access log objects after this many days via an S3 lifecycle
    rule. Only used with -AlbAccessLogsBucket. Access logs accumulate quickly,
    so a retention window is recommended.
    Default: not set (objects are kept indefinitely).

.PARAMETER LogRetentionDays
    Retention window applied to the project's CloudWatch log groups. Applied on
    every run to any matching group that has NO retention policy (i.e. "never
    expire"), including groups this script did not create -- the ECS agent
    creates them itself when a task definition sets `awslogs-create-group`, and
    sidecars or metric exporters create their own. Groups that already carry an
    explicit retention are left alone, so a deliberately longer window set by
    the project is never clobbered.
    Default: 30.

.PARAMETER VpcEndpointSecurityGroupId
    ID of a shared security group already attached to VPC interface endpoints.
    When provided, the script skips creating/modifying VPC endpoints and adding
    per-project ECS security groups to them. This avoids hitting the
    5-SG-per-ENI limit when multiple projects share a VPC.
    Example: "sg-0123456789abcdef0"

.PARAMETER EnableNlb
    Create a Network Load Balancer (NLB) in front of the ALB for static IPs
    and/or PrivateLink support. Route 53 DNS points to NLB when enabled.
    ECS service still registers with the ALB. Default: off

.PARAMETER NlbElasticIpAllocationIds
    Comma-separated Elastic IP allocation IDs to assign to the NLB (one per
    subnet/AZ). If omitted when EnableNlb is true, NLB uses AWS-assigned IPs.

.EXAMPLE
    .\CCM\setup-aws-infrastructure.ps1 -EnableEfs -EnableS3
    Create all infrastructure including EFS filesystem and S3 bucket for persistence

.EXAMPLE
    .\CCM\setup-aws-infrastructure.ps1 -EnableAurora
    Create all infrastructure including Aurora PostgreSQL (other values from ecs-config.json)

.EXAMPLE
    .\CCM\setup-aws-infrastructure.ps1
    With "EnableDynamoDb": true and "DynamoDbTables": [...] in ecs-config.json,
    also creates those DynamoDB tables and grants the task role scoped access.

.EXAMPLE
    .\CCM\setup-aws-infrastructure.ps1
    Run using all parameters from ecs-config.json in the project root

.EXAMPLE
    .\CCM\setup-aws-infrastructure.ps1 -VpcId "vpc-xxx" -SubnetIds "subnet-1,subnet-2" -ProjectName "my-project"
    Create infrastructure for "my-project" (CLI params override ecs-config.json)

.EXAMPLE
    .\CCM\setup-aws-infrastructure.ps1 -ProjectName "my-app" -VpcId "vpc-xxx" -SubnetIds "subnet-1,subnet-2"
    Create infrastructure for custom project

.EXAMPLE
    .\CCM\setup-aws-infrastructure.ps1 `
        -ProjectName "my-app" `
        -VpcId "vpc-xxx" `
        -SubnetIds "subnet-1,subnet-2" `
        -CertificateArn "arn:aws:acm:eu-central-1:xxx:certificate/xxx" `
        -ContainerPort 3000 `
        -HealthCheckPath "/health"
    Create infrastructure with custom settings

.NOTES
    This is a generic reusable script. The CCM folder can be shared across projects
    as a git submodule. Run this once per project to create AWS infrastructure.
    Configuration is saved to deploy/ecs/infrastructure-config.json.

    Parameters can be provided via:
      1. CLI arguments (highest priority)
      2. ecs-config.json in the project root (loaded automatically)
      3. Built-in defaults (lowest priority)

    To reuse across projects, copy ecs-config.json to the new project root and
    update ProjectName, SecretsPrefix, and app-specific settings. Shared values
    like VpcId, SubnetIds, and AwsRegion can remain unchanged.

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
    [string]$ProjectName,  # Base name for all resources

    [Parameter(Mandatory = $false)]
    [string]$VpcId,

    [Parameter(Mandatory = $false)]
    [string]$SubnetIds,  # Comma-separated list of subnet IDs

    [Parameter(Mandatory = $false)]
    [string]$CertificateArn,  # ACM certificate ARN for HTTPS

    [Parameter(Mandatory = $false)]
    [string]$AwsRegion,

    [Parameter(Mandatory = $false)]
    [string]$VpnCidr,  # Private-network CIDR(s) allowed to reach the internal ALB

    [Parameter(Mandatory = $false)]
    [int]$ContainerPort,  # Port exposed by the application container

    [Parameter(Mandatory = $false)]
    [string]$HealthCheckPath,  # Health check endpoint

    [Parameter(Mandatory = $false)]
    [string]$SecretsPrefix,  # Prefix for secrets in Secrets Manager (defaults to ProjectName)

    [Parameter(Mandatory = $false)]
    [string]$DeployDir,  # Directory containing ecs/ subfolder (auto-detected from script location)

    [Parameter(Mandatory = $false)]
    [string]$ConfigFile,  # Path to ecs-config.json (auto-detected from project root)

    [Parameter(Mandatory = $false)]
    [string]$EnvFile,      # Path to .env file to seed Secrets Manager (auto-detected: .env.local then .env)

    [Parameter(Mandatory = $false)]
    [switch]$EnableEfs,  # Create EFS filesystem + mount targets for persistent container storage

    [Parameter(Mandatory = $false)]
    [switch]$EnableS3,  # Create S3 bucket for persistent document storage

    [Parameter(Mandatory = $false)]
    [string]$S3BucketName,  # Override S3 bucket name (default: "$ProjectName-documents-$AwsAccountId")

    [Parameter(Mandatory = $false)]
    [nullable[bool]]$S3BucketVersioning,  # Enable bucket versioning when EnableS3 (default: true)

    [Parameter(Mandatory = $false)]
    [switch]$EnableDynamoDb,   # Create DynamoDB tables + grant task role scoped access

    [Parameter(Mandatory = $false)]
    [object[]]$DynamoDbTables, # Table specs (usually supplied via ecs-config.json)

    [Parameter(Mandatory = $false)]
    [switch]$EnableAurora,  # Create Aurora PostgreSQL Serverless v2 cluster + database secret

    [Parameter(Mandatory = $false)]
    [string]$AuroraMasterPassword,  # Master password (auto-generated if not provided)

    [Parameter(Mandatory = $false)]
    [string]$AuroraEngineVersion,  # Aurora PostgreSQL engine version (default: "15.12")

    [Parameter(Mandatory = $false)]
    [double]$AuroraMinCapacity,  # Serverless v2 min ACU (default: 0.5)

    [Parameter(Mandatory = $false)]
    [double]$AuroraMaxCapacity,  # Serverless v2 max ACU (default: 2)

    [Parameter(Mandatory = $false)]
    [string]$AuroraMasterUsername,  # Master username (default: "postgres")

    [Parameter(Mandatory = $false)]
    [string]$AuroraDatabaseName,  # Database name (default: ProjectName with hyphens as underscores)

    [Parameter(Mandatory = $false)]
    [string]$DatabaseUrlScheme,  # DB URL scheme prefix (default: "postgresql://")

    [Parameter(Mandatory = $false)]
    [int]$AlbIdleTimeoutSeconds,  # Override ALB idle timeout (seconds); 0 or omit = use AWS default (60 s)

    [Parameter(Mandatory = $false)]
    [string]$AlbAccessLogsBucket,  # Enable ALB access logs to this S3 bucket; omit = leave unchanged

    [Parameter(Mandatory = $false)]
    [string]$AlbAccessLogsPrefix,  # S3 key prefix for ALB access logs (default: project name)

    [Parameter(Mandatory = $false)]
    [int]$AlbAccessLogsRetentionDays,  # Expire access logs after N days; 0 or omit = keep indefinitely

    [Parameter(Mandatory = $false)]
    # CloudWatch Logs accepts only this fixed set of values; anything else is
    # rejected by the API mid-run, after resources have already been created.
    [ValidateSet(1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653)]
    [int]$LogRetentionDays = 30,  # Retention for the project's CloudWatch log groups that have none set

    [Parameter(Mandatory = $false)]
    [string]$VpcEndpointSecurityGroupId,  # Shared SG already on VPC endpoints (skip per-project attachment)

    [Parameter(Mandatory = $false)]
    [switch]$EnableNlb,  # Create NLB in front of ALB for static IPs / PrivateLink

    [Parameter(Mandatory = $false)]
    [string]$NlbElasticIpAllocationIds,  # Comma-separated EIP allocation IDs for NLB (one per subnet)

    [Parameter(Mandatory = $false)]
    [Object[]]$ExposeContainerPorts  # Extra container ports to expose via NLB (see schema for entry shape)
)

$ErrorActionPreference = "Stop"

$setup_aws_infrastructure_ps1_version = "1.5.0"
$script_name = $MyInvocation.MyCommand.Name

# Track errors across steps
$script:stepErrors = @()

function Assert-AwsSuccess {
    <#
    .SYNOPSIS
        Checks $LASTEXITCODE after an AWS CLI call and terminates on failure.
        AWS CLI is an external process, so $ErrorActionPreference does NOT catch its errors.
    #>
    param(
        [Parameter(Mandatory)][string]$StepDescription,
        [switch]$NonFatal
    )
    if ($LASTEXITCODE -ne 0) {
        $msg = "FAILED: $StepDescription (exit code: $LASTEXITCODE)"
        if ($NonFatal) {
            Write-Host "  WARNING: $msg" -ForegroundColor Yellow
            $script:stepErrors += $msg
        }
        else {
            Write-Host ""
            Write-Host "==========================================" -ForegroundColor Red
            Write-Host "  FATAL ERROR" -ForegroundColor Red
            Write-Host "  $msg" -ForegroundColor Red
            Write-Host "==========================================" -ForegroundColor Red
            Write-Host ""
            throw $msg
        }
    }
}

# Auto-detect script directory and project root
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

# Import shared utilities
if (Test-Path $ScriptDir/utils.psm1) {
    Import-Module -Name $ScriptDir/utils.psm1 -Force
}

$ccmLog = Initialize-CcmLogging
trap { Stop-CcmLogging $ccmLog; break }

$ErrorActionPreference = "Stop"

Write-Host "Setup AWS Infrastructure script version ${setup_aws_infrastructure_ps1_version}"
Write-Host "Script name: $script_name"
Write-Host "Working directory: $ScriptDir"
Write-Host "Project root: $ProjectRoot"
Write-Host "Log file: $($ccmLog.LogPath)"
Write-Host -NoNewLine "PowerShell version: "
$PSVersionTable.PSVersion
Write-Host ""

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
    if (-not $PSBoundParameters.ContainsKey('ProjectName')   -and $fileConfig.ProjectName)   { $ProjectName   = $fileConfig.ProjectName }
    if (-not $PSBoundParameters.ContainsKey('VpcId')          -and $fileConfig.VpcId)          { $VpcId          = $fileConfig.VpcId }
    if (-not $PSBoundParameters.ContainsKey('SubnetIds')      -and $fileConfig.SubnetIds)      { $SubnetIds      = $fileConfig.SubnetIds }
    if (-not $PSBoundParameters.ContainsKey('CertificateArn') -and $fileConfig.CertificateArn) { $CertificateArn = $fileConfig.CertificateArn }
    if (-not $PSBoundParameters.ContainsKey('AwsRegion')      -and $fileConfig.AwsRegion)      { $AwsRegion      = $fileConfig.AwsRegion }
    if (-not $PSBoundParameters.ContainsKey('VpnCidr')        -and $fileConfig.VpnCidr)        { $VpnCidr        = $fileConfig.VpnCidr }
    if (-not $PSBoundParameters.ContainsKey('ContainerPort')  -and $fileConfig.ContainerPort)  { $ContainerPort  = $fileConfig.ContainerPort }
    if (-not $PSBoundParameters.ContainsKey('HealthCheckPath') -and $fileConfig.HealthCheckPath) { $HealthCheckPath = $fileConfig.HealthCheckPath }
    if (-not $PSBoundParameters.ContainsKey('SecretsPrefix')  -and $fileConfig.SecretsPrefix)  { $SecretsPrefix  = $fileConfig.SecretsPrefix }
    if (-not $PSBoundParameters.ContainsKey('DeployDir')      -and $fileConfig.DeployDir)      { $DeployDir      = $fileConfig.DeployDir }

    # EFS + S3 optional config
    if (-not $PSBoundParameters.ContainsKey('EnableEfs')  -and $fileConfig.EnableEfs)  { $EnableEfs  = $true }
    if (-not $PSBoundParameters.ContainsKey('EnableS3')   -and $fileConfig.EnableS3)   { $EnableS3   = $true }
    if (-not $PSBoundParameters.ContainsKey('S3BucketName') -and $fileConfig.S3BucketName) { $S3BucketName = $fileConfig.S3BucketName }
    if (-not $PSBoundParameters.ContainsKey('S3BucketVersioning') -and $null -ne $fileConfig.S3BucketVersioning) { $S3BucketVersioning = [bool]$fileConfig.S3BucketVersioning }

    # DynamoDB optional config
    if (-not $PSBoundParameters.ContainsKey('EnableDynamoDb') -and $fileConfig.EnableDynamoDb) { $EnableDynamoDb = $true }
    if (-not $PSBoundParameters.ContainsKey('DynamoDbTables') -and $fileConfig.DynamoDbTables) { $DynamoDbTables = $fileConfig.DynamoDbTables }

    # Aurora optional config
    if (-not $PSBoundParameters.ContainsKey('EnableAurora')        -and $fileConfig.EnableAurora)          { $EnableAurora        = $true }
    if (-not $PSBoundParameters.ContainsKey('AuroraMasterPassword') -and $fileConfig.AuroraMasterPassword) { $AuroraMasterPassword = $fileConfig.AuroraMasterPassword }
    if (-not $PSBoundParameters.ContainsKey('AuroraEngineVersion')  -and $fileConfig.AuroraEngineVersion)  { $AuroraEngineVersion  = $fileConfig.AuroraEngineVersion }
    if (-not $PSBoundParameters.ContainsKey('AuroraMinCapacity')    -and $fileConfig.AuroraMinCapacity)    { $AuroraMinCapacity    = [double]$fileConfig.AuroraMinCapacity }
    if (-not $PSBoundParameters.ContainsKey('AuroraMaxCapacity')    -and $fileConfig.AuroraMaxCapacity)    { $AuroraMaxCapacity    = [double]$fileConfig.AuroraMaxCapacity }
    if (-not $PSBoundParameters.ContainsKey('AuroraMasterUsername') -and $fileConfig.AuroraMasterUsername)  { $AuroraMasterUsername = $fileConfig.AuroraMasterUsername }
    if (-not $PSBoundParameters.ContainsKey('AuroraDatabaseName')   -and $fileConfig.AuroraDatabaseName)   { $AuroraDatabaseName   = $fileConfig.AuroraDatabaseName }
    if (-not $PSBoundParameters.ContainsKey('DatabaseUrlScheme')    -and $fileConfig.DatabaseUrlScheme)    { $DatabaseUrlScheme    = $fileConfig.DatabaseUrlScheme }
    if (-not $PSBoundParameters.ContainsKey('AlbIdleTimeoutSeconds')       -and $fileConfig.AlbIdleTimeoutSeconds)       { $AlbIdleTimeoutSeconds       = [int]$fileConfig.AlbIdleTimeoutSeconds }
    if (-not $PSBoundParameters.ContainsKey('AlbAccessLogsBucket')         -and $fileConfig.AlbAccessLogsBucket)         { $AlbAccessLogsBucket         = $fileConfig.AlbAccessLogsBucket }
    if (-not $PSBoundParameters.ContainsKey('AlbAccessLogsPrefix')         -and $fileConfig.AlbAccessLogsPrefix)         { $AlbAccessLogsPrefix         = $fileConfig.AlbAccessLogsPrefix }
    if (-not $PSBoundParameters.ContainsKey('AlbAccessLogsRetentionDays')  -and $fileConfig.AlbAccessLogsRetentionDays)  { $AlbAccessLogsRetentionDays  = [int]$fileConfig.AlbAccessLogsRetentionDays }
    if (-not $PSBoundParameters.ContainsKey('LogRetentionDays')            -and $fileConfig.LogRetentionDays)            { $LogRetentionDays            = [int]$fileConfig.LogRetentionDays }
    if (-not $PSBoundParameters.ContainsKey('VpcEndpointSecurityGroupId') -and $fileConfig.VpcEndpointSecurityGroupId) { $VpcEndpointSecurityGroupId = $fileConfig.VpcEndpointSecurityGroupId }

    # NLB optional config
    if (-not $PSBoundParameters.ContainsKey('EnableNlb') -and $fileConfig.EnableNlb) { $EnableNlb = $true }
    if (-not $PSBoundParameters.ContainsKey('NlbElasticIpAllocationIds') -and $fileConfig.NlbElasticIpAllocationIds) { $NlbElasticIpAllocationIds = $fileConfig.NlbElasticIpAllocationIds }
    if (-not $PSBoundParameters.ContainsKey('ExposeContainerPorts') -and $fileConfig.ExposeContainerPorts) { $ExposeContainerPorts = @($fileConfig.ExposeContainerPorts) }

    # Route 53 / HTTPS settings
    if ($fileConfig.Route53HostedZoneId) { $Route53HostedZoneId = $fileConfig.Route53HostedZoneId }
    if ($fileConfig.ParentDomain)        { $ParentDomain = $fileConfig.ParentDomain }
    if ($fileConfig.CustomDomainName)    { $CustomDomainName = $fileConfig.CustomDomainName }

    Write-Host "  Config loaded successfully" -ForegroundColor Green
} else {
    Write-Host "No ecs-config.json found at $ConfigFile - using CLI parameters only" -ForegroundColor Yellow
}

# Apply built-in defaults for any values still not set
if (-not $AwsRegion)      { $AwsRegion      = "eu-central-1" }
if (-not $VpnCidr)        { $VpnCidr        = "10.0.0.0/8" }
if (-not $ContainerPort -or $ContainerPort -eq 0) { $ContainerPort = 8000 }
if (-not $HealthCheckPath) { $HealthCheckPath = "/health" }
if ($null -eq $S3BucketVersioning) { $S3BucketVersioning = $true }

# Pre-compute the CIDR list once so any downstream block can iterate over it,
# regardless of whether the ALB / ECS security groups are being created fresh
# or already exist (the original ALB-create block defined this lazily, which
# left $cidrList undefined on idempotent re-runs that touched downstream
# resources like ExposeContainerPorts SG ingress rules).
$cidrList = ($VpnCidr -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }

# Validate required parameters
$missingParams = @()
if (-not $ProjectName) { $missingParams += "ProjectName" }
if (-not $VpcId)       { $missingParams += "VpcId" }
if (-not $SubnetIds)   { $missingParams += "SubnetIds" }
if ($missingParams.Count -gt 0) {
    Write-Host "" -ForegroundColor Red
    Write-Host "=========================================" -ForegroundColor Red
    Write-Host "  MISSING REQUIRED PARAMETERS" -ForegroundColor Red
    Write-Host "  $($missingParams -join ', ')" -ForegroundColor Red
    Write-Host "" -ForegroundColor Red
    Write-Host "  Provide them via CLI or ecs-config.json" -ForegroundColor Red
    Write-Host "  in the project root." -ForegroundColor Red
    Write-Host "=========================================" -ForegroundColor Red
    throw"Missing required parameters: $($missingParams -join ', '). Provide via CLI or ecs-config.json."
}

# Default deploy directory is ../deploy relative to script location (CCM -> deploy)
if (-not $DeployDir) {
    $DeployDir = Join-Path $ProjectRoot "deploy"
}

# Ensure deploy output directory exists (deploy/ecs)
$ecsDeployDir = Join-Path $DeployDir "ecs"
New-Item -ItemType Directory -Path $ecsDeployDir -Force | Out-Null

# Set defaults for optional parameters
if (-not $SecretsPrefix) {
    $SecretsPrefix = $ProjectName
}

# Derived resource names
$EcrRepoName = $ProjectName
$ClusterName = "$ProjectName-cluster"
$AlbName = "$ProjectName-alb"
$TargetGroupName = "$ProjectName-tg"
$AlbSecurityGroupName = "$ProjectName-alb-sg"
$EcsSecurityGroupName = "$ProjectName-ecs-sg"
$ExecutionRoleName = "$ProjectName-execution-role"
$TaskRoleName = "$ProjectName-task-role"
$LogGroupApp = "/ecs/$ProjectName"
$LogGroupMigrations = "/ecs/$ProjectName-migrations"
$NlbName = "$ProjectName-nlb"
$NlbTargetGroupName = "$ProjectName-nlb-tg"
$NlbHttpTargetGroupName = "$ProjectName-nlb-http-tg"

# Validate AWS credentials / SSO session before any AWS work
Assert-AwsSsoSession -AwsRegion $AwsRegion -StopTranscript

$AwsAccountId = aws sts get-caller-identity --query Account --output text --region $AwsRegion
Assert-AwsSuccess "Retrieve AWS Account ID (aws sts get-caller-identity)"
if (-not $AwsAccountId -or $AwsAccountId -eq "None") {
    Write-Host "" -ForegroundColor Red
    Write-Host "FATAL: Could not determine AWS Account ID." -ForegroundColor Red
    Write-Host "  Ensure AWS CLI is configured and credentials are valid." -ForegroundColor Red
    Write-Host "  Run: aws sts get-caller-identity" -ForegroundColor Red
    throw"AWS credentials invalid or not configured"
}
$Subnets = $SubnetIds -split ","

Write-Host "=== $ProjectName AWS Infrastructure Setup ===" -ForegroundColor Cyan
Write-Host "Project: $ProjectName"
Write-Host "Region: $AwsRegion"
Write-Host "Account: $AwsAccountId"
Write-Host "VPC: $VpcId"
Write-Host "Subnets: $SubnetIds"
Write-Host "Container Port: $ContainerPort"
Write-Host "Health Check: $HealthCheckPath"
Write-Host "Secrets Prefix: $SecretsPrefix"
if ($EnableEfs) {
    Write-Host "EFS: ENABLED" -ForegroundColor Cyan
}
if ($EnableS3) {
    Write-Host "S3: ENABLED" -ForegroundColor Cyan
}
if ($EnableAurora) {
    Write-Host "Aurora PostgreSQL: ENABLED" -ForegroundColor Cyan
}
if ($AlbIdleTimeoutSeconds -and $AlbIdleTimeoutSeconds -gt 0) {
    Write-Host "ALB Idle Timeout: ${AlbIdleTimeoutSeconds}s" -ForegroundColor Cyan
}
if ($AlbAccessLogsBucket) {
    Write-Host "ALB Access Logs: s3://$AlbAccessLogsBucket" -ForegroundColor Cyan
}
if ($VpcEndpointSecurityGroupId) {
    Write-Host "VPC Endpoint SG: $VpcEndpointSecurityGroupId (shared, skip per-project attachment)" -ForegroundColor Cyan
}
if ($EnableNlb) {
    Write-Host "NLB: ENABLED" -ForegroundColor Cyan
    if ($NlbElasticIpAllocationIds) {
        Write-Host "NLB EIPs: $NlbElasticIpAllocationIds" -ForegroundColor Cyan
    }
}
Write-Host ""

# 1. Create ECR Repository
Write-Host "1. Creating ECR Repository..." -ForegroundColor Yellow
$ecrExists = aws ecr describe-repositories --repository-names $EcrRepoName --region $AwsRegion 2>$null
if (-not $ecrExists) {
    aws ecr create-repository `
        --repository-name $EcrRepoName `
        --region $AwsRegion `
        --image-scanning-configuration scanOnPush=true `
        --encryption-configuration encryptionType=AES256
    Assert-AwsSuccess "Create ECR repository '$EcrRepoName'"
    Write-Host "  ECR repository created: $EcrRepoName" -ForegroundColor Green
}
else {
    Write-Host "  ECR repository already exists: $EcrRepoName" -ForegroundColor Green
}

# 2. Create ECS Cluster
Write-Host "2. Creating ECS Cluster..." -ForegroundColor Yellow
$clusterExists = aws ecs describe-clusters --clusters $ClusterName --region $AwsRegion --query 'clusters[0].status' --output text
if ($clusterExists -ne "ACTIVE") {
    aws ecs create-cluster `
        --cluster-name $ClusterName `
        --region $AwsRegion `
        --capacity-providers FARGATE FARGATE_SPOT `
        --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1
    Assert-AwsSuccess "Create ECS cluster '$ClusterName'"
    Write-Host "  ECS cluster created: $ClusterName" -ForegroundColor Green
}
else {
    Write-Host "  ECS cluster already exists: $ClusterName" -ForegroundColor Green
}

# 3. Create CloudWatch Log Groups
Write-Host "3. Creating CloudWatch Log Groups..." -ForegroundColor Yellow
foreach ($logGroup in @($LogGroupApp, $LogGroupMigrations)) {
    $logExists = aws logs describe-log-groups --log-group-name-prefix $logGroup --region $AwsRegion --query 'logGroups[0].logGroupName' --output text
    if ($logExists -ne $logGroup) {
        aws logs create-log-group --log-group-name $logGroup --region $AwsRegion
        Assert-AwsSuccess "Create log group '$logGroup'"
        aws logs put-retention-policy --log-group-name $logGroup --retention-in-days $LogRetentionDays --region $AwsRegion
        Assert-AwsSuccess "Set retention policy for '$logGroup'"
        Write-Host "  Created: $logGroup (retention ${LogRetentionDays}d)" -ForegroundColor Green
    }
    else {
        Write-Host "  Exists: $logGroup" -ForegroundColor Green
    }
}

# 3b. Reconcile retention across ALL of the project's log groups, every run.
# The loop above only sets retention on the branch where it CREATES the group,
# so a group that already existed keeps whatever it had -- and a group this
# script never creates is missed entirely. Both happen routinely: the ECS agent
# creates the app log group itself when a task definition sets
# `awslogs-create-group: true` (a race this script loses on a first deploy), and
# sidecars or metric exporters create their own groups. Those default to "never
# expire", which is not a retention period and accumulates personal data (user
# identifiers, client IPs) indefinitely.
#
# Only groups with NO retention are touched, so an explicitly longer window set
# by the project is preserved.
Write-Host "   Reconciling log-group retention (${LogRetentionDays}d where unset)..." -ForegroundColor Yellow
# NB: `aws --output json` yields a string ARRAY (one element per line) in
# PowerShell. ConvertFrom-Json's -InputObject is [string], so the positional
# form throws on Object[]; only the pipeline form accumulates the lines.
$logGroupsJson = aws logs describe-log-groups --log-group-name-prefix "/ecs/$ProjectName" --region $AwsRegion --output json | ConvertFrom-Json
if ($LASTEXITCODE -eq 0 -and $logGroupsJson) {
    # Prefix matching is a plain string match, so "/ecs/foo" also returns
    # "/ecs/foo-bar-migrations" belonging to a DIFFERENT project. Keep only this
    # project's own groups: the exact name, the "-migrations" sibling, or a child
    # under "/ecs/<project>/".
    $projectGroups = $logGroupsJson.logGroups | Where-Object {
        $_.logGroupName -eq $LogGroupApp -or
        $_.logGroupName -eq $LogGroupMigrations -or
        $_.logGroupName.StartsWith("$LogGroupApp/")
    }
    $unset = @($projectGroups | Where-Object { -not $_.retentionInDays })
    if ($unset.Count -eq 0) {
        Write-Host "     All $($projectGroups.Count) project log group(s) already have a retention policy" -ForegroundColor Green
    }
    else {
        foreach ($g in $unset) {
            aws logs put-retention-policy --log-group-name $g.logGroupName --retention-in-days $LogRetentionDays --region $AwsRegion
            Assert-AwsSuccess "Set ${LogRetentionDays}-day retention on '$($g.logGroupName)'" -NonFatal
            Write-Host "     Set ${LogRetentionDays}d on: $($g.logGroupName) (was: never expire)" -ForegroundColor Green
        }
    }
}
else {
    Write-Host "     WARNING: could not list log groups; retention not reconciled" -ForegroundColor Yellow
}

# 4. Create IAM Roles
Write-Host "4. Creating IAM Roles..." -ForegroundColor Yellow

# Execution Role (for pulling images, writing logs)
$executionRoleTrust = @"
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {"Service": "ecs-tasks.amazonaws.com"},
            "Action": "sts:AssumeRole"
        }
    ]
}
"@

$executionRoleExists = aws iam get-role --role-name $ExecutionRoleName 2>$null
if (-not $executionRoleExists) {
    $tempFile = [System.IO.Path]::GetTempFileName()
    $executionRoleTrust | Set-Content $tempFile

    aws iam create-role `
        --role-name $ExecutionRoleName `
        --assume-role-policy-document "file://$tempFile"
    Assert-AwsSuccess "Create IAM execution role '$ExecutionRoleName'"

    aws iam attach-role-policy `
        --role-name $ExecutionRoleName `
        --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
    Assert-AwsSuccess "Attach ECS execution policy to '$ExecutionRoleName'"

    Remove-Item $tempFile
    Write-Host "  Execution role created: $ExecutionRoleName" -ForegroundColor Green
}
else {
    Write-Host "  Execution role already exists: $ExecutionRoleName" -ForegroundColor Green
}

# Task Role (for secrets access)
$taskRolePolicy = @"
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": ["secretsmanager:GetSecretValue"],
            "Resource": "arn:aws:secretsmanager:${AwsRegion}:${AwsAccountId}:secret:${SecretsPrefix}/*"
        }
    ]
}
"@

$taskRoleExists = aws iam get-role --role-name $TaskRoleName 2>$null
if (-not $taskRoleExists) {
    $tempFile = [System.IO.Path]::GetTempFileName()
    $executionRoleTrust | Set-Content $tempFile

    aws iam create-role `
        --role-name $TaskRoleName `
        --assume-role-policy-document "file://$tempFile"
    Assert-AwsSuccess "Create IAM task role '$TaskRoleName'"

    $tempPolicy = [System.IO.Path]::GetTempFileName()
    $taskRolePolicy | Set-Content $tempPolicy

    aws iam put-role-policy `
        --role-name $TaskRoleName `
        --policy-name "$ProjectName-secrets-access" `
        --policy-document "file://$tempPolicy"
    Assert-AwsSuccess "Attach secrets policy to task role '$TaskRoleName'"

    Remove-Item $tempFile
    Remove-Item $tempPolicy
    Write-Host "  Task role created: $TaskRoleName" -ForegroundColor Green
}
else {
    Write-Host "  Task role already exists: $TaskRoleName" -ForegroundColor Green
}

# Add secrets manager access to execution role
$secretsPolicy = @"
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": ["secretsmanager:GetSecretValue"],
            "Resource": "arn:aws:secretsmanager:${AwsRegion}:${AwsAccountId}:secret:${SecretsPrefix}/*"
        }
    ]
}
"@
$tempSecrets = [System.IO.Path]::GetTempFileName()
$secretsPolicy | Set-Content $tempSecrets
aws iam put-role-policy `
    --role-name $ExecutionRoleName `
    --policy-name "$ProjectName-secrets-access" `
    --policy-document "file://$tempSecrets"
Assert-AwsSuccess "Attach secrets policy to execution role '$ExecutionRoleName'"
Remove-Item $tempSecrets

# 5. Create Security Groups
Write-Host "5. Creating Security Groups..." -ForegroundColor Yellow

# ALB Security Group
$albSgId = aws ec2 describe-security-groups `
    --filters "Name=group-name,Values=$AlbSecurityGroupName" "Name=vpc-id,Values=$VpcId" `
    --region $AwsRegion `
    --query 'SecurityGroups[0].GroupId' `
    --output text

if ($albSgId -eq "None" -or -not $albSgId) {
    $albSgId = aws ec2 create-security-group `
        --group-name $AlbSecurityGroupName `
        --description "Security group for $ProjectName ALB" `
        --vpc-id $VpcId `
        --region $AwsRegion `
        --query 'GroupId' `
        --output text
    Assert-AwsSuccess "Create ALB security group '$AlbSecurityGroupName'"

    # Allow HTTPS and HTTP from each VPN CIDR (comma-separated list supported)
    $cidrList = ($VpnCidr -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    foreach ($cidr in $cidrList) {
        aws ec2 authorize-security-group-ingress `
            --group-id $albSgId `
            --protocol tcp `
            --port 443 `
            --cidr $cidr `
            --region $AwsRegion
        Assert-AwsSuccess "Add HTTPS ingress rule to ALB security group (CIDR: $cidr)"

        aws ec2 authorize-security-group-ingress `
            --group-id $albSgId `
            --protocol tcp `
            --port 80 `
            --cidr $cidr `
            --region $AwsRegion 2>$null
        # HTTP rule is non-fatal if it already exists (duplicate rule error)
        if ($LASTEXITCODE -ne 0) { Write-Host "  Note: HTTP ingress rule for $cidr may already exist (non-fatal)" -ForegroundColor Yellow }
    }

    Write-Host "  ALB security group created: $albSgId" -ForegroundColor Green
}
else {
    Write-Host "  ALB security group exists: $albSgId" -ForegroundColor Green
}

# Reconcile the ALB ingress against VpnCidr on EVERY run, not only on create.
# The block above runs only when the security group does not yet exist, so on an
# existing project the `else` branch above prints "exists" and the CIDR list is
# never looked at again. Adding a second range to VpnCidr in ecs-config.json
# therefore had NO effect on any project already deployed -- the config said one
# thing and the security group kept doing another, which is invisible until
# someone on the new range reports that they cannot reach the service.
#
# Additive only: a CIDR removed from VpnCidr is NOT revoked here. Revoking
# ingress from a live load balancer is how you lock an office out of every
# application at once, and it should be a deliberate act, not a side effect of
# re-running infrastructure setup.
$cidrList = ($VpnCidr -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
# NB: `aws --output json` yields a string ARRAY (one element per line) in
# PowerShell. ConvertFrom-Json's -InputObject is [string], so the positional
# form throws on Object[]; only the pipeline form accumulates the lines. This
# matches the existing idiom used for the ECS security-group rules below.
$albRulesJson = aws ec2 describe-security-group-rules `
    --filters "Name=group-id,Values=$albSgId" `
    --region $AwsRegion `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -eq 0 -and $albRulesJson) {
    $albRules = $albRulesJson.SecurityGroupRules | Where-Object { -not $_.IsEgress }
    $added = 0
    foreach ($cidr in $cidrList) {
        foreach ($port in @(443, 80)) {
            $present = $albRules | Where-Object {
                $_.CidrIpv4 -eq $cidr -and $_.FromPort -eq $port -and $_.ToPort -eq $port
            }
            if (-not $present) {
                aws ec2 authorize-security-group-ingress `
                    --group-id $albSgId `
                    --protocol tcp `
                    --port $port `
                    --cidr $cidr `
                    --region $AwsRegion 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "     Added ALB ingress tcp/$port from $cidr" -ForegroundColor Green
                    $added++
                }
                else {
                    Write-Host "     WARNING: could not add ALB ingress tcp/$port from $cidr" -ForegroundColor Yellow
                }
            }
        }
    }
    if ($added -eq 0) {
        Write-Host "  ALB ingress already matches VpnCidr ($($cidrList -join ', '))" -ForegroundColor Green
    }
}
else {
    Write-Host "  WARNING: could not read ALB security group rules; ingress not reconciled" -ForegroundColor Yellow
}

# ECS Security Group
$ecsSgId = aws ec2 describe-security-groups `
    --filters "Name=group-name,Values=$EcsSecurityGroupName" "Name=vpc-id,Values=$VpcId" `
    --region $AwsRegion `
    --query 'SecurityGroups[0].GroupId' `
    --output text

if ($ecsSgId -eq "None" -or -not $ecsSgId) {
    $ecsSgId = aws ec2 create-security-group `
        --group-name $EcsSecurityGroupName `
        --description "Security group for $ProjectName ECS tasks" `
        --vpc-id $VpcId `
        --region $AwsRegion `
        --query 'GroupId' `
        --output text
    Assert-AwsSuccess "Create ECS security group '$EcsSecurityGroupName'"

    # Allow traffic from ALB
    aws ec2 authorize-security-group-ingress `
        --group-id $ecsSgId `
        --protocol tcp `
        --port $ContainerPort `
        --source-group $albSgId `
        --region $AwsRegion
    Assert-AwsSuccess "Add ingress rule to ECS security group (port $ContainerPort from ALB)"

    Write-Host "  ECS security group created: $ecsSgId" -ForegroundColor Green
}
else {
    Write-Host "  ECS security group exists: $ecsSgId" -ForegroundColor Green
}

# Allow HTTPS (443) within ECS security group for VPC endpoint communication
# VPC Interface endpoints use HTTPS, so ECS tasks must be able to reach them
$existingHttpsRule = aws ec2 describe-security-group-rules `
    --filters "Name=group-id,Values=$ecsSgId" `
    --region $AwsRegion `
    --query "SecurityGroupRules[?FromPort==``443`` && ToPort==``443`` && ReferencedGroupInfo.GroupId=='$ecsSgId']" `
    --output json | ConvertFrom-Json

if ($existingHttpsRule.Count -eq 0) {
    aws ec2 authorize-security-group-ingress `
        --group-id $ecsSgId `
        --protocol tcp `
        --port 443 `
        --source-group $ecsSgId `
        --region $AwsRegion 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Added HTTPS self-referencing rule to ECS security group" -ForegroundColor Green
    } else {
        Write-Host "  Note: HTTPS self-referencing rule may already exist (non-fatal)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  HTTPS self-referencing rule already exists on ECS security group" -ForegroundColor Green
}

# 6. Create VPC Endpoints (required for Fargate tasks in private subnets)
Write-Host "6. Creating VPC Endpoints for private subnet access..." -ForegroundColor Yellow
Write-Host "   (Fargate tasks need these to reach AWS services without public IP)" -ForegroundColor Yellow

# Determine the security group to use for VPC endpoints
if ($VpcEndpointSecurityGroupId) {
    $vpceSecurityGroupId = $VpcEndpointSecurityGroupId
    Write-Host "  Using shared VPC endpoint security group: $vpceSecurityGroupId" -ForegroundColor Cyan
    Write-Host "  Skipping per-project SG attachment to endpoints (shared SG handles access)" -ForegroundColor Cyan
} else {
    $vpceSecurityGroupId = $ecsSgId
    Write-Host "  No shared VPC endpoint SG configured, using project ECS SG: $ecsSgId" -ForegroundColor Yellow
    Write-Host "  TIP: Set VpcEndpointSecurityGroupId in ecs-config.json to avoid SG-per-ENI limits" -ForegroundColor Yellow
}

$requiredEndpoints = @(
    @{ Service = "com.amazonaws.$AwsRegion.secretsmanager"; Type = "Interface"; Name = "Secrets Manager" },
    @{ Service = "com.amazonaws.$AwsRegion.ecr.dkr";       Type = "Interface"; Name = "ECR Docker" },
    @{ Service = "com.amazonaws.$AwsRegion.ecr.api";       Type = "Interface"; Name = "ECR API" },
    @{ Service = "com.amazonaws.$AwsRegion.logs";          Type = "Interface"; Name = "CloudWatch Logs" }
)

foreach ($ep in $requiredEndpoints) {
    $existing = aws ec2 describe-vpc-endpoints `
        --filters "Name=vpc-id,Values=$VpcId" "Name=service-name,Values=$($ep.Service)" "Name=vpc-endpoint-state,Values=available,pending" `
        --region $AwsRegion `
        --query "VpcEndpoints[0].VpcEndpointId" `
        --output text 2>$null
    if ($existing -and $existing -ne "None") {
        Write-Host "  $($ep.Name) endpoint already exists: $existing" -ForegroundColor Green
        if ($VpcEndpointSecurityGroupId) {
            # Shared SG mode: verify it is attached, but don't add per-project SG
            $attachedSgs = aws ec2 describe-vpc-endpoints `
                --vpc-endpoint-ids $existing `
                --region $AwsRegion `
                --query "VpcEndpoints[0].Groups[*].GroupId" `
                --output json 2>$null | ConvertFrom-Json
            if ($attachedSgs -contains $VpcEndpointSecurityGroupId) {
                Write-Host "    Shared SG already attached" -ForegroundColor Green
            } else {
                Write-Host "    WARNING: Shared SG $VpcEndpointSecurityGroupId is NOT attached to $($ep.Name) endpoint" -ForegroundColor Yellow
                Write-Host "    Run: aws ec2 modify-vpc-endpoint --vpc-endpoint-id $existing --add-security-group-ids $VpcEndpointSecurityGroupId --region $AwsRegion" -ForegroundColor White
            }
        } else {
            # Legacy mode: attach per-project ECS SG to the endpoint
            $attachedSgs = aws ec2 describe-vpc-endpoints `
                --vpc-endpoint-ids $existing `
                --region $AwsRegion `
                --query "VpcEndpoints[0].Groups[*].GroupId" `
                --output json 2>$null | ConvertFrom-Json
            if ($attachedSgs -notcontains $ecsSgId) {
                aws ec2 modify-vpc-endpoint `
                    --vpc-endpoint-id $existing `
                    --add-security-group-ids $ecsSgId `
                    --region $AwsRegion | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "    Added $ecsSgId to existing $($ep.Name) endpoint" -ForegroundColor Green
                } else {
                    Write-Host "    WARNING: Could not add $ecsSgId to $($ep.Name) endpoint (SG limit reached?)" -ForegroundColor Yellow
                    Write-Host "    Consider using a shared VPC endpoint SG (VpcEndpointSecurityGroupId in ecs-config.json)" -ForegroundColor Yellow
                }
            } else {
                Write-Host "    ECS security group already attached to $($ep.Name) endpoint" -ForegroundColor Green
            }
        }
    } else {
        $newEp = aws ec2 create-vpc-endpoint `
            --vpc-id $VpcId `
            --service-name $ep.Service `
            --vpc-endpoint-type $ep.Type `
            --subnet-ids $Subnets `
            --security-group-ids $vpceSecurityGroupId `
            --private-dns-enabled `
            --region $AwsRegion `
            --query "VpcEndpoint.VpcEndpointId" `
            --output text
        Assert-AwsSuccess "Create $($ep.Name) VPC endpoint" -NonFatal
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  $($ep.Name) endpoint created: $newEp" -ForegroundColor Green
        }
    }
}

# S3 Gateway endpoint (ECR stores container layers in S3)
$s3Service = "com.amazonaws.$AwsRegion.s3"
$existingS3 = aws ec2 describe-vpc-endpoints `
    --filters "Name=vpc-id,Values=$VpcId" "Name=service-name,Values=$s3Service" "Name=vpc-endpoint-state,Values=available,pending" `
    --region $AwsRegion `
    --query "VpcEndpoints[0].VpcEndpointId" `
    --output text 2>$null
if ($existingS3 -and $existingS3 -ne "None") {
    Write-Host "  S3 Gateway endpoint already exists: $existingS3" -ForegroundColor Green
} else {
    # Look up the route table associated with the first subnet
    $rtbId = aws ec2 describe-route-tables `
        --filters "Name=association.subnet-id,Values=$($Subnets[0])" `
        --region $AwsRegion `
        --query "RouteTables[0].RouteTableId" `
        --output text
    if ($rtbId -and $rtbId -ne "None") {
        aws ec2 create-vpc-endpoint `
            --vpc-id $VpcId `
            --service-name $s3Service `
            --vpc-endpoint-type Gateway `
            --route-table-ids $rtbId `
            --region $AwsRegion `
            --query "VpcEndpoint.VpcEndpointId" `
            --output text
        Assert-AwsSuccess "Create S3 Gateway VPC endpoint" -NonFatal
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  S3 Gateway endpoint created" -ForegroundColor Green
        }
    } else {
        Write-Host "  WARNING: Could not find route table for subnet $($Subnets[0]), skipping S3 endpoint" -ForegroundColor Yellow
        $script:stepErrors += "Could not create S3 Gateway endpoint (no route table found)"
    }
}

# 7. Create Application Load Balancer
Write-Host "7. Creating Application Load Balancer..." -ForegroundColor Yellow

$albArn = aws elbv2 describe-load-balancers `
    --names $AlbName `
    --region $AwsRegion `
    --query 'LoadBalancers[0].LoadBalancerArn' `
    --output text 2>$null

if (-not $albArn -or $albArn -eq "None") {
    $subnetArgs = ($Subnets | ForEach-Object { $_.Trim() }) -join " "

    $albArn = aws elbv2 create-load-balancer `
        --name $AlbName `
        --type application `
        --scheme internal `
        --subnets $Subnets `
        --security-groups $albSgId `
        --region $AwsRegion `
        --query 'LoadBalancers[0].LoadBalancerArn' `
        --output text
    Assert-AwsSuccess "Create Application Load Balancer '$AlbName'"

    # Wait for ALB to become active before creating listener
    Write-Host "  Waiting for ALB to become active..." -ForegroundColor Yellow
    aws elbv2 wait load-balancer-available `
        --load-balancer-arns $albArn `
        --region $AwsRegion
    Assert-AwsSuccess "Wait for ALB '$AlbName' to become active"
    Write-Host "  ALB is active" -ForegroundColor Green

    Write-Host "  ALB created: $albArn" -ForegroundColor Green
}
else {
    Write-Host "  ALB exists: $albArn" -ForegroundColor Green

    # Reconcile subnets: if the configured subnet set has drifted ahead of the
    # live ALB (typically because new AZs were added to ecs-config.json after
    # the ALB was originally created), bring the ALB in line so ECS task
    # placements in the new AZs can be routed.
    $currentSubnets = aws elbv2 describe-load-balancers `
        --load-balancer-arns $albArn `
        --region $AwsRegion `
        --query 'LoadBalancers[0].AvailabilityZones[*].SubnetId' `
        --output text
    $currentSet = @(($currentSubnets -split '\s+' | Where-Object { $_ }) | Sort-Object)
    $desiredSet = @(($Subnets | ForEach-Object { $_.Trim() }) | Sort-Object)
    if (Compare-Object $currentSet $desiredSet -SyncWindow 0) {
        Write-Host "  Reconciling ALB subnets: $($desiredSet -join ',')" -ForegroundColor Yellow
        aws elbv2 set-subnets `
            --load-balancer-arn $albArn `
            --subnets $Subnets `
            --region $AwsRegion | Out-Null
        Assert-AwsSuccess "Reconcile ALB '$AlbName' subnets"
        Write-Host "  ALB subnets updated" -ForegroundColor Green
    }
}

# Optionally override ALB idle timeout (e.g. for long-running uploads).
if ($AlbIdleTimeoutSeconds -and $AlbIdleTimeoutSeconds -gt 0) {
    $currentIdleTimeout = aws elbv2 describe-load-balancer-attributes `
        --load-balancer-arn $albArn `
        --region $AwsRegion `
        --query "Attributes[?Key=='idle_timeout.timeout_seconds'].Value | [0]" `
        --output text
    if ([int]$currentIdleTimeout -ne $AlbIdleTimeoutSeconds) {
        Write-Host "  Setting ALB idle timeout from ${currentIdleTimeout}s to ${AlbIdleTimeoutSeconds}s..." -ForegroundColor Yellow
        aws elbv2 modify-load-balancer-attributes `
            --load-balancer-arn $albArn `
            --attributes "Key=idle_timeout.timeout_seconds,Value=$AlbIdleTimeoutSeconds" `
            --region $AwsRegion | Out-Null
        Assert-AwsSuccess "Set ALB idle timeout to ${AlbIdleTimeoutSeconds}s"
        Write-Host "  ALB idle timeout updated" -ForegroundColor Green
    } else {
        Write-Host "  ALB idle timeout is already ${currentIdleTimeout}s" -ForegroundColor Green
    }
}

# Optionally enable ALB access logs. CloudWatch metrics only aggregate; access logs
# record every request (elb_status_code, target_status_code, processing times), which
# is what you need to tell a client-side abort from a load balancer or target fault.
if ($AlbAccessLogsBucket) {
    if (-not $AlbAccessLogsPrefix) { $AlbAccessLogsPrefix = $ProjectName }
    Write-Host "  Configuring ALB access logs -> s3://$AlbAccessLogsBucket/$AlbAccessLogsPrefix" -ForegroundColor Yellow

    # a. Create the log bucket when missing.
    $albLogBucketExists = aws s3api head-bucket --bucket $AlbAccessLogsBucket --region $AwsRegion 2>$null
    if ($LASTEXITCODE -ne 0) {
        if ($AwsRegion -eq "us-east-1") {
            aws s3api create-bucket `
                --bucket $AlbAccessLogsBucket `
                --region $AwsRegion | Out-Null
        } else {
            aws s3api create-bucket `
                --bucket $AlbAccessLogsBucket `
                --region $AwsRegion `
                --create-bucket-configuration "LocationConstraint=$AwsRegion" | Out-Null
        }
        Assert-AwsSuccess "Create ALB access log bucket '$AlbAccessLogsBucket'"
        Write-Host "     Created: $AlbAccessLogsBucket" -ForegroundColor Green
    } else {
        Write-Host "     Exists: $AlbAccessLogsBucket" -ForegroundColor Green
    }

    aws s3api put-public-access-block `
        --bucket $AlbAccessLogsBucket `
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" `
        --region $AwsRegion | Out-Null
    Assert-AwsSuccess "Block public access on '$AlbAccessLogsBucket'" -NonFatal

    # b. Delivery policy. In regions launched before Aug 2022 ELB writes from a
    #    per-region AWS account; newer regions use a service principal. Grant both so
    #    the policy is correct regardless of region age.
    $elbLogAccounts = @{
        'us-east-1'      = '127311923021'; 'us-east-2'      = '033677994240'
        'us-west-1'      = '027434742980'; 'us-west-2'      = '797873946194'
        'af-south-1'     = '098369216593'; 'ap-east-1'      = '754344448648'
        'ap-south-1'     = '718504428378'; 'ap-northeast-1' = '582318560864'
        'ap-northeast-2' = '600734575887'; 'ap-northeast-3' = '383597477331'
        'ap-southeast-1' = '114774131450'; 'ap-southeast-2' = '783225319266'
        'ap-southeast-3' = '589379963580'; 'ca-central-1'   = '985666609251'
        'eu-central-1'   = '054676820928'; 'eu-west-1'      = '156460612806'
        'eu-west-2'      = '652711504416'; 'eu-west-3'      = '009996457667'
        'eu-north-1'     = '897822967062'; 'eu-south-1'     = '635631232127'
        'me-south-1'     = '076674570225'; 'sa-east-1'      = '507241528517'
    }
    $albLogResource   = "arn:aws:s3:::${AlbAccessLogsBucket}/${AlbAccessLogsPrefix}/AWSLogs/${AwsAccountId}/*"
    $albLogStatements = @()
    if ($elbLogAccounts.ContainsKey($AwsRegion)) {
        $elbLogAccount = $elbLogAccounts[$AwsRegion]
        $albLogStatements += @"
        {
            "Sid": "AllowELBAccountPutObject",
            "Effect": "Allow",
            "Principal": { "AWS": "arn:aws:iam::${elbLogAccount}:root" },
            "Action": "s3:PutObject",
            "Resource": "$albLogResource"
        }
"@
    }
    $albLogStatements += @"
        {
            "Sid": "AllowLogDeliveryPutObject",
            "Effect": "Allow",
            "Principal": { "Service": "logdelivery.elasticloadbalancing.amazonaws.com" },
            "Action": "s3:PutObject",
            "Resource": "$albLogResource",
            "Condition": { "StringEquals": { "s3:x-amz-acl": "bucket-owner-full-control" } }
        }
"@
    $albLogStatements += @"
        {
            "Sid": "AllowLogDeliveryGetBucketAcl",
            "Effect": "Allow",
            "Principal": { "Service": "logdelivery.elasticloadbalancing.amazonaws.com" },
            "Action": "s3:GetBucketAcl",
            "Resource": "arn:aws:s3:::${AlbAccessLogsBucket}"
        }
"@
    $albLogPolicy = @"
{
    "Version": "2012-10-17",
    "Statement": [
$($albLogStatements -join ",`n")
    ]
}
"@
    $tempAlbLogPolicy = [System.IO.Path]::GetTempFileName()
    $albLogPolicy | Set-Content $tempAlbLogPolicy
    aws s3api put-bucket-policy `
        --bucket $AlbAccessLogsBucket `
        --policy "file://$tempAlbLogPolicy" `
        --region $AwsRegion | Out-Null
    Assert-AwsSuccess "Attach delivery policy to '$AlbAccessLogsBucket'"
    Remove-Item $tempAlbLogPolicy
    Write-Host "     Delivery policy applied" -ForegroundColor Green

    # c. Optional retention — access logs grow fast on busy load balancers.
    if ($AlbAccessLogsRetentionDays -and $AlbAccessLogsRetentionDays -gt 0) {
        $albLogLifecycle = @"
{
    "Rules": [
        {
            "ID": "expire-alb-access-logs",
            "Status": "Enabled",
            "Filter": { "Prefix": "${AlbAccessLogsPrefix}/" },
            "Expiration": { "Days": $AlbAccessLogsRetentionDays }
        }
    ]
}
"@
        $tempAlbLogLifecycle = [System.IO.Path]::GetTempFileName()
        $albLogLifecycle | Set-Content $tempAlbLogLifecycle
        aws s3api put-bucket-lifecycle-configuration `
            --bucket $AlbAccessLogsBucket `
            --lifecycle-configuration "file://$tempAlbLogLifecycle" `
            --region $AwsRegion | Out-Null
        Assert-AwsSuccess "Set ${AlbAccessLogsRetentionDays}-day retention on '$AlbAccessLogsBucket'" -NonFatal
        Remove-Item $tempAlbLogLifecycle
        Write-Host "     Retention: ${AlbAccessLogsRetentionDays} days" -ForegroundColor Green
    }

    # d. Enable on the ALB. AWS validates delivery with a test write, so this fails
    #    fast if the bucket policy above is wrong.
    $currentLogEnabled = aws elbv2 describe-load-balancer-attributes `
        --load-balancer-arn $albArn `
        --region $AwsRegion `
        --query "Attributes[?Key=='access_logs.s3.enabled'].Value | [0]" `
        --output text
    $currentLogBucket = aws elbv2 describe-load-balancer-attributes `
        --load-balancer-arn $albArn `
        --region $AwsRegion `
        --query "Attributes[?Key=='access_logs.s3.bucket'].Value | [0]" `
        --output text
    if ($currentLogEnabled -ne "true" -or $currentLogBucket -ne $AlbAccessLogsBucket) {
        aws elbv2 modify-load-balancer-attributes `
            --load-balancer-arn $albArn `
            --attributes "Key=access_logs.s3.enabled,Value=true" "Key=access_logs.s3.bucket,Value=$AlbAccessLogsBucket" "Key=access_logs.s3.prefix,Value=$AlbAccessLogsPrefix" `
            --region $AwsRegion | Out-Null
        Assert-AwsSuccess "Enable ALB access logs to '$AlbAccessLogsBucket'"
        Write-Host "  ALB access logs enabled" -ForegroundColor Green
    } else {
        Write-Host "  ALB access logs already enabled -> s3://$AlbAccessLogsBucket/$AlbAccessLogsPrefix" -ForegroundColor Green
    }
}

# Get ALB DNS name
$albDns = aws elbv2 describe-load-balancers `
    --load-balancer-arns $albArn `
    --region $AwsRegion `
    --query 'LoadBalancers[0].DNSName' `
    --output text

# 8. Create Target Group
Write-Host "8. Creating Target Group..." -ForegroundColor Yellow

$tgArn = aws elbv2 describe-target-groups `
    --names $TargetGroupName `
    --region $AwsRegion `
    --query 'TargetGroups[0].TargetGroupArn' `
    --output text 2>$null

if (-not $tgArn -or $tgArn -eq "None") {
    $tgArn = aws elbv2 create-target-group `
        --name $TargetGroupName `
        --protocol HTTP `
        --port $ContainerPort `
        --vpc-id $VpcId `
        --target-type ip `
        --health-check-enabled `
        --health-check-path $HealthCheckPath `
        --health-check-interval-seconds 30 `
        --health-check-timeout-seconds 10 `
        --healthy-threshold-count 2 `
        --unhealthy-threshold-count 3 `
        --region $AwsRegion `
        --query 'TargetGroups[0].TargetGroupArn' `
        --output text
    Assert-AwsSuccess "Create target group '$TargetGroupName'"

    # Set idle timeout for SSE support
    aws elbv2 modify-target-group-attributes `
        --target-group-arn $tgArn `
        --attributes Key=deregistration_delay.timeout_seconds,Value=30 `
        --region $AwsRegion
    Assert-AwsSuccess "Set deregistration delay on target group"

    Write-Host "  Target group created: $tgArn" -ForegroundColor Green
}
else {
    Write-Host "  Target group exists: $tgArn" -ForegroundColor Green
}

# 9. Create ALB Listener
Write-Host "9. Creating ALB Listener..." -ForegroundColor Yellow

$listenerExists = aws elbv2 describe-listeners `
    --load-balancer-arn $albArn `
    --region $AwsRegion `
    --query 'Listeners[0].ListenerArn' `
    --output text

if (-not $listenerExists -or $listenerExists -eq "None") {
    if ($CertificateArn) {
        # HTTPS listener
        aws elbv2 create-listener `
            --load-balancer-arn $albArn `
            --protocol HTTPS `
            --port 443 `
            --certificates "CertificateArn=$CertificateArn" `
            --default-actions "Type=forward,TargetGroupArn=$tgArn" `
            --region $AwsRegion
        Assert-AwsSuccess "Create HTTPS listener on ALB"
        Write-Host "  HTTPS listener created" -ForegroundColor Green

        # Optional HTTP -> HTTPS redirect listener (best practice).
        # The AWS CLI shorthand parser cannot reliably handle the nested
        # RedirectConfig={...} structure when arguments transit through
        # PowerShell's native-command quoting (it ends up parsed as a single
        # string, producing "Invalid type for parameter ...RedirectConfig").
        # Use inline JSON via a variable to bypass the shorthand parser.
        $redirectActions = '[{"Type":"redirect","RedirectConfig":{"Protocol":"HTTPS","Port":"443","StatusCode":"HTTP_301"}}]'
        aws elbv2 create-listener `
            --load-balancer-arn $albArn `
            --protocol HTTP `
            --port 80 `
            --default-actions $redirectActions `
            --region $AwsRegion | Out-Null
        Assert-AwsSuccess "Create HTTP->HTTPS redirect listener" -NonFatal
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  HTTP->HTTPS redirect listener created" -ForegroundColor Green
        }
    }
    else {
        # HTTP listener (for testing)
        aws elbv2 create-listener `
            --load-balancer-arn $albArn `
            --protocol HTTP `
            --port 80 `
            --default-actions "Type=forward,TargetGroupArn=$tgArn" `
            --region $AwsRegion
        Assert-AwsSuccess "Create HTTP listener on ALB"
        Write-Host "  HTTP listener created (no certificate provided)" -ForegroundColor Yellow
        Write-Host "  WARNING: For production, provide -CertificateArn parameter" -ForegroundColor Yellow
    }
}
else {
    Write-Host "  Listener already exists" -ForegroundColor Green
}

# CRITICAL: Verify listener is actually attached to ALB
Write-Host "  Verifying listener attachment..." -ForegroundColor Yellow
$verifyListener = aws elbv2 describe-listeners `
    --load-balancer-arn $albArn `
    --region $AwsRegion `
    --query 'Listeners[0].ListenerArn' `
    --output text
if (-not $verifyListener -or $verifyListener -eq "None") {
    Write-Host "" -ForegroundColor Red
    Write-Host "==========================================" -ForegroundColor Red
    Write-Host "  FATAL: ALB has NO listeners!" -ForegroundColor Red
    Write-Host "  The target group is not linked to the ALB." -ForegroundColor Red
    Write-Host "  ECS service creation WILL FAIL without this." -ForegroundColor Red
    Write-Host "==========================================" -ForegroundColor Red
    throw"ALB listener verification failed: no listeners found on $AlbName"
}
Write-Host "  Listener verified: $verifyListener" -ForegroundColor Green

# =============================================================================
# 9b. Network Load Balancer Setup (optional — requires -EnableNlb)
# =============================================================================
if ($EnableNlb) {
    Write-Host ""
    Write-Host "9b. Setting up Network Load Balancer (NLB) in front of ALB..." -ForegroundColor Yellow

    # Elastic IPs are public and cannot be assigned to internal NLBs.
    # Internal NLBs already get static private IPs from the subnet CIDR.
    if ($NlbElasticIpAllocationIds) {
        Write-Host ""
        Write-Host "==========================================" -ForegroundColor Red
        Write-Host "  CONFIGURATION ERROR" -ForegroundColor Red
        Write-Host "  NlbElasticIpAllocationIds cannot be used" -ForegroundColor Red
        Write-Host "  with internal NLBs. Elastic IPs are public" -ForegroundColor Red
        Write-Host "  and only work with internet-facing NLBs." -ForegroundColor Red
        Write-Host "" -ForegroundColor Red
        Write-Host "  Internal NLBs already get static private" -ForegroundColor Red
        Write-Host "  IPs from the subnet CIDR — no EIPs needed." -ForegroundColor Red
        Write-Host "" -ForegroundColor Red
        Write-Host "  Remove NlbElasticIpAllocationIds from" -ForegroundColor Red
        Write-Host "  ecs-config.json and release the EIPs." -ForegroundColor Red
        Write-Host "==========================================" -ForegroundColor Red
        throw"NlbElasticIpAllocationIds is not compatible with internal NLBs. Remove it from ecs-config.json."
    }

    # 9b.a Create NLB Target Group(s) (type=alb)
    # Primary target group forwards to the ALB's main listener port.
    # When HTTPS is configured, a second target group on port 80 is needed
    # so NLB TCP:80 reaches the ALB's HTTP->HTTPS redirect listener.
    Write-Host "  a. Creating NLB Target Group(s) (type=alb)..." -ForegroundColor Yellow

    $nlbPort = if ($CertificateArn) { 443 } else { 80 }

    # When the NLB target group's traffic port is 443 (TLS termination at ALB),
    # the health check itself must speak HTTPS — otherwise AWS's default HTTP
    # health check sends plain HTTP into the ALB's TLS-only listener and every
    # probe fails with Target.FailedHealthChecks.
    $nlbHcArgs = @()
    if ($CertificateArn) {
        $nlbHcArgs = @(
            '--health-check-protocol', 'HTTPS',
            '--health-check-path', '/',
            '--matcher', 'HttpCode=200-399'
        )
    }

    $nlbTgArn = aws elbv2 describe-target-groups `
        --names $NlbTargetGroupName `
        --region $AwsRegion `
        --query 'TargetGroups[0].TargetGroupArn' `
        --output text 2>$null

    if (-not $nlbTgArn -or $nlbTgArn -eq "None") {
        $nlbTgArn = aws elbv2 create-target-group `
            --name $NlbTargetGroupName `
            --protocol TCP `
            --port $nlbPort `
            --vpc-id $VpcId `
            --target-type alb `
            --health-check-enabled `
            @nlbHcArgs `
            --region $AwsRegion `
            --query 'TargetGroups[0].TargetGroupArn' `
            --output text
        Assert-AwsSuccess "Create NLB target group '$NlbTargetGroupName'"
        Write-Host "     NLB target group created (port $nlbPort): $nlbTgArn" -ForegroundColor Green
    }
    else {
        Write-Host "     NLB target group exists (port $nlbPort): $nlbTgArn" -ForegroundColor Green
        # Self-heal: enforce HTTPS health check on existing target groups created
        # before this fix landed (the original CCM script left them with default
        # HTTP, which silently breaks NLB→ALB HTTPS routing).
        if ($CertificateArn) {
            aws elbv2 modify-target-group `
                --target-group-arn $nlbTgArn `
                --health-check-protocol HTTPS `
                --health-check-path / `
                --matcher HttpCode=200-399 `
                --region $AwsRegion | Out-Null
            Assert-AwsSuccess "Enforce HTTPS health check on NLB target group '$NlbTargetGroupName'" -NonFatal
        }
    }

    # When HTTPS: create a second target group on port 80 for the redirect listener
    if ($CertificateArn) {
        $nlbHttpTgArn = aws elbv2 describe-target-groups `
            --names $NlbHttpTargetGroupName `
            --region $AwsRegion `
            --query 'TargetGroups[0].TargetGroupArn' `
            --output text 2>$null

        if (-not $nlbHttpTgArn -or $nlbHttpTgArn -eq "None") {
            $nlbHttpTgArn = aws elbv2 create-target-group `
                --name $NlbHttpTargetGroupName `
                --protocol TCP `
                --port 80 `
                --vpc-id $VpcId `
                --target-type alb `
                --health-check-enabled `
                --region $AwsRegion `
                --query 'TargetGroups[0].TargetGroupArn' `
                --output text
            Assert-AwsSuccess "Create NLB HTTP redirect target group '$NlbHttpTargetGroupName'"
            Write-Host "     NLB HTTP redirect target group created (port 80): $nlbHttpTgArn" -ForegroundColor Green
        }
        else {
            Write-Host "     NLB HTTP redirect target group exists (port 80): $nlbHttpTgArn" -ForegroundColor Green
        }
    }

    # 9b.b Register ALB as target in NLB target group(s)
    Write-Host "  b. Registering ALB as target in NLB target group(s)..." -ForegroundColor Yellow
    $existingTargets = aws elbv2 describe-target-health `
        --target-group-arn $nlbTgArn `
        --region $AwsRegion `
        --query 'TargetHealthDescriptions[0].Target.Id' `
        --output text 2>$null

    if (-not $existingTargets -or $existingTargets -eq "None") {
        aws elbv2 register-targets `
            --target-group-arn $nlbTgArn `
            --targets "Id=$albArn" `
            --region $AwsRegion
        Assert-AwsSuccess "Register ALB as target in NLB target group"
        Write-Host "     ALB registered in primary target group" -ForegroundColor Green
    }
    else {
        Write-Host "     ALB already registered in primary target group" -ForegroundColor Green
    }

    if ($CertificateArn -and $nlbHttpTgArn) {
        $existingHttpTargets = aws elbv2 describe-target-health `
            --target-group-arn $nlbHttpTgArn `
            --region $AwsRegion `
            --query 'TargetHealthDescriptions[0].Target.Id' `
            --output text 2>$null

        if (-not $existingHttpTargets -or $existingHttpTargets -eq "None") {
            aws elbv2 register-targets `
                --target-group-arn $nlbHttpTgArn `
                --targets "Id=$albArn" `
                --region $AwsRegion
            Assert-AwsSuccess "Register ALB as target in NLB HTTP redirect target group"
            Write-Host "     ALB registered in HTTP redirect target group" -ForegroundColor Green
        }
        else {
            Write-Host "     ALB already registered in HTTP redirect target group" -ForegroundColor Green
        }
    }

    # 9b.c Create NLB
    Write-Host "  c. Creating Network Load Balancer..." -ForegroundColor Yellow
    $nlbArn = aws elbv2 describe-load-balancers `
        --names $NlbName `
        --region $AwsRegion `
        --query 'LoadBalancers[0].LoadBalancerArn' `
        --output text 2>$null

    if (-not $nlbArn -or $nlbArn -eq "None") {
        if ($NlbElasticIpAllocationIds) {
            # Build subnet-mappings for EIP assignment
            $eipList = ($NlbElasticIpAllocationIds -split ',') | ForEach-Object { $_.Trim() }
            $subnetMappings = @()
            for ($i = 0; $i -lt $Subnets.Count; $i++) {
                if ($i -lt $eipList.Count) {
                    $subnetMappings += "SubnetId=$($Subnets[$i]),AllocationId=$($eipList[$i])"
                } else {
                    $subnetMappings += "SubnetId=$($Subnets[$i])"
                }
            }
            $nlbArn = aws elbv2 create-load-balancer `
                --name $NlbName `
                --type network `
                --scheme internal `
                --subnet-mappings $subnetMappings `
                --region $AwsRegion `
                --query 'LoadBalancers[0].LoadBalancerArn' `
                --output text
        }
        else {
            $nlbArn = aws elbv2 create-load-balancer `
                --name $NlbName `
                --type network `
                --scheme internal `
                --subnets $Subnets `
                --region $AwsRegion `
                --query 'LoadBalancers[0].LoadBalancerArn' `
                --output text
        }
        Assert-AwsSuccess "Create Network Load Balancer '$NlbName'"

        # Wait for NLB to become active
        Write-Host "     Waiting for NLB to become active..." -ForegroundColor Yellow
        aws elbv2 wait load-balancer-available `
            --load-balancer-arns $nlbArn `
            --region $AwsRegion
        Assert-AwsSuccess "Wait for NLB '$NlbName' to become active"
        Write-Host "     NLB is active" -ForegroundColor Green

        Write-Host "     NLB created: $nlbArn" -ForegroundColor Green
    }
    else {
        Write-Host "     NLB exists: $nlbArn" -ForegroundColor Green
    }

    # Enable cross-zone load balancing (disabled by default on NLB)
    $currentCrossZone = aws elbv2 describe-load-balancer-attributes `
        --load-balancer-arn $nlbArn `
        --region $AwsRegion `
        --query "Attributes[?Key=='load_balancing.cross_zone.enabled'].Value | [0]" `
        --output text
    if ($currentCrossZone -ne "true") {
        Write-Host "     Enabling cross-zone load balancing..." -ForegroundColor Yellow
        aws elbv2 modify-load-balancer-attributes `
            --load-balancer-arn $nlbArn `
            --attributes "Key=load_balancing.cross_zone.enabled,Value=true" `
            --region $AwsRegion | Out-Null
        Assert-AwsSuccess "Enable cross-zone load balancing on NLB"
        Write-Host "     Cross-zone load balancing enabled" -ForegroundColor Green
    }

    # Get NLB DNS name
    $nlbDns = aws elbv2 describe-load-balancers `
        --load-balancer-arns $nlbArn `
        --region $AwsRegion `
        --query 'LoadBalancers[0].DNSName' `
        --output text

    # 9b.d Create NLB TCP Listener(s)
    Write-Host "  d. Creating NLB TCP Listener(s)..." -ForegroundColor Yellow
    $nlbListeners = aws elbv2 describe-listeners `
        --load-balancer-arn $nlbArn `
        --region $AwsRegion `
        --query 'Listeners[*].Port' `
        --output json 2>$null | ConvertFrom-Json

    if (-not $nlbListeners -or $nlbListeners.Count -eq 0) {
        if ($CertificateArn) {
            # NLB TCP:443 -> NLB TG (port 443) -> ALB HTTPS listener (TLS termination)
            aws elbv2 create-listener `
                --load-balancer-arn $nlbArn `
                --protocol TCP `
                --port 443 `
                --default-actions "Type=forward,TargetGroupArn=$nlbTgArn" `
                --region $AwsRegion | Out-Null
            Assert-AwsSuccess "Create NLB TCP:443 listener"
            Write-Host "     NLB TCP:443 listener created -> ALB HTTPS" -ForegroundColor Green

            # NLB TCP:80 -> NLB HTTP TG (port 80) -> ALB HTTP->HTTPS redirect listener
            aws elbv2 create-listener `
                --load-balancer-arn $nlbArn `
                --protocol TCP `
                --port 80 `
                --default-actions "Type=forward,TargetGroupArn=$nlbHttpTgArn" `
                --region $AwsRegion | Out-Null
            Assert-AwsSuccess "Create NLB TCP:80 listener"
            Write-Host "     NLB TCP:80 listener created -> ALB HTTP->HTTPS redirect" -ForegroundColor Green
        }
        else {
            # HTTP only: NLB TCP:80 -> NLB TG (port 80) -> ALB HTTP listener
            aws elbv2 create-listener `
                --load-balancer-arn $nlbArn `
                --protocol TCP `
                --port 80 `
                --default-actions "Type=forward,TargetGroupArn=$nlbTgArn" `
                --region $AwsRegion | Out-Null
            Assert-AwsSuccess "Create NLB TCP:80 listener"
            Write-Host "     NLB TCP:80 listener created" -ForegroundColor Green
        }
    }
    else {
        Write-Host "     NLB listener(s) already exist (ports: $($nlbListeners -join ', '))" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "  NLB DNS: $nlbDns" -ForegroundColor Cyan
    Write-Host "  NOTE: NLB is transparent (no security group). Traffic arrives at ALB with original source IP." -ForegroundColor Yellow
    Write-Host "  If using PrivateLink, add consumer VPC CIDRs to the ALB security group ($albSgId)." -ForegroundColor Yellow

    # 9b.f Expose extra container ports via NLB (configurable per project)
    # Each entry creates: target group (type=ip), TCP listener, ECS-SG ingress
    # rules for each VpnCidr block. Used for direct dev/debug access to side-car
    # containers (Neo4j Browser, Qdrant dashboard, etc.) without leaking them
    # through the ALB's path-routed application traffic.
    $exposedTargetGroups = @()
    if ($ExposeContainerPorts -and $ExposeContainerPorts.Count -gt 0) {
        Write-Host ""
        Write-Host "  f. Exposing $($ExposeContainerPorts.Count) extra container port(s) via NLB..." -ForegroundColor Yellow

        # Existing NLB listener ports (so we don't try to create a duplicate)
        $existingListenerPorts = aws elbv2 describe-listeners `
            --load-balancer-arn $nlbArn `
            --region $AwsRegion `
            --query 'Listeners[*].Port' `
            --output json | ConvertFrom-Json

        # NB: PowerShell variable names are case-insensitive, so $ContainerPort
        # (the script-level parameter for the primary ALB target) and any
        # locally-named $containerPort would alias each other and clobber the
        # parameter on the last iteration. We use $entryPort / $entryContainerPort
        # below to avoid that.
        foreach ($entry in $ExposeContainerPorts) {
            $entryPort           = [int]$entry.Port
            $entryContainerName  = [string]$entry.ContainerName
            $entryContainerPort  = if ($entry.ContainerPort) { [int]$entry.ContainerPort } else { $entryPort }
            $entryProtocol       = if ($entry.Protocol) { [string]$entry.Protocol } else { 'TCP' }
            $entryHcProto        = if ($entry.HealthCheckProtocol) { [string]$entry.HealthCheckProtocol } else { 'TCP' }
            $entryHcPath         = if ($entry.HealthCheckPath)     { [string]$entry.HealthCheckPath }     else { '/' }
            $entryHcMatcher      = if ($entry.HealthCheckMatcher)  { [string]$entry.HealthCheckMatcher }  else { '200-399' }

            if (-not $entryContainerName) {
                Write-Warning "     Skipping ExposeContainerPorts entry with missing ContainerName (port $entryPort)"
                continue
            }
            if ($entryPort -eq 80 -or $entryPort -eq 443) {
                Write-Warning "     Skipping ExposeContainerPorts entry on reserved port $entryPort (use the ALB path)"
                continue
            }

            $tgName = "$ProjectName-nlb-${entryPort}-tg"
            if ($tgName.Length -gt 32) {
                Write-Warning "     Target group name '$tgName' exceeds 32 chars; truncating"
                $tgName = $tgName.Substring(0, 32)
            }

            # 1) Target group (type=ip, on the container's actual port)
            $exposedTgArn = aws elbv2 describe-target-groups `
                --names $tgName `
                --region $AwsRegion `
                --query 'TargetGroups[0].TargetGroupArn' `
                --output text 2>$null

            $exposedTgHcArgs = @()
            if ($entryHcProto -eq 'HTTP' -or $entryHcProto -eq 'HTTPS') {
                $exposedTgHcArgs = @(
                    '--health-check-protocol', $entryHcProto,
                    '--health-check-path', $entryHcPath,
                    '--matcher', "HttpCode=$entryHcMatcher"
                )
            } else {
                $exposedTgHcArgs = @('--health-check-protocol', 'TCP')
            }

            if (-not $exposedTgArn -or $exposedTgArn -eq "None") {
                $exposedTgArn = aws elbv2 create-target-group `
                    --name $tgName `
                    --protocol $entryProtocol `
                    --port $entryContainerPort `
                    --vpc-id $VpcId `
                    --target-type ip `
                    --health-check-enabled `
                    @exposedTgHcArgs `
                    --region $AwsRegion `
                    --query 'TargetGroups[0].TargetGroupArn' `
                    --output text
                Assert-AwsSuccess "Create exposed-port target group '$tgName'"
                Write-Host "     Created target group: $tgName ($entryProtocol/$entryContainerPort, $entryHcProto health)" -ForegroundColor Green
            }
            else {
                Write-Host "     Target group exists: $tgName" -ForegroundColor Green
                # Self-heal: enforce current health-check settings
                aws elbv2 modify-target-group `
                    --target-group-arn $exposedTgArn `
                    @exposedTgHcArgs `
                    --region $AwsRegion | Out-Null
                Assert-AwsSuccess "Reconcile health check on '$tgName'" -NonFatal
            }

            # 2) NLB listener — only if a listener for this port doesn't already exist
            if ($existingListenerPorts -notcontains $entryPort) {
                aws elbv2 create-listener `
                    --load-balancer-arn $nlbArn `
                    --protocol $entryProtocol `
                    --port $entryPort `
                    --default-actions "Type=forward,TargetGroupArn=$exposedTgArn" `
                    --region $AwsRegion | Out-Null
                Assert-AwsSuccess "Create NLB ${entryProtocol}:${entryPort} listener"
                Write-Host "     Created NLB listener: ${entryProtocol}:${entryPort} -> $tgName" -ForegroundColor Green
            }
            else {
                Write-Host "     NLB listener already exists on port $entryPort (skipping)" -ForegroundColor Green
            }

            # 3) ECS-SG ingress: NLB type=ip preserves client source IP, so allow
            #    each VpnCidr block directly on the container port.
            foreach ($cidr in $cidrList) {
                aws ec2 authorize-security-group-ingress `
                    --group-id $ecsSgId `
                    --protocol tcp `
                    --port $entryContainerPort `
                    --cidr $cidr `
                    --region $AwsRegion 2>$null | Out-Null
                # Duplicate-rule errors are non-fatal; log only on real failure
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "     Note: ingress rule for $cidr on port $entryContainerPort may already exist (non-fatal)" -ForegroundColor Yellow
                }
            }

            $exposedTargetGroups += [PSCustomObject]@{
                Port           = $entryPort
                ContainerName  = $entryContainerName
                ContainerPort  = $entryContainerPort
                Protocol       = $entryProtocol
                TargetGroupArn = $exposedTgArn
            }
        }
    }
}

# =============================================================================
# 9c. Route 53 DNS Record (optional — requires Route53HostedZoneId + ParentDomain)
#
# Subdomains get a CNAME -> LB DNS name. The zone apex (CustomDomainName ==
# ParentDomain) gets an A-ALIAS to the LB instead, because CNAMEs at a zone
# apex are illegal per RFC 1034 §3.6.2.
# =============================================================================
if ($Route53HostedZoneId -and $ParentDomain) {
    # Auto-derive CustomDomainName if not set
    if (-not $CustomDomainName) {
        $CustomDomainName = "$ProjectName.$ParentDomain"
        Write-Host "  Auto-derived CustomDomainName: $CustomDomainName" -ForegroundColor Cyan
    }

    # Apex when CustomDomainName equals ParentDomain (trailing dots normalised)
    $isApex = ($CustomDomainName.TrimEnd('.') -eq $ParentDomain.TrimEnd('.'))

    # When NLB is enabled, DNS should point to NLB instead of ALB
    $dnsTarget    = if ($EnableNlb -and $nlbDns) { $nlbDns } else { $albDns }
    $dnsTargetArn = if ($EnableNlb -and $nlbArn) { $nlbArn } else { $albArn }
    $recordType   = if ($isApex) { 'A' } else { 'CNAME' }
    $displayType  = if ($isApex) { 'A-ALIAS' } else { 'CNAME' }

    Write-Host "  Creating Route 53 ${displayType}: $CustomDomainName -> $dnsTarget" -ForegroundColor Yellow

    # Build the ResourceRecordSet payload (apex needs the LB's CanonicalHostedZoneId)
    $resourceRecordSet = $null
    if ($isApex) {
        $lbCanonicalZone = aws elbv2 describe-load-balancers `
            --load-balancer-arns $dnsTargetArn `
            --region $AwsRegion `
            --query 'LoadBalancers[0].CanonicalHostedZoneId' `
            --output text

        if (-not $lbCanonicalZone -or $lbCanonicalZone -eq "None") {
            Write-Host "  WARNING: Could not resolve LB CanonicalHostedZoneId; skipping apex DNS." -ForegroundColor Yellow
            $script:stepErrors += "Could not resolve LB CanonicalHostedZoneId for apex alias $CustomDomainName"
        } else {
            $resourceRecordSet = @{
                Name = $CustomDomainName
                Type = "A"
                AliasTarget = @{
                    HostedZoneId         = $lbCanonicalZone
                    DNSName              = $dnsTarget
                    EvaluateTargetHealth = $false
                }
            }
        }
    } else {
        $resourceRecordSet = @{
            Name = $CustomDomainName
            Type = "CNAME"
            TTL = 300
            ResourceRecords = @(@{ Value = $dnsTarget })
        }
    }

    if ($resourceRecordSet) {
        # Look up any existing record of the same name+type
        $existingRecord = aws route53 list-resource-record-sets `
            --hosted-zone-id $Route53HostedZoneId `
            --query "ResourceRecordSets[?Name=='${CustomDomainName}.' && Type=='${recordType}']" `
            --output json 2>$null | ConvertFrom-Json

        # Extract the current target for idempotency comparison
        $currentValue = $null
        if ($existingRecord.Count -gt 0) {
            if ($isApex -and $existingRecord[0].AliasTarget) {
                $currentValue = $existingRecord[0].AliasTarget.DNSName
            } elseif (-not $isApex -and $existingRecord[0].ResourceRecords) {
                $currentValue = $existingRecord[0].ResourceRecords[0].Value
            }
        }

        $alreadyCorrect = $existingRecord.Count -gt 0 -and $currentValue `
            -and ($currentValue.TrimEnd('.') -eq $dnsTarget.TrimEnd('.'))

        if ($alreadyCorrect) {
            Write-Host "  Route 53 ${displayType} already exists and is correct" -ForegroundColor Green
        } else {
            $action = if ($existingRecord.Count -gt 0) { 'UPSERT' } else { 'CREATE' }
            if ($action -eq 'UPSERT') {
                Write-Host "  Route 53 ${displayType} exists but points to '$currentValue', updating..." -ForegroundColor Yellow
            }

            $changeBatch = @{
                Changes = @(@{
                    Action = $action
                    ResourceRecordSet = $resourceRecordSet
                })
            } | ConvertTo-Json -Depth 6 -Compress

            $tempDns = [System.IO.Path]::GetTempFileName()
            $changeBatch | Set-Content $tempDns
            aws route53 change-resource-record-sets `
                --hosted-zone-id $Route53HostedZoneId `
                --change-batch "file://$tempDns" | Out-Null
            Remove-Item $tempDns
            if ($LASTEXITCODE -eq 0) {
                if ($action -eq 'UPSERT') {
                    Write-Host "  Route 53 ${displayType} updated" -ForegroundColor Green
                } else {
                    Write-Host "  Route 53 ${displayType} created: $CustomDomainName -> $dnsTarget" -ForegroundColor Green
                }
            } else {
                $verb = if ($action -eq 'UPSERT') { 'update' } else { 'create' }
                Write-Host "  WARNING: Could not ${verb} Route 53 ${displayType}" -ForegroundColor Yellow
                $script:stepErrors += "Could not ${verb} Route 53 ${displayType} for $CustomDomainName"
            }
        }
    }
} elseif ($ParentDomain -and -not $Route53HostedZoneId) {
    Write-Host ""
    Write-Host "  Route 53 record: skipped (ParentDomain set but Route53HostedZoneId missing)" -ForegroundColor Yellow
    Write-Host "  Run setup-route53-zone.ps1 first, then add Route53HostedZoneId to ecs-config.json" -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "  Route 53 record: skipped (no ParentDomain/Route53HostedZoneId in config)" -ForegroundColor DarkGray
}

# =============================================================================
# 10. EFS Setup (optional — requires -EnableEfs)
# =============================================================================
if ($EnableEfs) {
    Write-Host ""
    Write-Host "10. Setting up EFS (Elastic File System)..." -ForegroundColor Yellow

    $EfsName = "$ProjectName-efs"
    $EfsSecurityGroupName = "$ProjectName-efs-sg"

    # 10a. EFS Security Group
    Write-Host "  a. Creating EFS Security Group..." -ForegroundColor Yellow
    $efsSgId = aws ec2 describe-security-groups `
        --filters "Name=group-name,Values=$EfsSecurityGroupName" "Name=vpc-id,Values=$VpcId" `
        --region $AwsRegion `
        --query 'SecurityGroups[0].GroupId' `
        --output text
    if ($efsSgId -eq "None" -or -not $efsSgId) {
        $efsSgId = aws ec2 create-security-group `
            --group-name $EfsSecurityGroupName `
            --description "EFS access for $ProjectName" `
            --vpc-id $VpcId `
            --region $AwsRegion `
            --query 'GroupId' `
            --output text
        Assert-AwsSuccess "Create EFS security group '$EfsSecurityGroupName'"
        Write-Host "     Created: $efsSgId" -ForegroundColor Green
    } else {
        Write-Host "     Exists: $efsSgId" -ForegroundColor Green
    }

    # Allow NFS (port 2049) from ECS security group
    Write-Host "  b. Configuring NFS ingress rule..." -ForegroundColor Yellow
    $existingNfsRule = aws ec2 describe-security-group-rules `
        --filters "Name=group-id,Values=$efsSgId" `
        --region $AwsRegion `
        --query "SecurityGroupRules[?FromPort==``2049`` && ToPort==``2049`` && ReferencedGroupInfo.GroupId=='$ecsSgId']" `
        --output json | ConvertFrom-Json

    if ($existingNfsRule.Count -eq 0) {
        aws ec2 authorize-security-group-ingress `
            --group-id $efsSgId `
            --protocol tcp `
            --port 2049 `
            --source-group $ecsSgId `
            --region $AwsRegion
        Assert-AwsSuccess "Add NFS ingress rule (port 2049 from ECS SG $ecsSgId)"
        Write-Host "     Added: port 2049 from ECS security group ($ecsSgId)" -ForegroundColor Green
    } else {
        Write-Host "     Rule exists: port 2049 from ECS security group" -ForegroundColor Green
    }

    # 10c. Create EFS filesystem
    Write-Host "  c. Creating EFS filesystem..." -ForegroundColor Yellow
    $efsId = aws efs describe-file-systems `
        --region $AwsRegion `
        --query "FileSystems[?Tags[?Key=='Name' && Value=='$EfsName']].FileSystemId | [0]" `
        --output text

    if (-not $efsId -or $efsId -eq "None") {
        $efsId = aws efs create-file-system `
            --performance-mode generalPurpose `
            --throughput-mode bursting `
            --encrypted `
            --tags "Key=Name,Value=$EfsName" `
            --region $AwsRegion `
            --query 'FileSystemId' `
            --output text
        Assert-AwsSuccess "Create EFS filesystem '$EfsName'"
        Write-Host "     Created: $efsId" -ForegroundColor Green

        # Wait for filesystem to become available
        Write-Host "     Waiting for EFS to become available..." -ForegroundColor Yellow
        $efsState = "creating"
        $waitCount = 0
        while ($efsState -ne "available" -and $waitCount -lt 60) {
            Start-Sleep -Seconds 5
            $efsState = aws efs describe-file-systems `
                --file-system-id $efsId `
                --region $AwsRegion `
                --query 'FileSystems[0].LifeCycleState' `
                --output text
            $waitCount++
        }
        if ($efsState -ne "available") {
            Write-Host "     WARNING: EFS state is '$efsState' after waiting" -ForegroundColor Yellow
        } else {
            Write-Host "     EFS is available" -ForegroundColor Green
        }
    } else {
        Write-Host "     Exists: $efsId" -ForegroundColor Green
    }

    # 10d. Create mount targets in each subnet
    Write-Host "  d. Creating mount targets..." -ForegroundColor Yellow
    foreach ($subnet in $Subnets) {
        $existingMt = aws efs describe-mount-targets `
            --file-system-id $efsId `
            --region $AwsRegion `
            --query "MountTargets[?SubnetId=='$subnet'].MountTargetId | [0]" `
            --output text

        if (-not $existingMt -or $existingMt -eq "None") {
            aws efs create-mount-target `
                --file-system-id $efsId `
                --subnet-id $subnet `
                --security-groups $efsSgId `
                --region $AwsRegion | Out-Null
            Assert-AwsSuccess "Create EFS mount target in $subnet"
            Write-Host "     Created mount target in: $subnet" -ForegroundColor Green
        } else {
            Write-Host "     Mount target exists in: $subnet" -ForegroundColor Green
        }
    }

    # 10e. Set EFS file system policy (allow IAM-authorized mounts from within VPC)
    Write-Host "  e. Setting EFS file system policy..." -ForegroundColor Yellow
    $efsFsPolicy = @"
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowEcsTaskRole",
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::${AwsAccountId}:role/${TaskRoleName}"
            },
            "Action": [
                "elasticfilesystem:ClientMount",
                "elasticfilesystem:ClientWrite",
                "elasticfilesystem:ClientRootAccess"
            ],
            "Resource": "arn:aws:elasticfilesystem:${AwsRegion}:${AwsAccountId}:file-system/${efsId}"
        }
    ]
}
"@
    $tempEfsFsPolicy = [System.IO.Path]::GetTempFileName()
    $efsFsPolicy | Set-Content $tempEfsFsPolicy
    aws efs put-file-system-policy `
        --file-system-id $efsId `
        --policy (Get-Content $tempEfsFsPolicy -Raw) `
        --region $AwsRegion | Out-Null
    Assert-AwsSuccess "Set EFS file system policy" -NonFatal
    Remove-Item $tempEfsFsPolicy
    Write-Host "     EFS file system policy set" -ForegroundColor Green

    # 10f. Grant ECS task role EFS access (required for IAM-authorized access points)
    Write-Host "  e. Granting ECS task role EFS access..." -ForegroundColor Yellow
    $efsPolicy = @"
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "elasticfilesystem:ClientMount",
                "elasticfilesystem:ClientWrite",
                "elasticfilesystem:ClientRootAccess"
            ],
            "Resource": "arn:aws:elasticfilesystem:${AwsRegion}:${AwsAccountId}:file-system/${efsId}"
        }
    ]
}
"@
    $tempEfsPolicy = [System.IO.Path]::GetTempFileName()
    $efsPolicy | Set-Content $tempEfsPolicy
    aws iam put-role-policy `
        --role-name $TaskRoleName `
        --policy-name "$ProjectName-efs-access" `
        --policy-document "file://$tempEfsPolicy"
    Assert-AwsSuccess "Attach EFS policy to task role '$TaskRoleName'"
    Remove-Item $tempEfsPolicy
    Write-Host "     EFS access granted to $TaskRoleName" -ForegroundColor Green

    Write-Host ""
    Write-Host "  EFS setup complete! FileSystemId: $efsId" -ForegroundColor Green
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "10. EFS: skipped (use -EnableEfs to create)" -ForegroundColor DarkGray
}

# =============================================================================
# 11. S3 Bucket Setup (optional — requires -EnableS3)
# =============================================================================
if ($EnableS3) {
    Write-Host ""
    Write-Host "11. Setting up S3 bucket for document storage..." -ForegroundColor Yellow

    if (-not $S3BucketName) { $S3BucketName = "$ProjectName-documents-$AwsAccountId" }
    Write-Host "  Bucket: $S3BucketName"

    # 11a. Create bucket
    Write-Host "  a. Creating S3 bucket..." -ForegroundColor Yellow
    $bucketExists = aws s3api head-bucket --bucket $S3BucketName --region $AwsRegion 2>$null
    if ($LASTEXITCODE -ne 0) {
        if ($AwsRegion -eq "us-east-1") {
            aws s3api create-bucket `
                --bucket $S3BucketName `
                --region $AwsRegion | Out-Null
        } else {
            aws s3api create-bucket `
                --bucket $S3BucketName `
                --region $AwsRegion `
                --create-bucket-configuration "LocationConstraint=$AwsRegion" | Out-Null
        }
        Assert-AwsSuccess "Create S3 bucket '$S3BucketName'"
        Write-Host "     Created: $S3BucketName" -ForegroundColor Green
    } else {
        Write-Host "     Exists: $S3BucketName" -ForegroundColor Green
    }

    # 11b. Versioning. On by default -- protects against accidental deletion
    # -- but can be turned off: a project that documents a hard delete with
    # no undelete path must not have versioning silently turned back on
    # underneath it, because the objects would remain recoverable while the
    # documentation says they are gone.
    if ($S3BucketVersioning) {
        Write-Host "  b. Enabling bucket versioning..." -ForegroundColor Yellow
        aws s3api put-bucket-versioning `
            --bucket $S3BucketName `
            --versioning-configuration Status=Enabled `
            --region $AwsRegion | Out-Null
        Assert-AwsSuccess "Enable versioning on '$S3BucketName'" -NonFatal
        Write-Host "     Versioning enabled" -ForegroundColor Green
    } else {
        Write-Host "  b. Bucket versioning left disabled (S3BucketVersioning: false)" -ForegroundColor Yellow
    }

    # 11c. Block public access
    Write-Host "  c. Blocking public access..." -ForegroundColor Yellow
    aws s3api put-public-access-block `
        --bucket $S3BucketName `
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" `
        --region $AwsRegion | Out-Null
    Assert-AwsSuccess "Block public access on '$S3BucketName'" -NonFatal
    Write-Host "     Public access blocked" -ForegroundColor Green

    # 11d. Grant ECS task role access to S3 bucket
    Write-Host "  d. Granting ECS task role S3 access..." -ForegroundColor Yellow
    $s3Policy = @"
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::${S3BucketName}",
                "arn:aws:s3:::${S3BucketName}/*"
            ]
        }
    ]
}
"@
    $tempS3Policy = [System.IO.Path]::GetTempFileName()
    $s3Policy | Set-Content $tempS3Policy
    aws iam put-role-policy `
        --role-name $TaskRoleName `
        --policy-name "$ProjectName-s3-access" `
        --policy-document "file://$tempS3Policy"
    Assert-AwsSuccess "Attach S3 policy to task role '$TaskRoleName'"
    Remove-Item $tempS3Policy
    Write-Host "     S3 access granted to $TaskRoleName" -ForegroundColor Green

    Write-Host ""
    Write-Host "  S3 setup complete! Bucket: $S3BucketName" -ForegroundColor Green
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "11. S3: skipped (use -EnableS3 to create)" -ForegroundColor DarkGray
}

# =============================================================================
# 11b. DynamoDB Setup (optional — requires -EnableDynamoDb)
# =============================================================================
if ($EnableDynamoDb) {
    Write-Host ""
    Write-Host "11b. Setting up DynamoDB tables..." -ForegroundColor Yellow
    if (-not $DynamoDbTables -or $DynamoDbTables.Count -eq 0) {
        Write-Host "  WARNING: EnableDynamoDb set but DynamoDbTables is empty — nothing to create." -ForegroundColor Yellow
    }
    $createdNames = @()
    foreach ($t in $DynamoDbTables) {
        $name    = $t.Name
        $pkName  = $t.PartitionKey.Name
        $pkType  = if ($t.PartitionKey.Type) { $t.PartitionKey.Type } else { "S" }
        $billing = if ($t.BillingMode) { $t.BillingMode } else { "PAY_PER_REQUEST" }
        $createdNames += $name
        Write-Host "  Table: $name (PK $pkName)" -ForegroundColor Yellow

        $exists = aws dynamodb describe-table --table-name $name --region $AwsRegion 2>$null
        if ($LASTEXITCODE -ne 0) {
            $attrs = @("AttributeName=$pkName,AttributeType=$pkType")
            $keys  = @("AttributeName=$pkName,KeyType=HASH")
            if ($t.SortKey -and $t.SortKey.Name) {
                $skType = if ($t.SortKey.Type) { $t.SortKey.Type } else { "S" }
                $attrs += "AttributeName=$($t.SortKey.Name),AttributeType=$skType"
                $keys  += "AttributeName=$($t.SortKey.Name),KeyType=RANGE"
            }
            aws dynamodb create-table `
                --table-name $name `
                --attribute-definitions $attrs `
                --key-schema $keys `
                --billing-mode $billing `
                --region $AwsRegion | Out-Null
            Assert-AwsSuccess "Create DynamoDB table '$name'"
            Write-Host "     Created: $name" -ForegroundColor Green
        } else {
            Write-Host "     Exists: $name" -ForegroundColor Green
        }
    }

    if ($createdNames.Count -gt 0) {
        Write-Host "  Granting ECS task role DynamoDB access..." -ForegroundColor Yellow
        $ddbPolicy = New-DynamoDbTaskPolicy -AwsRegion $AwsRegion -AwsAccountId $AwsAccountId -TableNames $createdNames
        $tempDdbPolicy = [System.IO.Path]::GetTempFileName()
        $ddbPolicy | Set-Content $tempDdbPolicy
        aws iam put-role-policy `
            --role-name $TaskRoleName `
            --policy-name "$ProjectName-dynamodb-access" `
            --policy-document "file://$tempDdbPolicy"
        Assert-AwsSuccess "Attach DynamoDB policy to task role '$TaskRoleName'"
        Remove-Item $tempDdbPolicy
        Write-Host "     DynamoDB access granted to $TaskRoleName" -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "  DynamoDB setup complete! Tables: $($createdNames -join ', ')" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "11b. DynamoDB: skipped (use -EnableDynamoDb to create)" -ForegroundColor DarkGray
}

# =============================================================================
# 12. Aurora PostgreSQL Setup (optional — requires -EnableAurora)
# =============================================================================
if ($EnableAurora) {
    Write-Host ""
    Write-Host "12. Setting up Aurora PostgreSQL Serverless v2..." -ForegroundColor Yellow

    # Derived resource names
    $AuroraClusterName       = "$ProjectName-cluster"
    $AuroraInstanceName      = "$ProjectName-instance-1"
    $AuroraSubnetGroupName   = "$ProjectName-db-subnet-group"
    $AuroraSecurityGroupName = "$ProjectName-aurora-sg"

    # Apply defaults for Aurora-specific parameters
    if (-not $AuroraDatabaseName)   { $AuroraDatabaseName  = ($ProjectName -replace '-', '_') }
    if (-not $AuroraMasterUsername)  { $AuroraMasterUsername = "postgres" }
    if (-not $AuroraEngineVersion)   { $AuroraEngineVersion  = "15.12" }
    if ($AuroraMinCapacity -le 0)    { $AuroraMinCapacity    = 0.5 }
    if ($AuroraMaxCapacity -le 0)    { $AuroraMaxCapacity    = 2 }
    if (-not $DatabaseUrlScheme)     { $DatabaseUrlScheme    = "postgresql://" }

    # Generate master password if not provided
    $auroraCreatedNow = $false
    if (-not $AuroraMasterPassword) {
        $AuroraMasterPassword = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 30 | ForEach-Object { [char]$_ })
        Write-Host "  Auto-generated master password (will be stored in Secrets Manager)" -ForegroundColor Cyan
    }

    Write-Host "  Cluster:  $AuroraClusterName"
    Write-Host "  Engine:   aurora-postgresql $AuroraEngineVersion"
    Write-Host "  Database: $AuroraDatabaseName"
    Write-Host "  Capacity: $AuroraMinCapacity - $AuroraMaxCapacity ACU"
    Write-Host ""

    # 10a. DB Subnet Group
    Write-Host "  a. Creating DB Subnet Group..." -ForegroundColor Yellow
    $subnetGroupExists = aws rds describe-db-subnet-groups `
        --db-subnet-group-name $AuroraSubnetGroupName `
        --region $AwsRegion 2>$null
    if (-not $subnetGroupExists) {
        aws rds create-db-subnet-group `
            --db-subnet-group-name $AuroraSubnetGroupName `
            --db-subnet-group-description "$ProjectName Aurora PostgreSQL subnet group" `
            --subnet-ids $Subnets `
            --region $AwsRegion | Out-Null
        Assert-AwsSuccess "Create DB subnet group '$AuroraSubnetGroupName'"
        Write-Host "     Created: $AuroraSubnetGroupName" -ForegroundColor Green
    } else {
        Write-Host "     Exists: $AuroraSubnetGroupName" -ForegroundColor Green
    }

    # 10b. Aurora Security Group
    Write-Host "  b. Creating Aurora Security Group..." -ForegroundColor Yellow
    $auroraSgId = aws ec2 describe-security-groups `
        --filters "Name=group-name,Values=$AuroraSecurityGroupName" "Name=vpc-id,Values=$VpcId" `
        --region $AwsRegion `
        --query 'SecurityGroups[0].GroupId' `
        --output text
    if ($auroraSgId -eq "None" -or -not $auroraSgId) {
        $auroraSgId = aws ec2 create-security-group `
            --group-name $AuroraSecurityGroupName `
            --description "Aurora PostgreSQL for $ProjectName" `
            --vpc-id $VpcId `
            --region $AwsRegion `
            --query 'GroupId' `
            --output text
        Assert-AwsSuccess "Create Aurora security group '$AuroraSecurityGroupName'"
        Write-Host "     Created: $auroraSgId" -ForegroundColor Green
    } else {
        Write-Host "     Exists: $auroraSgId" -ForegroundColor Green
    }

    # 10c. Allow inbound PostgreSQL from ECS security group
    Write-Host "  c. Configuring security group rules..." -ForegroundColor Yellow
    $existingPgRule = aws ec2 describe-security-group-rules `
        --filters "Name=group-id,Values=$auroraSgId" `
        --region $AwsRegion `
        --query "SecurityGroupRules[?FromPort==``5432`` && ToPort==``5432`` && ReferencedGroupInfo.GroupId=='$ecsSgId']" `
        --output json | ConvertFrom-Json

    if ($existingPgRule.Count -eq 0) {
        aws ec2 authorize-security-group-ingress `
            --group-id $auroraSgId `
            --protocol tcp `
            --port 5432 `
            --source-group $ecsSgId `
            --region $AwsRegion
        Assert-AwsSuccess "Add PostgreSQL ingress rule (port 5432 from ECS SG $ecsSgId)"
        Write-Host "     Added: port 5432 from ECS security group ($ecsSgId)" -ForegroundColor Green
    } else {
        Write-Host "     Rule exists: port 5432 from ECS security group" -ForegroundColor Green
    }

    # 10d. Create Aurora PostgreSQL cluster
    Write-Host "  d. Creating Aurora PostgreSQL cluster..." -ForegroundColor Yellow
    $auroraStatus = aws rds describe-db-clusters `
        --db-cluster-identifier $AuroraClusterName `
        --region $AwsRegion `
        --query 'DBClusters[0].Status' `
        --output text 2>$null

    if (-not $auroraStatus -or $auroraStatus -eq "None") {
        aws rds create-db-cluster `
            --db-cluster-identifier $AuroraClusterName `
            --engine aurora-postgresql `
            --engine-version $AuroraEngineVersion `
            --serverless-v2-scaling-configuration "MinCapacity=$AuroraMinCapacity,MaxCapacity=$AuroraMaxCapacity" `
            --database-name $AuroraDatabaseName `
            --master-username $AuroraMasterUsername `
            --master-user-password $AuroraMasterPassword `
            --db-subnet-group-name $AuroraSubnetGroupName `
            --vpc-security-group-ids $auroraSgId `
            --storage-encrypted `
            --region $AwsRegion | Out-Null
        Assert-AwsSuccess "Create Aurora PostgreSQL cluster '$AuroraClusterName'"
        $auroraCreatedNow = $true
        Write-Host "     Cluster created: $AuroraClusterName" -ForegroundColor Green
    } else {
        Write-Host "     Cluster exists: $AuroraClusterName (status: $auroraStatus)" -ForegroundColor Green
    }

    # 10e. Create Serverless v2 writer instance
    Write-Host "  e. Creating Serverless v2 writer instance..." -ForegroundColor Yellow
    $instanceStatus = aws rds describe-db-instances `
        --db-instance-identifier $AuroraInstanceName `
        --region $AwsRegion `
        --query 'DBInstances[0].DBInstanceStatus' `
        --output text 2>$null

    if (-not $instanceStatus -or $instanceStatus -eq "None") {
        aws rds create-db-instance `
            --db-instance-identifier $AuroraInstanceName `
            --db-cluster-identifier $AuroraClusterName `
            --db-instance-class "db.serverless" `
            --engine aurora-postgresql `
            --region $AwsRegion | Out-Null
        Assert-AwsSuccess "Create Aurora Serverless v2 instance '$AuroraInstanceName'"
        Write-Host "     Instance created: $AuroraInstanceName" -ForegroundColor Green
    } else {
        Write-Host "     Instance exists: $AuroraInstanceName (status: $instanceStatus)" -ForegroundColor Green
    }

    # 10f. Wait for cluster availability
    Write-Host "  f. Waiting for Aurora cluster to become available (this may take several minutes)..." -ForegroundColor Yellow
    aws rds wait db-cluster-available `
        --db-cluster-identifier $AuroraClusterName `
        --region $AwsRegion
    Assert-AwsSuccess "Wait for Aurora cluster '$AuroraClusterName' to become available"
    Write-Host "     Aurora cluster is available" -ForegroundColor Green

    # 10g. Retrieve writer endpoint
    $AuroraEndpoint = aws rds describe-db-clusters `
        --db-cluster-identifier $AuroraClusterName `
        --region $AwsRegion `
        --query 'DBClusters[0].Endpoint' `
        --output text
    Assert-AwsSuccess "Retrieve Aurora writer endpoint"
    Write-Host "     Writer endpoint: $AuroraEndpoint" -ForegroundColor Green

    # 10h. Create/update database secret in Secrets Manager
    Write-Host "  h. Creating database secret in Secrets Manager..." -ForegroundColor Yellow
    $dbSecretName = "$SecretsPrefix/database"
    $existingDbSecret = aws secretsmanager describe-secret `
        --secret-id $dbSecretName `
        --region $AwsRegion `
        --query 'ARN' --output text 2>$null

    if ($auroraCreatedNow) {
        # Cluster was just created — we know the password, store the DATABASE_URL
        $encodedPassword = [System.Uri]::EscapeDataString($AuroraMasterPassword)
        $dbUrl = "${DatabaseUrlScheme}${AuroraMasterUsername}:${encodedPassword}@${AuroraEndpoint}:5432/${AuroraDatabaseName}"

        if ($existingDbSecret -and $existingDbSecret -ne 'None') {
            aws secretsmanager put-secret-value `
                --secret-id $dbSecretName `
                --secret-string $dbUrl `
                --region $AwsRegion | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "     Updated secret: $dbSecretName" -ForegroundColor Green
            } else {
                Write-Host "     WARNING: Failed to update secret $dbSecretName" -ForegroundColor Yellow
            }
        } else {
            aws secretsmanager create-secret `
                --name $dbSecretName `
                --secret-string $dbUrl `
                --region $AwsRegion | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "     Created secret: $dbSecretName" -ForegroundColor Green
            } else {
                Write-Host "     WARNING: Failed to create secret $dbSecretName" -ForegroundColor Yellow
            }
        }
    } else {
        # Cluster already existed — password is unknown
        if ($existingDbSecret -and $existingDbSecret -ne 'None') {
            Write-Host "     Secret exists: $dbSecretName (not modified — cluster pre-existed)" -ForegroundColor Green
        } else {
            Write-Host "     WARNING: Aurora cluster exists but no database secret at $dbSecretName" -ForegroundColor Yellow
            Write-Host "     Create it manually:" -ForegroundColor Yellow
            Write-Host "       aws secretsmanager create-secret --name `"$dbSecretName`" --secret-string `"<DATABASE_URL>`" --region $AwsRegion" -ForegroundColor White
        }
    }

    Write-Host ""
    Write-Host "  Aurora PostgreSQL setup complete!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  NOTE: Enable the pgvector extension by running this SQL:" -ForegroundColor Yellow
    Write-Host "    CREATE EXTENSION IF NOT EXISTS vector;" -ForegroundColor White
    Write-Host "  Or ensure your database migrations include this command." -ForegroundColor Yellow
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "12. Aurora PostgreSQL: skipped (use -EnableAurora to create)" -ForegroundColor DarkGray
}

# =============================================================================
# FINAL VALIDATION: Verify all critical resources exist and are properly linked
# =============================================================================
Write-Host ""
Write-Host "13. Running final validation..." -ForegroundColor Yellow
$validationFailed = $false

# Verify ECR
$vEcr = aws ecr describe-repositories --repository-names $EcrRepoName --region $AwsRegion --query 'repositories[0].repositoryUri' --output text 2>$null
if (-not $vEcr -or $vEcr -eq "None") { Write-Host "  FAIL: ECR repository '$EcrRepoName' not found" -ForegroundColor Red; $validationFailed = $true }
else { Write-Host "  OK: ECR repository: $vEcr" -ForegroundColor Green }

# Verify ECS Cluster
$vCluster = aws ecs describe-clusters --clusters $ClusterName --region $AwsRegion --query 'clusters[0].status' --output text 2>$null
if ($vCluster -ne "ACTIVE") { Write-Host "  FAIL: ECS cluster '$ClusterName' not active (status: $vCluster)" -ForegroundColor Red; $validationFailed = $true }
else { Write-Host "  OK: ECS cluster '$ClusterName' is ACTIVE" -ForegroundColor Green }

# Verify ALB
$vAlbState = aws elbv2 describe-load-balancers --load-balancer-arns $albArn --region $AwsRegion --query 'LoadBalancers[0].State.Code' --output text 2>$null
if ($vAlbState -ne "active") { Write-Host "  WARN: ALB state is '$vAlbState' (may still be provisioning)" -ForegroundColor Yellow }
else { Write-Host "  OK: ALB '$AlbName' is active" -ForegroundColor Green }

# Verify Target Group linked to ALB
$vTgAlbs = aws elbv2 describe-target-groups --target-group-arns $tgArn --region $AwsRegion --query 'TargetGroups[0].LoadBalancerArns' --output json 2>$null
if (-not $vTgAlbs -or $vTgAlbs -eq "[]" -or $vTgAlbs -eq "None") {
    Write-Host "  FAIL: Target group '$TargetGroupName' is NOT linked to any ALB!" -ForegroundColor Red
    Write-Host "        This means no listener is forwarding traffic to the target group." -ForegroundColor Red
    Write-Host "        ECS service creation will fail." -ForegroundColor Red
    $validationFailed = $true
}
else { Write-Host "  OK: Target group linked to ALB" -ForegroundColor Green }

# Verify Listeners
$vListenerCount = aws elbv2 describe-listeners --load-balancer-arn $albArn --region $AwsRegion --query 'length(Listeners)' --output text 2>$null
if (-not $vListenerCount -or $vListenerCount -eq "0") {
    Write-Host "  FAIL: ALB has 0 listeners!" -ForegroundColor Red
    $validationFailed = $true
}
else { Write-Host "  OK: ALB has $vListenerCount listener(s)" -ForegroundColor Green }

# Verify IAM Roles
$vExecRole = aws iam get-role --role-name $ExecutionRoleName --query 'Role.Arn' --output text 2>$null
if (-not $vExecRole -or $vExecRole -eq "None") { Write-Host "  FAIL: Execution role '$ExecutionRoleName' not found" -ForegroundColor Red; $validationFailed = $true }
else { Write-Host "  OK: Execution role exists" -ForegroundColor Green }

$vTaskRole = aws iam get-role --role-name $TaskRoleName --query 'Role.Arn' --output text 2>$null
if (-not $vTaskRole -or $vTaskRole -eq "None") { Write-Host "  FAIL: Task role '$TaskRoleName' not found" -ForegroundColor Red; $validationFailed = $true }
else { Write-Host "  OK: Task role exists" -ForegroundColor Green }

# Validate EFS (when enabled)
if ($EnableEfs) {
    $vEfsState = aws efs describe-file-systems `
        --file-system-id $efsId `
        --region $AwsRegion `
        --query 'FileSystems[0].LifeCycleState' `
        --output text 2>$null
    if ($vEfsState -ne "available") {
        Write-Host "  WARN: EFS '$efsId' state: $vEfsState" -ForegroundColor Yellow
    } else {
        Write-Host "  OK: EFS '$efsId' is available" -ForegroundColor Green
    }
}

# Validate S3 (when enabled)
if ($EnableS3) {
    $vBucket = aws s3api head-bucket --bucket $S3BucketName --region $AwsRegion 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAIL: S3 bucket '$S3BucketName' not accessible" -ForegroundColor Red
        $validationFailed = $true
    } else {
        Write-Host "  OK: S3 bucket '$S3BucketName' is accessible" -ForegroundColor Green
    }
}

# Validate DynamoDB tables (when enabled)
if ($EnableDynamoDb -and $DynamoDbTables) {
    foreach ($t in $DynamoDbTables) {
        $v = aws dynamodb describe-table --table-name $t.Name --region $AwsRegion 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  FAIL: DynamoDB table '$($t.Name)' not found" -ForegroundColor Red; $validationFailed = $true
        } else {
            Write-Host "  OK: DynamoDB table '$($t.Name)' exists" -ForegroundColor Green
        }
    }
}

# Validate Aurora resources (when enabled)
if ($EnableAurora) {
    $vAuroraStatus = aws rds describe-db-clusters `
        --db-cluster-identifier $AuroraClusterName `
        --region $AwsRegion `
        --query 'DBClusters[0].Status' `
        --output text 2>$null
    if ($vAuroraStatus -ne "available") {
        Write-Host "  WARN: Aurora cluster '$AuroraClusterName' status: $vAuroraStatus" -ForegroundColor Yellow
    } else {
        Write-Host "  OK: Aurora cluster '$AuroraClusterName' is available" -ForegroundColor Green
    }
}
if ($EnableNlb) {
    $vNlbState = aws elbv2 describe-load-balancers `
        --load-balancer-arns $nlbArn `
        --region $AwsRegion `
        --query 'LoadBalancers[0].State.Code' `
        --output text 2>$null
    if ($vNlbState -ne "active") {
        Write-Host "  FAIL: NLB state is '$vNlbState'" -ForegroundColor Red
        $validationFailed = $true
    } else {
        Write-Host "  OK: NLB '$NlbName' is active" -ForegroundColor Green
    }
}

if ($validationFailed) {
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Red
    Write-Host "  INFRASTRUCTURE VALIDATION FAILED" -ForegroundColor Red
    Write-Host "  One or more resources are missing or" -ForegroundColor Red
    Write-Host "  misconfigured. Do NOT proceed with" -ForegroundColor Red
    Write-Host "  deployment until issues are resolved." -ForegroundColor Red
    Write-Host "==========================================" -ForegroundColor Red
    Write-Host ""
    throw"Infrastructure validation failed. See details above."
}

if ($script:stepErrors.Count -gt 0) {
    Write-Host ""
    Write-Host "Non-fatal warnings encountered:" -ForegroundColor Yellow
    foreach ($warn in $script:stepErrors) {
        Write-Host "  - $warn" -ForegroundColor Yellow
    }
}

# Step 14: Seed Secrets Manager from .env file
Write-Host "14. Seeding Secrets Manager from .env file..." -ForegroundColor Yellow

# Auto-detect env file if not provided
if (-not $EnvFile) {
    $candidates = @(
        (Join-Path $ProjectRoot ".env.local"),
        (Join-Path $ProjectRoot ".env")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            $EnvFile = $candidate
            break
        }
    }
}

if (-not $EnvFile -or -not (Test-Path $EnvFile)) {
    Write-Host "  No .env / .env.local file found — skipping secret seeding." -ForegroundColor Yellow
    Write-Host "  Create secrets manually or re-run with -EnvFile <path>" -ForegroundColor Yellow
} else {
    Write-Host "  Reading from: $EnvFile" -ForegroundColor Cyan

    # Parse key=value lines; strip surrounding quotes from values
    $envVars = @{}
    Get-Content $EnvFile | ForEach-Object {
        if ($_ -match '^\s*([^#=\s][^=]*)=(.*)$') {
            $key   = $Matches[1].Trim()
            $value = $Matches[2].Trim().Trim("'").Trim('"')
            $envVars[$key] = $value
        }
    }

    $apiKey  = $envVars['AZURE_OPENAI_API_KEY']
    $endpoint = $envVars['AZURE_OPENAI_ENDPOINT']
    $model   = $envVars['AZURE_OPENAI_MODEL']

    if (-not $apiKey -or -not $endpoint -or -not $model) {
        Write-Host "  WARNING: One or more required variables missing in $EnvFile" -ForegroundColor Yellow
        Write-Host "  Required: AZURE_OPENAI_API_KEY, AZURE_OPENAI_ENDPOINT, AZURE_OPENAI_MODEL" -ForegroundColor Yellow
        Write-Host "  Skipping secret seeding." -ForegroundColor Yellow
    } else {
        $secretName = "$SecretsPrefix/azure-openai"
        $secretValue = "{`"api_key`":`"$apiKey`",`"endpoint`":`"$endpoint`",`"model`":`"$model`"}"

        # Create or update the secret
        $existingSecret = aws secretsmanager describe-secret `
            --secret-id $secretName `
            --region $AwsRegion `
            --query 'ARN' --output text 2>$null

        if ($existingSecret -and $existingSecret -ne 'None') {
            aws secretsmanager put-secret-value `
                --secret-id $secretName `
                --secret-string $secretValue `
                --region $AwsRegion | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Updated secret: $secretName" -ForegroundColor Green
            } else {
                Write-Host "  WARNING: Failed to update secret $secretName" -ForegroundColor Yellow
            }
        } else {
            aws secretsmanager create-secret `
                --name $secretName `
                --secret-string $secretValue `
                --region $AwsRegion | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Created secret: $secretName" -ForegroundColor Green
            } else {
                Write-Host "  WARNING: Failed to create secret $secretName" -ForegroundColor Yellow
            }
        }
    }
}

# Output summary
Write-Host ""
Write-Host "=== Infrastructure Setup Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Resources Created:" -ForegroundColor Cyan
Write-Host "  Project Name:       $ProjectName"
Write-Host "  ECR Repository:     $AwsAccountId.dkr.ecr.$AwsRegion.amazonaws.com/$EcrRepoName"
Write-Host "  ECS Cluster:        $ClusterName"
Write-Host "  ALB DNS:            $albDns"
Write-Host "  Target Group:       $tgArn"
Write-Host "  ALB Security Group: $albSgId"
Write-Host "  ECS Security Group: $ecsSgId"
Write-Host "  Container Port:     $ContainerPort"
Write-Host "  Health Check:       $HealthCheckPath"
if ($EnableNlb) {
    Write-Host "  NLB DNS:            $nlbDns"
    Write-Host "  NLB Target Group:   $nlbTgArn"
    Write-Host "  DNS Target:         $nlbDns (NLB)"
} else {
    Write-Host "  DNS Target:         $albDns (ALB)"
}
if ($EnableEfs) {
    Write-Host "  EFS Filesystem:     $efsId"
    Write-Host "  EFS Security Group: $efsSgId"
}
if ($EnableS3) {
    Write-Host "  S3 Bucket:          $S3BucketName"
}
if ($EnableDynamoDb -and $DynamoDbTables) {
    Write-Host "  DynamoDB Tables:    $(($DynamoDbTables | ForEach-Object { $_.Name }) -join ', ')"
}
if ($EnableAurora) {
    Write-Host "  Aurora Cluster:     $AuroraClusterName"
    Write-Host "  Aurora Endpoint:    $AuroraEndpoint"
    Write-Host "  Aurora Database:    $AuroraDatabaseName"
    Write-Host "  Aurora SG:          $auroraSgId"
}
Write-Host ""
if ($CustomDomainName) {
    $displayProtocol = if ($CertificateArn) { "https" } else { "http" }
    Write-Host "  Custom Domain:      $CustomDomainName"
    Write-Host "  URL:                ${displayProtocol}://${CustomDomainName}"
}
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "  1. If secrets were NOT seeded automatically, create them manually:"
Write-Host "     - $SecretsPrefix/azure-openai (api_key, endpoint, model) [if using Azure OpenAI]"
Write-Host "     - $SecretsPrefix/database (DATABASE_URL) [if using a database]"
Write-Host "     - $SecretsPrefix/entra-id (client_id, tenant_id) [if using Entra ID auth]"
Write-Host "     Or re-run with a .env.local file present, or: -EnvFile <path>"
Write-Host ""
Write-Host "  2. [If using a database] Create database (Aurora PostgreSQL, RDS, etc.) and configure connection"
Write-Host ""
if (-not $Route53HostedZoneId -and -not $CustomDomainName) {
    $dnsSuggestionTarget = if ($EnableNlb -and $nlbDns) { $nlbDns } else { $albDns }
    $dnsSuggestionLabel = if ($EnableNlb) { "NLB" } else { "ALB" }
    Write-Host "  3. Create DNS record pointing to ${dnsSuggestionLabel}:"
    Write-Host "     $ProjectName.yourdomain.com -> $dnsSuggestionTarget"
    Write-Host "     Or run: .\CCM\setup-route53-zone.ps1 -ParentDomain `"apps.example.com`""
    Write-Host ""
}
if (-not $CertificateArn) {
    Write-Host "  3. Upgrade to HTTPS (after DNS is configured):"
    Write-Host "     .\CCM\upgrade-alb-to-https.ps1 -CertificateArn <WILDCARD_CERT_ARN>"
    Write-Host ""
}
Write-Host "  4. Deploy the application:"
Write-Host "     .\CCM\deploy-ecs.ps1"
Write-Host ""

# Save configuration for later use
$config = @{
    ProjectName      = $ProjectName
    AwsRegion        = $AwsRegion
    AwsAccountId     = $AwsAccountId
    VpcId            = $VpcId
    Subnets          = $Subnets
    AlbArn           = $albArn
    AlbDns           = $albDns
    TargetGroupArn   = $tgArn
    AlbSecurityGroup = $albSgId
    EcsSecurityGroup = $ecsSgId
    ContainerPort    = $ContainerPort
    HealthCheckPath  = $HealthCheckPath
    SecretsPrefix    = $SecretsPrefix
}

if ($CertificateArn) {
    $config['CertificateArn'] = $CertificateArn
    $config['ListenerProtocol'] = "HTTPS"
} else {
    $config['ListenerProtocol'] = "HTTP"
}

if ($CustomDomainName) {
    $config['CustomDomainName'] = $CustomDomainName
}
if ($Route53HostedZoneId) {
    $config['Route53HostedZoneId'] = $Route53HostedZoneId
}
if ($ParentDomain) {
    $config['ParentDomain'] = $ParentDomain
}

if ($EnableEfs) {
    $config['EfsFileSystemId']    = $efsId
    $config['EfsSecurityGroup']   = $efsSgId
}
if ($EnableS3) {
    $config['S3BucketName'] = $S3BucketName
}
if ($AlbAccessLogsBucket) {
    $config['AlbAccessLogsBucket'] = $AlbAccessLogsBucket
    $config['AlbAccessLogsPrefix'] = $AlbAccessLogsPrefix
}
if ($EnableDynamoDb -and $DynamoDbTables) {
    $config['DynamoDbTables'] = @($DynamoDbTables | ForEach-Object { $_.Name })
}
if ($EnableAurora) {
    $config['AuroraClusterIdentifier'] = $AuroraClusterName
    $config['AuroraEndpoint']          = $AuroraEndpoint
    $config['AuroraSecurityGroup']     = $auroraSgId
    $config['AuroraDatabaseName']      = $AuroraDatabaseName
    $config['AuroraMasterUsername']     = $AuroraMasterUsername
}
if ($VpcEndpointSecurityGroupId) {
    $config['VpcEndpointSecurityGroupId'] = $VpcEndpointSecurityGroupId
}
if ($EnableNlb) {
    $config['NlbArn']            = $nlbArn
    $config['NlbDns']            = $nlbDns
    $config['NlbTargetGroupArn'] = $nlbTgArn
    if ($nlbHttpTgArn) {
        $config['NlbHttpTargetGroupArn'] = $nlbHttpTgArn
    }
    if ($NlbElasticIpAllocationIds) {
        $config['NlbElasticIpAllocationIds'] = $NlbElasticIpAllocationIds
    }
    if ($exposedTargetGroups -and $exposedTargetGroups.Count -gt 0) {
        # Persist as plain hashtables so deploy-ecs.ps1 (and humans) can read them
        $config['ExposedTargetGroups'] = @(
            $exposedTargetGroups | ForEach-Object {
                @{
                    Port           = $_.Port
                    ContainerName  = $_.ContainerName
                    ContainerPort  = $_.ContainerPort
                    Protocol       = $_.Protocol
                    TargetGroupArn = $_.TargetGroupArn
                }
            }
        )
    }
}

$configPath = Join-Path $ecsDeployDir "infrastructure-config.json"

# Merge with any existing file so we don't clobber keys written by sibling
# scripts (e.g. EfsAccessPoints written by a project-specific setup helper
# under the consumer's own deploy/ directory). Keys produced by THIS script always win;
# keys we don't manage are passed through verbatim.
if (Test-Path $configPath) {
    $existingJson = Get-Content $configPath -Raw
    if ($existingJson -and $existingJson.Trim()) {
        $existing = $existingJson | ConvertFrom-Json
        foreach ($prop in $existing.PSObject.Properties) {
            if (-not $config.ContainsKey($prop.Name)) {
                $config[$prop.Name] = $prop.Value
            }
        }
    }
}

$config | ConvertTo-Json -Depth 10 | Set-Content $configPath
Write-Host "Configuration saved to $configPath" -ForegroundColor Cyan

Stop-CcmLogging $ccmLog
