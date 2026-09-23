#! /usr/bin/env pwsh

<#
.SYNOPSIS
    Removes an ECS preview environment.

.DESCRIPTION
    Idempotently removes preview listener rules, ECS service, target group, and
    optional Route 53 record created by deploy-ecs-preview.ps1.
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [string]$PullRequestId,

    [Parameter(Mandatory = $false)]
    [string]$PreviewId,

    # Must match the value used at deploy time: New-CcmEcsPreviewIdentity seeds the
    # hash-truncated target group name with it, so recomputing the identity with a
    # different branch would look up (and miss) the wrong target group name.
    [Parameter(Mandatory = $false)]
    [string]$SourceBranch
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

Import-Module (Join-Path $ScriptDir "CCM.psd1") -Force

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

function ConvertTo-CcmTemplateValue {
    param([string]$Value, [hashtable]$Tokens)
    $result = $Value
    foreach ($key in $Tokens.Keys) {
        $result = $result.Replace("{$key}", "$($Tokens[$key])")
    }
    return $result
}

function Get-CcmTargetGroupByName {
    param([string]$Name, [string]$Region)
    $output = aws elbv2 describe-target-groups --names $Name --region $Region --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) {
        return $null
    }
    return ((($output -join "`n") | ConvertFrom-Json).TargetGroups | Select-Object -First 1)
}

function Get-CcmListener {
    param([string]$LoadBalancerArn, [string]$PreferredProtocol, [string]$Region)
    if (-not $LoadBalancerArn) {
        return $null
    }
    $listenersOutput = aws elbv2 describe-listeners --load-balancer-arn $LoadBalancerArn --region $Region --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $listenersOutput) {
        return $null
    }
    $listeners = (($listenersOutput -join "`n") | ConvertFrom-Json).Listeners
    $listener = $listeners | Where-Object { $_.Protocol -eq $PreferredProtocol } | Select-Object -First 1
    if (-not $listener) { $listener = $listeners | Where-Object { $_.Protocol -eq "HTTPS" } | Select-Object -First 1 }
    if (-not $listener) { $listener = $listeners | Where-Object { $_.Protocol -eq "HTTP" } | Select-Object -First 1 }
    return $listener
}

function Get-CcmPreviewRule {
    param(
        [string]$ListenerArn,
        [string]$RoutingMode,
        [string]$PathPrefix,
        [string]$HostName,
        [string]$Region
    )

    if (-not $ListenerArn) {
        return $null
    }
    $rulesOutput = aws elbv2 describe-rules --listener-arn $ListenerArn --region $Region --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $rulesOutput) {
        return $null
    }
    $rules = (($rulesOutput -join "`n") | ConvertFrom-Json).Rules
    foreach ($rule in $rules) {
        if ($rule.IsDefault) { continue }
        foreach ($condition in $rule.Conditions) {
            if ($RoutingMode -eq "path" -and $condition.Field -eq "path-pattern") {
                $values = @($condition.PathPatternConfig.Values)
                if ($values -contains $PathPrefix -or $values -contains "$PathPrefix/*") {
                    return $rule
                }
            }
            if ($RoutingMode -eq "host" -and $condition.Field -eq "host-header") {
                $values = @($condition.HostHeaderConfig.Values)
                if ($values -contains $HostName) {
                    return $rule
                }
            }
        }
    }
    return $null
}

function Wait-CcmServiceDrained {
    param([string]$ClusterName, [string]$ServiceName, [string]$Region)

    for ($i = 1; $i -le 40; $i++) {
        $output = aws ecs describe-services --cluster $ClusterName --services $ServiceName --region $Region --output json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $output) {
            return
        }
        $service = ((($output -join "`n") | ConvertFrom-Json).services | Select-Object -First 1)
        if (-not $service -or $service.status -eq "INACTIVE") {
            return
        }
        if ([int]$service.runningCount -eq 0 -and [int]$service.pendingCount -eq 0) {
            return
        }
        Start-Sleep -Seconds 10
    }
}

function Wait-CcmServiceInactive {
    param([string]$ClusterName, [string]$ServiceName, [string]$Region)

    for ($i = 1; $i -le 40; $i++) {
        $output = aws ecs describe-services --cluster $ClusterName --services $ServiceName --region $Region --output json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $output) {
            return
        }
        $service = ((($output -join "`n") | ConvertFrom-Json).services | Select-Object -First 1)
        if (-not $service -or $service.status -eq "INACTIVE") {
            return
        }
        Start-Sleep -Seconds 10
    }
}

function Remove-CcmRoute53Cname {
    param([string]$HostedZoneId, [string]$RecordName, [string]$RecordValue)
    if (-not $HostedZoneId -or -not $RecordName -or -not $RecordValue) {
        return
    }

    $record = aws route53 list-resource-record-sets `
        --hosted-zone-id $HostedZoneId `
        --start-record-name $RecordName `
        --start-record-type CNAME `
        --max-items 1 `
        --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $record) {
        return
    }
    $recordSet = ((($record -join "`n") | ConvertFrom-Json).ResourceRecordSets | Select-Object -First 1)
    if (-not $recordSet -or $recordSet.Type -ne "CNAME") {
        return
    }
    if ($recordSet.Name.TrimEnd('.') -ne $RecordName.TrimEnd('.')) {
        return
    }
    $values = @($recordSet.ResourceRecords | ForEach-Object { $_.Value.TrimEnd('.') })
    if ($values -notcontains $RecordValue.TrimEnd('.')) {
        return
    }

    $change = @{
        Changes = @(
            @{
                Action = "DELETE"
                ResourceRecordSet = $recordSet
            }
        )
    }
    $changeFile = [System.IO.Path]::GetTempFileName()
    $change | ConvertTo-Json -Depth 20 | Set-Content -Path $changeFile -Encoding UTF8
    try {
        aws route53 change-resource-record-sets `
            --hosted-zone-id $HostedZoneId `
            --change-batch "file://$changeFile" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to delete Route 53 record $RecordName"
        }
    }
    finally {
        Remove-Item $changeFile -ErrorAction SilentlyContinue
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

if (-not $PullRequestId) {
    $PullRequestId = $env:SYSTEM_PULLREQUEST_PULLREQUESTID
}
if (-not $PullRequestId) {
    $PullRequestId = $env:SYSTEM_PULLREQUEST_PULLREQUESTNUMBER
}
if (-not $PullRequestId -and $PreviewId) {
    $PullRequestId = $PreviewId
}
if (-not $PullRequestId) {
    throw "PullRequestId or PreviewId is required."
}

# Mirror deploy-ecs-preview.ps1's fallback chain so that, in the same pipeline
# context, both scripts derive the same identity. Callers that know the deploy-time
# branch (e.g. cleanup-ecs-previews.ps1 reading the SourceBranch tag) pass it
# explicitly — even as an empty string — which skips the environment fallback.
if (-not $PSBoundParameters.ContainsKey('SourceBranch')) {
    if (-not $SourceBranch) {
        $SourceBranch = $env:SYSTEM_PULLREQUEST_SOURCEBRANCH
    }
    if (-not $SourceBranch) {
        $SourceBranch = $env:BUILD_SOURCEBRANCH
    }
}

$previewConfig = Get-CcmPropertyValue $config "PreviewEnvironments" ([pscustomobject]@{})
$identity = New-CcmEcsPreviewIdentity `
    -ProjectName $projectName `
    -PullRequestId $PullRequestId `
    -SourceBranch "$SourceBranch" `
    -PreviewId $PreviewId `
    -PathPrefixTemplate (Get-CcmPropertyValue $previewConfig "PathPrefixTemplate" "/_pr/{id}")

$awsRegion = Get-CcmPropertyValue $config "AwsRegion" "eu-central-1"
$clusterName = "$projectName-cluster"
$deployDir = Get-CcmPropertyValue $config "DeployDir" (Join-Path $ProjectRoot "deploy")
if (-not [System.IO.Path]::IsPathRooted($deployDir)) {
    $deployDir = Join-Path $ProjectRoot $deployDir
}
$infraPath = Join-Path $deployDir "ecs\infrastructure-config.json"
$infra = $null
if (Test-Path $infraPath) {
    $infra = Get-Content $infraPath -Raw | ConvertFrom-Json
}

$routingMode = (Get-CcmPropertyValue $previewConfig "RoutingMode" "path").ToLowerInvariant()
$hostName = $null
if ($routingMode -eq "host") {
    $hostTemplate = Get-CcmPropertyValue $previewConfig "HostTemplate" $null
    if ($hostTemplate) {
        $hostName = ConvertTo-CcmTemplateValue $hostTemplate @{ project = $projectName; id = $identity.PreviewId }
    }
}

Write-Host "Removing ECS preview '$($identity.PreviewId)' for PR $PullRequestId" -ForegroundColor Cyan

$listener = $null
if ($infra -and $infra.AlbArn) {
    $listener = Get-CcmListener -LoadBalancerArn $infra.AlbArn -PreferredProtocol $infra.ListenerProtocol -Region $awsRegion
}
$rule = $null
if ($listener) {
    $rule = Get-CcmPreviewRule `
        -ListenerArn $listener.ListenerArn `
        -RoutingMode $routingMode `
        -PathPrefix $identity.PathPrefix `
        -HostName $hostName `
        -Region $awsRegion
}
if ($rule) {
    Write-Host "Deleting listener rule: $($rule.RuleArn)" -ForegroundColor Yellow
    aws elbv2 delete-rule --rule-arn $rule.RuleArn --region $awsRegion | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to delete listener rule $($rule.RuleArn)"
    }
}

$serviceOutput = aws ecs describe-services `
    --cluster $clusterName `
    --services $identity.ServiceName `
    --region $awsRegion `
    --output json 2>$null
if ($LASTEXITCODE -eq 0 -and $serviceOutput) {
    $service = ((($serviceOutput -join "`n") | ConvertFrom-Json).services | Where-Object { $_.status -ne "INACTIVE" } | Select-Object -First 1)
    if ($service) {
        Write-Host "Scaling service to zero: $($identity.ServiceName)" -ForegroundColor Yellow
        aws ecs update-service `
            --cluster $clusterName `
            --service $identity.ServiceName `
            --desired-count 0 `
            --region $awsRegion | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to scale service '$($identity.ServiceName)' to zero."
        }
        Wait-CcmServiceDrained -ClusterName $clusterName -ServiceName $identity.ServiceName -Region $awsRegion

        Write-Host "Deleting service: $($identity.ServiceName)" -ForegroundColor Yellow
        aws ecs delete-service `
            --cluster $clusterName `
            --service $identity.ServiceName `
            --force `
            --region $awsRegion | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to delete service '$($identity.ServiceName)'."
        }
        Wait-CcmServiceInactive -ClusterName $clusterName -ServiceName $identity.ServiceName -Region $awsRegion
    }
}

$targetGroup = Get-CcmTargetGroupByName -Name $identity.TargetGroupName -Region $awsRegion
if ($targetGroup) {
    Write-Host "Deleting target group: $($targetGroup.TargetGroupArn)" -ForegroundColor Yellow
    $targetGroupDeleted = $false
    for ($i = 1; $i -le 12; $i++) {
        aws elbv2 delete-target-group --target-group-arn $targetGroup.TargetGroupArn --region $awsRegion | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $targetGroupDeleted = $true
            break
        }
        Start-Sleep -Seconds 10
    }
    if (-not $targetGroupDeleted) {
        throw "Failed to delete target group $($targetGroup.TargetGroupArn)"
    }
}

if ($routingMode -eq "host" -and $hostName -and $infra) {
    $zoneId = Get-CcmPropertyValue $config "Route53HostedZoneId" (Get-CcmPropertyValue $infra "Route53HostedZoneId" $null)
    $dnsTarget = Get-CcmPropertyValue $infra "NlbDns" (Get-CcmPropertyValue $infra "AlbDns" $null)
    Remove-CcmRoute53Cname -HostedZoneId $zoneId -RecordName $hostName -RecordValue $dnsTarget
}

Write-Host "Preview removal complete: $($identity.PreviewId)" -ForegroundColor Green
$global:LASTEXITCODE = 0
