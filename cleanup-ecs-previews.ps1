#! /usr/bin/env pwsh

<#
.SYNOPSIS
    Garbage-collects expired ECS preview environments.

.DESCRIPTION
    Discovers CCM-managed preview resources by tags and removes previews whose
    ExpiresAt tag is in the past. When Azure DevOps metadata and a token are
    available, also removes previews whose pull request is no longer active.
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [string]$AzureDevOpsToken,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

function Get-CcmPropertyValue {
    param([object]$Object, [string]$Name, [object]$DefaultValue)
    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) {
        $value = $Object.$Name
        if ($null -ne $value -and "$value" -ne "") {
            return $value
        }
    }
    return $DefaultValue
}

function ConvertFrom-CcmTagList {
    param([object[]]$TagList)

    $tags = @{}
    foreach ($tag in @($TagList)) {
        $tags[$tag.Key] = $tag.Value
    }
    return $tags
}

function Get-CcmActiveAzureDevOpsPullRequests {
    param([string]$Token)

    $collectionUri = $env:SYSTEM_COLLECTIONURI
    $teamProject = $env:SYSTEM_TEAMPROJECT
    $repositoryId = $env:BUILD_REPOSITORY_ID

    if (-not $Token -or -not $collectionUri -or -not $teamProject -or -not $repositoryId) {
        Write-Warning "Azure DevOps PR lookup unavailable; cleanup will use TTL only."
        return $null
    }

    $encodedProject = [System.Uri]::EscapeDataString($teamProject)
    $uri = "$($collectionUri.TrimEnd('/'))/$encodedProject/_apis/git/repositories/$repositoryId/pullrequests?searchCriteria.status=active&api-version=7.1"
    $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Token"))
    try {
        $response = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Basic $basic" } -Method Get
        $active = @{}
        foreach ($pr in @($response.value)) {
            $active["$($pr.pullRequestId)"] = $true
        }
        return $active
    }
    catch {
        Write-Warning "Azure DevOps PR lookup failed; cleanup will use TTL only. $($_.Exception.Message)"
        return $null
    }
}

if (-not $ConfigFile) {
    $ConfigFile = Join-Path $ProjectRoot "ecs-config.json"
}
if (-not (Test-Path $ConfigFile)) {
    throw "Configuration file not found: $ConfigFile"
}

$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
$projectName = Get-CcmPropertyValue $config "ProjectName" $null
if (-not $projectName) {
    throw "ProjectName is required in $ConfigFile"
}
$awsRegion = Get-CcmPropertyValue $config "AwsRegion" "eu-central-1"

if (-not $AzureDevOpsToken) {
    $AzureDevOpsToken = $env:SYSTEM_ACCESSTOKEN
}
$activePullRequests = Get-CcmActiveAzureDevOpsPullRequests -Token $AzureDevOpsToken

Write-Host "Discovering CCM-managed ECS previews for project '$projectName'..." -ForegroundColor Cyan
$resourcesOutput = aws resourcegroupstaggingapi get-resources `
    --tag-filters "Key=ManagedBy,Values=CCM" "Key=Preview,Values=true" "Key=Project,Values=$projectName" `
    --region $awsRegion `
    --output json
if ($LASTEXITCODE -ne 0) {
    throw "Failed to discover tagged preview resources."
}

$resources = (($resourcesOutput -join "`n") | ConvertFrom-Json).ResourceTagMappingList
$previews = @{}
foreach ($resource in @($resources)) {
    $tags = ConvertFrom-CcmTagList $resource.Tags
    $previewId = $tags["PreviewId"]
    if (-not $previewId) {
        continue
    }
    if (-not $previews.ContainsKey($previewId)) {
        $previews[$previewId] = @{
            PreviewId = $previewId
            PullRequestId = $tags["PullRequestId"]
            SourceBranch = $tags["SourceBranch"]
            ExpiresAt = $tags["ExpiresAt"]
            Resources = @()
        }
    }
    $previews[$previewId].Resources += $resource.ResourceARN
    if ($tags["ExpiresAt"]) {
        $previews[$previewId].ExpiresAt = $tags["ExpiresAt"]
    }
    if ($tags["PullRequestId"]) {
        $previews[$previewId].PullRequestId = $tags["PullRequestId"]
    }
    if ($tags["SourceBranch"]) {
        $previews[$previewId].SourceBranch = $tags["SourceBranch"]
    }
}

$now = [DateTimeOffset]::UtcNow
$removeScript = Join-Path $ScriptDir "remove-ecs-preview.ps1"
foreach ($preview in $previews.Values) {
    $expired = $false
    $closed = $false

    if ($preview.ExpiresAt) {
        $expiresAt = [DateTimeOffset]::Parse($preview.ExpiresAt, [System.Globalization.CultureInfo]::InvariantCulture)
        $expired = $expiresAt -le $now
    }
    if ($activePullRequests -ne $null -and $preview.PullRequestId) {
        $closed = -not $activePullRequests.ContainsKey("$($preview.PullRequestId)")
    }

    if (-not $expired -and -not $closed) {
        continue
    }

    $reason = if ($expired) { "expired" } else { "pull request no longer active" }
    Write-Host "Removing preview '$($preview.PreviewId)' ($reason)" -ForegroundColor Yellow
    if ($DryRun) {
        Write-Host "  DryRun: would remove PR $($preview.PullRequestId), resources=$($preview.Resources.Count)"
        continue
    }

    # Pass the deploy-time SourceBranch tag even when empty: the identity's
    # hash-truncated target group name is seeded with it, and an explicit (bound)
    # parameter stops remove-ecs-preview.ps1 from substituting this scheduled
    # run's own branch via its environment fallback.
    & $removeScript `
        -ConfigFile $ConfigFile `
        -PullRequestId $preview.PullRequestId `
        -PreviewId $preview.PreviewId `
        -SourceBranch "$($preview.SourceBranch)"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to remove preview '$($preview.PreviewId)'"
    }
}

Write-Host "Preview cleanup complete." -ForegroundColor Green
