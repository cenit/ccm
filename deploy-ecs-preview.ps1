#! /usr/bin/env pwsh

<#
.SYNOPSIS
    Creates or updates an ECS preview environment for a pull request.

.DESCRIPTION
    Creates a PR-scoped target group and ALB listener rule, then delegates image
    build/deploy work to deploy-ecs.ps1 with a preview service name and target
    group override. Project-specific settings come from ecs-config.json.
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [string]$PullRequestId,

    [Parameter(Mandatory = $false)]
    [string]$SourceBranch,

    [Parameter(Mandatory = $false)]
    [string]$CommitSha,

    [Parameter(Mandatory = $false)]
    [string]$PreviewId,

    [Parameter(Mandatory = $false)]
    [string]$ImageTag,

    [Parameter(Mandatory = $false)]
    [switch]$SkipBuild,

    [Parameter(Mandatory = $false)]
    [switch]$UsePodman,

    [Parameter(Mandatory = $false)]
    [switch]$UseDocker,

    [Parameter(Mandatory = $false)]
    [switch]$UseTarContext,

    [Parameter(Mandatory = $false)]
    [string[]]$BuildArgs,

    [Parameter(Mandatory = $false)]
    [switch]$ForceRecreate
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

Import-Module (Join-Path $ScriptDir "CCM.psd1") -Force

function Get-CcmPropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue
    )

    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) {
        $value = $Object.$Name
        if ($null -ne $value -and "$value" -ne "") {
            return $value
        }
    }
    return $DefaultValue
}

function ConvertTo-CcmTagArguments {
    # AWS CLI tag shorthand casing is service-specific: elbv2 expects
    # "Key=...,Value=..." while ecs tag-resource expects lowercase
    # "key=...,value=..." and rejects the capitalized form. Use
    # -LowerCaseKeys for the ecs calls.
    param(
        [hashtable]$Tags,
        [switch]$LowerCaseKeys
    )

    $keyName = if ($LowerCaseKeys) { "key" } else { "Key" }
    $valueName = if ($LowerCaseKeys) { "value" } else { "Value" }
    $arguments = @()
    foreach ($key in ($Tags.Keys | Sort-Object)) {
        $value = "$($Tags[$key])"
        $arguments += "$keyName=$key,$valueName=$value"
    }
    return $arguments
}

function ConvertTo-CcmTemplateValue {
    param(
        [string]$Value,
        [hashtable]$Tokens
    )

    $result = $Value
    foreach ($key in $Tokens.Keys) {
        $result = $result.Replace("{$key}", "$($Tokens[$key])")
    }
    return $result
}

function Get-CcmTargetGroupByName {
    param(
        [string]$Name,
        [string]$Region
    )

    $output = aws elbv2 describe-target-groups --names $Name --region $Region --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) {
        return $null
    }
    $json = ($output -join "`n") | ConvertFrom-Json
    return $json.TargetGroups | Select-Object -First 1
}

function Write-CcmJsonTempFile {
    param([Parameter(Mandatory)][object]$Value)

    $path = [System.IO.Path]::GetTempFileName()
    ConvertTo-Json -InputObject $Value -Depth 20 | Set-Content -Path $path -Encoding UTF8
    return $path
}

function Get-CcmListener {
    param(
        [string]$LoadBalancerArn,
        [string]$PreferredProtocol,
        [string]$Region
    )

    $listenersOutput = aws elbv2 describe-listeners `
        --load-balancer-arn $LoadBalancerArn `
        --region $Region `
        --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to describe ALB listeners for $LoadBalancerArn"
    }

    $listeners = (($listenersOutput -join "`n") | ConvertFrom-Json).Listeners
    $listener = $listeners | Where-Object { $_.Protocol -eq $PreferredProtocol } | Select-Object -First 1
    if (-not $listener) {
        $listener = $listeners | Where-Object { $_.Protocol -eq "HTTPS" } | Select-Object -First 1
    }
    if (-not $listener) {
        $listener = $listeners | Where-Object { $_.Protocol -eq "HTTP" } | Select-Object -First 1
    }
    if (-not $listener) {
        throw "No HTTP/HTTPS listener found for load balancer $LoadBalancerArn"
    }
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

    $rulesOutput = aws elbv2 describe-rules --listener-arn $ListenerArn --region $Region --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to describe listener rules for $ListenerArn"
    }
    $rules = (($rulesOutput -join "`n") | ConvertFrom-Json).Rules

    foreach ($rule in $rules) {
        if ($rule.IsDefault) {
            continue
        }
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

function Get-CcmNextListenerPriority {
    param(
        [string]$ListenerArn,
        [int]$Base,
        [int]$BandSize,
        [string]$Region
    )

    $rulesOutput = aws elbv2 describe-rules --listener-arn $ListenerArn --region $Region --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to describe listener rules for $ListenerArn"
    }
    $rules = (($rulesOutput -join "`n") | ConvertFrom-Json).Rules
    $used = @{}
    foreach ($rule in $rules) {
        if ($rule.Priority -and $rule.Priority -ne "default") {
            $used[[int]$rule.Priority] = $true
        }
    }

    $last = $Base + $BandSize - 1
    for ($priority = $Base; $priority -le $last; $priority++) {
        if (-not $used.ContainsKey($priority)) {
            return $priority
        }
    }
    throw "No free ALB listener-rule priorities in reserved preview band $Base-$last"
}

function Set-CcmRoute53Cname {
    param(
        [string]$HostedZoneId,
        [string]$RecordName,
        [string]$RecordValue
    )

    if (-not $HostedZoneId -or -not $RecordName -or -not $RecordValue) {
        return
    }

    $change = @{
        Changes = @(
            @{
                Action = "UPSERT"
                ResourceRecordSet = @{
                    Name = $RecordName
                    Type = "CNAME"
                    TTL = 60
                    ResourceRecords = @(@{ Value = $RecordValue })
                }
            }
        )
    }
    $changeFile = Write-CcmJsonTempFile $change
    try {
        aws route53 change-resource-record-sets `
            --hosted-zone-id $HostedZoneId `
            --change-batch "file://$changeFile" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to upsert Route 53 record $RecordName"
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

$previewConfig = Get-CcmPropertyValue $config "PreviewEnvironments" ([pscustomobject]@{})
$previewEnabled = [bool](Get-CcmPropertyValue $previewConfig "Enabled" $false)
if (-not $previewEnabled) {
    throw "PreviewEnvironments.Enabled is false or missing in $ConfigFile"
}

$awsRegion = Get-CcmPropertyValue $config "AwsRegion" "eu-central-1"
$clusterName = "$projectName-cluster"
$containerName = Get-CcmPropertyValue $config "ContainerName" $projectName
$containerPort = [int](Get-CcmPropertyValue $config "ContainerPort" 8000)
$deployDir = Get-CcmPropertyValue $config "DeployDir" (Join-Path $ProjectRoot "deploy")
if (-not [System.IO.Path]::IsPathRooted($deployDir)) {
    $deployDir = Join-Path $ProjectRoot $deployDir
}
$infraPath = Join-Path $deployDir "ecs\infrastructure-config.json"
if (-not (Test-Path $infraPath)) {
    throw "Infrastructure config not found: $infraPath. Run setup-aws-infrastructure.ps1 first."
}
$infra = Get-Content $infraPath -Raw | ConvertFrom-Json

if (-not $PullRequestId) {
    $PullRequestId = $env:SYSTEM_PULLREQUEST_PULLREQUESTID
}
if (-not $PullRequestId) {
    $PullRequestId = $env:SYSTEM_PULLREQUEST_PULLREQUESTNUMBER
}
if (-not $PullRequestId -and $env:BUILD_SOURCEBRANCH -match 'refs/pull/(\d+)/') {
    $PullRequestId = $matches[1]
}
if (-not $PullRequestId) {
    throw "PullRequestId was not provided and could not be derived from Azure DevOps environment variables."
}

if (-not $SourceBranch) {
    $SourceBranch = $env:SYSTEM_PULLREQUEST_SOURCEBRANCH
}
if (-not $SourceBranch) {
    $SourceBranch = $env:BUILD_SOURCEBRANCH
}
if (-not $CommitSha) {
    $CommitSha = $env:BUILD_SOURCEVERSION
}

$pathPrefixTemplate = Get-CcmPropertyValue $previewConfig "PathPrefixTemplate" "/_pr/{id}"
$identity = New-CcmEcsPreviewIdentity `
    -ProjectName $projectName `
    -PullRequestId $PullRequestId `
    -SourceBranch "$SourceBranch" `
    -PreviewId $PreviewId `
    -PathPrefixTemplate $pathPrefixTemplate

if (-not $ImageTag) {
    if ($CommitSha -and $CommitSha.Length -ge 7) {
        $ImageTag = "pr-$($identity.PreviewId)-$($CommitSha.Substring(0, 7))"
    } else {
        $ImageTag = "pr-$($identity.PreviewId)"
    }
}

$routingMode = (Get-CcmPropertyValue $previewConfig "RoutingMode" "path").ToLowerInvariant()
if ($routingMode -ne "path" -and $routingMode -ne "host") {
    throw "PreviewEnvironments.RoutingMode must be 'path' or 'host'."
}

$protocol = if ($infra.ListenerProtocol -eq "HTTPS") { "https" } else { "http" }
$displayHost = Get-CcmPropertyValue $config "CustomDomainName" (Get-CcmPropertyValue $infra "CustomDomainName" $null)
if (-not $displayHost) {
    $displayHost = Get-CcmPropertyValue $infra "NlbDns" (Get-CcmPropertyValue $infra "AlbDns" $null)
}
if (-not $displayHost) {
    throw "Could not determine preview host from CustomDomainName, NlbDns, or AlbDns."
}

$hostName = $null
if ($routingMode -eq "host") {
    $hostTemplate = Get-CcmPropertyValue $previewConfig "HostTemplate" $null
    if (-not $hostTemplate) {
        throw "PreviewEnvironments.HostTemplate is required when RoutingMode is 'host'."
    }
    $hostName = ConvertTo-CcmTemplateValue $hostTemplate @{
        project = $projectName
        id = $identity.PreviewId
    }
    $previewUrl = "${protocol}://${hostName}"
    $origin = $previewUrl
} else {
    $previewUrl = "${protocol}://${displayHost}$($identity.PathPrefix)"
    $origin = "${protocol}://${displayHost}"
}

$expiresAt = [DateTimeOffset]::UtcNow.AddDays([int](Get-CcmPropertyValue $previewConfig "TtlDays" 3)).ToString("o")
$tags = @{
    ManagedBy = "CCM"
    Project = $projectName
    Preview = "true"
    PreviewId = $identity.PreviewId
    PullRequestId = $PullRequestId
    SourceBranch = "$SourceBranch"
    CommitSha = "$CommitSha"
    ExpiresAt = $expiresAt
}
$tagArgs = ConvertTo-CcmTagArguments $tags
$ecsTagArgs = ConvertTo-CcmTagArguments $tags -LowerCaseKeys

Write-Host "Deploying ECS preview '$($identity.PreviewId)' for PR $PullRequestId" -ForegroundColor Cyan
Write-Host "  Service: $($identity.ServiceName)"
Write-Host "  Image tag: $ImageTag"
Write-Host "  URL: $previewUrl"
Write-Host "  ExpiresAt: $expiresAt"

if ($ForceRecreate) {
    Write-Host "ForceRecreate requested; removing any existing preview before deploy..." -ForegroundColor Yellow
    & (Join-Path $ScriptDir "remove-ecs-preview.ps1") `
        -ConfigFile $ConfigFile `
        -PullRequestId $PullRequestId `
        -PreviewId $identity.PreviewId `
        -SourceBranch "$SourceBranch"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to remove existing preview before ForceRecreate deploy."
    }
}

$primaryTargetGroup = $null
if ($infra.TargetGroupArn) {
    $primaryTgOutput = aws elbv2 describe-target-groups `
        --target-group-arns $infra.TargetGroupArn `
        --region $awsRegion `
        --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and $primaryTgOutput) {
        $primaryTargetGroup = (($primaryTgOutput -join "`n") | ConvertFrom-Json).TargetGroups | Select-Object -First 1
    }
}

$healthConfig = Get-CcmPropertyValue $previewConfig "HealthCheck" ([pscustomobject]@{})
$healthPath = Get-CcmPropertyValue $healthConfig "Path" (Get-CcmPropertyValue $primaryTargetGroup "HealthCheckPath" (Get-CcmPropertyValue $config "HealthCheckPath" "/"))
$healthProtocol = Get-CcmPropertyValue $healthConfig "Protocol" (Get-CcmPropertyValue $primaryTargetGroup "HealthCheckProtocol" "HTTP")
$healthMatcher = Get-CcmPropertyValue $healthConfig "Matcher" (Get-CcmPropertyValue (Get-CcmPropertyValue $primaryTargetGroup "Matcher" $null) "HttpCode" "200-399")
$targetProtocol = Get-CcmPropertyValue $primaryTargetGroup "Protocol" "HTTP"

$targetGroup = Get-CcmTargetGroupByName -Name $identity.TargetGroupName -Region $awsRegion
if ($targetGroup) {
    $targetGroupArn = $targetGroup.TargetGroupArn
    Write-Host "Reusing target group: $targetGroupArn" -ForegroundColor Cyan
    aws elbv2 add-tags --resource-arns $targetGroupArn --tags @tagArgs --region $awsRegion | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to tag existing target group $targetGroupArn"
    }
} else {
    Write-Host "Creating target group: $($identity.TargetGroupName)" -ForegroundColor Yellow
    $createArgs = @(
        "elbv2", "create-target-group",
        "--name", $identity.TargetGroupName,
        "--protocol", $targetProtocol,
        "--port", "$containerPort",
        "--vpc-id", $infra.VpcId,
        "--target-type", "ip",
        "--health-check-protocol", $healthProtocol,
        "--matcher", "HttpCode=$healthMatcher",
        "--tags"
    ) + $tagArgs + @("--region", $awsRegion, "--output", "json")
    if ($healthProtocol -eq "HTTP" -or $healthProtocol -eq "HTTPS") {
        $createArgs = @(
            "elbv2", "create-target-group",
            "--name", $identity.TargetGroupName,
            "--protocol", $targetProtocol,
            "--port", "$containerPort",
            "--vpc-id", $infra.VpcId,
            "--target-type", "ip",
            "--health-check-protocol", $healthProtocol,
            "--health-check-path", $healthPath,
            "--matcher", "HttpCode=$healthMatcher",
            "--tags"
        ) + $tagArgs + @("--region", $awsRegion, "--output", "json")
    }
    $created = aws @createArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create target group $($identity.TargetGroupName)"
    }
    $targetGroupArn = (($created -join "`n") | ConvertFrom-Json).TargetGroups[0].TargetGroupArn
}

$deregistrationDelay = [int](Get-CcmPropertyValue $previewConfig "DeregistrationDelaySeconds" 30)
aws elbv2 modify-target-group-attributes `
    --target-group-arn $targetGroupArn `
    --attributes "Key=deregistration_delay.timeout_seconds,Value=$deregistrationDelay" `
    --region $awsRegion | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to set target group deregistration delay for $targetGroupArn"
}

$serviceOutput = aws ecs describe-services `
    --cluster $clusterName `
    --services $identity.ServiceName `
    --region $awsRegion `
    --output json 2>$null
if ($LASTEXITCODE -eq 0 -and $serviceOutput) {
    $existingService = (($serviceOutput -join "`n") | ConvertFrom-Json).services |
        Where-Object { $_.status -eq "ACTIVE" } |
        Select-Object -First 1
    if ($existingService) {
        $attachedTargetGroups = @($existingService.loadBalancers | ForEach-Object { $_.targetGroupArn })
        if ($attachedTargetGroups.Count -gt 0 -and $attachedTargetGroups -notcontains $targetGroupArn) {
            throw "Preview service '$($identity.ServiceName)' already exists with a different target group. Re-run with -ForceRecreate to replace it."
        }
    }
}

$listener = Get-CcmListener -LoadBalancerArn $infra.AlbArn -PreferredProtocol $infra.ListenerProtocol -Region $awsRegion
if ($routingMode -eq "path") {
    $conditions = @(
        @{
            Field = "path-pattern"
            PathPatternConfig = @{ Values = @($identity.PathPrefix, "$($identity.PathPrefix)/*") }
        }
    )
} else {
    $conditions = @(
        @{
            Field = "host-header"
            HostHeaderConfig = @{ Values = @($hostName) }
        }
    )
}
$actions = @(@{ Type = "forward"; TargetGroupArn = $targetGroupArn })
$conditionsFile = Write-CcmJsonTempFile $conditions
$actionsFile = Write-CcmJsonTempFile $actions
try {
    $existingRule = Get-CcmPreviewRule `
        -ListenerArn $listener.ListenerArn `
        -RoutingMode $routingMode `
        -PathPrefix $identity.PathPrefix `
        -HostName $hostName `
        -Region $awsRegion

    if ($existingRule) {
        Write-Host "Updating listener rule: $($existingRule.RuleArn)" -ForegroundColor Cyan
        aws elbv2 modify-rule `
            --rule-arn $existingRule.RuleArn `
            --conditions "file://$conditionsFile" `
            --actions "file://$actionsFile" `
            --region $awsRegion | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to update listener rule $($existingRule.RuleArn)"
        }
        $ruleArn = $existingRule.RuleArn
    } else {
        $priority = Get-CcmNextListenerPriority `
            -ListenerArn $listener.ListenerArn `
            -Base ([int](Get-CcmPropertyValue $previewConfig "RulePriorityBase" 30000)) `
            -BandSize ([int](Get-CcmPropertyValue $previewConfig "RulePriorityBandSize" 1000)) `
            -Region $awsRegion
        Write-Host "Creating listener rule with priority $priority" -ForegroundColor Yellow
        $createdRule = aws elbv2 create-rule `
            --listener-arn $listener.ListenerArn `
            --priority $priority `
            --conditions "file://$conditionsFile" `
            --actions "file://$actionsFile" `
            --tags @tagArgs `
            --region $awsRegion `
            --output json
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create listener rule for preview $($identity.PreviewId)"
        }
        $ruleArn = (($createdRule -join "`n") | ConvertFrom-Json).Rules[0].RuleArn
    }
    aws elbv2 add-tags --resource-arns $ruleArn --tags @tagArgs --region $awsRegion | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to tag listener rule $ruleArn"
    }
}
finally {
    Remove-Item $conditionsFile -ErrorAction SilentlyContinue
    Remove-Item $actionsFile -ErrorAction SilentlyContinue
}

if ($routingMode -eq "host") {
    $zoneId = Get-CcmPropertyValue $config "Route53HostedZoneId" (Get-CcmPropertyValue $infra "Route53HostedZoneId" $null)
    $dnsTarget = Get-CcmPropertyValue $infra "NlbDns" (Get-CcmPropertyValue $infra "AlbDns" $null)
    Set-CcmRoute53Cname -HostedZoneId $zoneId -RecordName $hostName -RecordValue $dnsTarget
}

$tokens = @{
    project = $projectName
    id = $identity.PreviewId
    url = $previewUrl
    origin = $origin
    path = $identity.PathPrefix
}
$environmentOverrides = @()
$configEnvironmentOverrides = Get-CcmPropertyValue $previewConfig "EnvironmentOverrides" $null
if ($configEnvironmentOverrides) {
    foreach ($property in $configEnvironmentOverrides.PSObject.Properties) {
        $environmentOverrides += "$($property.Name)=$(ConvertTo-CcmTemplateValue "$($property.Value)" $tokens)"
    }
}
$secretOverrides = @()
$configSecretOverrides = Get-CcmPropertyValue $previewConfig "SecretOverrides" $null
if ($configSecretOverrides) {
    foreach ($property in $configSecretOverrides.PSObject.Properties) {
        $secretOverrides += "$($property.Name)=$(ConvertTo-CcmTemplateValue "$($property.Value)" $tokens)"
    }
}

$deployParams = @{
    ConfigFile = $ConfigFile
    ServiceName = $identity.ServiceName
    TargetGroupArn = $targetGroupArn
    ImageTag = $ImageTag
    DesiredCount = [int](Get-CcmPropertyValue $previewConfig "DesiredCount" 1)
    ContainerName = $containerName
    ContainerPort = $containerPort
    SkipLatestTag = $true
    CorsAllowedOrigins = $origin
    WebUiUrl = $previewUrl
}
if ($SkipBuild) { $deployParams.SkipBuild = $true }
if ($UsePodman) { $deployParams.UsePodman = $true }
if ($UseDocker) { $deployParams.UseDocker = $true }
if ($UseTarContext) { $deployParams.UseTarContext = $true }
if ($BuildArgs -and $BuildArgs.Count -gt 0) { $deployParams.BuildArgs = $BuildArgs }
if ([bool](Get-CcmPropertyValue $previewConfig "RunMigrations" $false)) { $deployParams.RunMigrations = $true }
if ($environmentOverrides.Count -gt 0) { $deployParams.EnvironmentOverride = $environmentOverrides }
if ($secretOverrides.Count -gt 0) { $deployParams.SecretOverride = $secretOverrides }

# Allow projects with multi-container / EFS-backed live task defs to deploy
# previews from an isolated, ephemeral-storage task definition. Resolved
# relative to the project root if a non-rooted path is given.
$previewTaskDef = Get-CcmPropertyValue $previewConfig "TaskDefinitionFile" $null
if ($previewTaskDef) {
    if (-not [System.IO.Path]::IsPathRooted($previewTaskDef)) {
        $previewTaskDef = Join-Path $ProjectRoot $previewTaskDef
    }
    if (-not (Test-Path $previewTaskDef)) {
        throw "PreviewEnvironments.TaskDefinitionFile '$previewTaskDef' not found."
    }
    $deployParams.TaskDefinitionFile = $previewTaskDef
    Write-Host "  Preview task definition: $previewTaskDef" -ForegroundColor Cyan
}

& (Join-Path $ScriptDir "deploy-ecs.ps1") @deployParams
if ($LASTEXITCODE -ne 0) {
    throw "deploy-ecs.ps1 failed for preview $($identity.PreviewId)"
}

$serviceDetailsOutput = aws ecs describe-services `
    --cluster $clusterName `
    --services $identity.ServiceName `
    --region $awsRegion `
    --output json
if ($LASTEXITCODE -eq 0 -and $serviceDetailsOutput) {
    $serviceArn = ((($serviceDetailsOutput -join "`n") | ConvertFrom-Json).services | Select-Object -First 1).serviceArn
    if ($serviceArn) {
        aws ecs tag-resource --resource-arn $serviceArn --tags @ecsTagArgs --region $awsRegion | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to tag ECS service $serviceArn"
        }
    }
}

Write-Host ""
Write-Host "=== Preview Deployment Complete ===" -ForegroundColor Green
Write-Host "Preview URL: $previewUrl" -ForegroundColor Green
Write-Host "Service: $($identity.ServiceName)"
Write-Host "Target Group: $targetGroupArn"
Write-Host "ExpiresAt: $expiresAt"
Write-Host "##vso[task.setvariable variable=previewUrl;isOutput=true]$previewUrl"
