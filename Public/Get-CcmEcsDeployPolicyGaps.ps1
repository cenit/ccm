function Get-CcmEcsDeployPolicyGaps {
    <#
    .SYNOPSIS
    Compares an IAM policy document against the AWS actions the CCM ECS deploy
    scripts actually call, and reports what is missing.

    .DESCRIPTION
    setup-azure-devops-iam.ps1 attaches a deploy policy to the Azure DevOps IAM
    user. Some of the actions it needs are only exercised on rarely-taken paths -
    the daily preview-cleanup cron, a first deploy that creates the service, the
    layer uploads inside a container push - so a missing grant surfaces days later
    as a confusing runtime failure. This function makes that gap detectable (and
    unit-testable) before the policy is attached.

    Actions are split into two tiers:

      Required     - exercised by every deploy of a project with this config, so a
                     missing grant is treated as a hard failure by the caller.
      Recommended  - only reached through an optional switch (-RunMigrations,
                     -SkipBuild). Reported as a warning: requiring them would
                     reject policies that are perfectly correct for projects that
                     never use those switches.

    The action lists are derived from the actual `aws ...` calls in deploy-ecs.ps1,
    deploy-ecs-preview.ps1, remove-ecs-preview.ps1 and cleanup-ecs-previews.ps1.

    .PARAMETER PolicyObject
    The parsed IAM policy document (ConvertFrom-Json of the policy file).

    .PARAMETER Config
    The parsed ecs-config.json. Optional; its PreviewEnvironments and
    ExternalImage settings decide which actions apply.

    .OUTPUTS
    A PSCustomObject with Missing, MissingRecommended (arrays of
    "action (needed for: reason)" strings), plus RequiredCount and
    RecommendedCount.

    .EXAMPLE
    $gaps = Get-CcmEcsDeployPolicyGaps -PolicyObject $policy -Config $cfg
    if ($gaps.Missing.Count -gt 0) { throw "Incomplete policy" }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$PolicyObject,

        [object]$Config
    )

    function Get-CcmGrantedActionSet {
        param([object]$Policy)

        $granted = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($statement in @($Policy.Statement)) {
            if ($statement.Effect -ne "Allow") { continue }
            foreach ($action in @($statement.Action)) {
                if ($action) { [void]$granted.Add("$action") }
            }
        }
        # Comma operator: a bare `return $granted` enumerates the set, which turns
        # a policy granting nothing (e.g. all-Deny) into $null and crashes the
        # membership checks below.
        return ,$granted
    }

    function Test-CcmActionInSet {
        param(
            [System.Collections.Generic.HashSet[string]]$GrantedActions,
            [string]$RequiredAction
        )

        if ($GrantedActions.Contains($RequiredAction) -or $GrantedActions.Contains("*")) {
            return $true
        }
        $service = $RequiredAction.Split(':')[0]
        if ($GrantedActions.Contains("$service`:*")) { return $true }
        foreach ($granted in $GrantedActions) {
            # Only a wildcard within the same service can cover the action:
            # 'ecs:Desc*' must not be treated as granting 'ecr:DescribeImages'.
            if (-not $granted.EndsWith('*')) { continue }
            $prefix = $granted.TrimEnd('*')
            if ($prefix -notmatch '^[^:]+:') { continue }
            if ($RequiredAction.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        return $false
    }

    $required = [ordered]@{}
    $recommended = [ordered]@{}

    # --- Image build + push (skipped when the image comes from another registry) ---
    $externalImage = $null
    if ($Config -and $Config.PSObject.Properties.Name -contains "ExternalImage") {
        $externalImage = $Config.ExternalImage
    }
    if (-not $externalImage) {
        $required["ecr:GetAuthorizationToken"]       = "authenticating the container tool to ECR"
        $required["ecr:BatchCheckLayerAvailability"] = "the container push checking which layers ECR already has"
        $required["ecr:InitiateLayerUpload"]         = "the container push starting a layer upload"
        $required["ecr:UploadLayerPart"]             = "the container push streaming layer data"
        $required["ecr:CompleteLayerUpload"]         = "the container push finalizing a layer"
        $required["ecr:PutImage"]                    = "pushing the image manifest, and re-tagging it as 'latest'"
        $required["ecr:BatchGetImage"]               = "reading the pushed manifest to re-tag it as 'latest'"
        $recommended["ecr:DescribeImages"]           = "deploy-ecs.ps1 -SkipBuild verifying the tag already exists in ECR"
    }

    # --- Every deploy ---
    $required["ecs:RegisterTaskDefinition"]    = "registering the new task definition"
    $required["ecs:CreateService"]             = "deploy-ecs.ps1 creating the service on a first deploy"
    $required["ecs:UpdateService"]             = "rolling out the deployment"
    $required["ecs:DescribeServices"]          = "polling deployment status"
    $required["secretsmanager:DescribeSecret"] = "resolving secret ARNs for the task definition"
    $required["iam:PassRole"]                  = "passing the task/execution role to ECS"

    $recommended["ecs:RunTask"]       = "deploy-ecs.ps1 -RunMigrations starting the migrations task"
    $recommended["ecs:DescribeTasks"] = "deploy-ecs.ps1 -RunMigrations polling the migrations task"

    # --- Per-PR preview environments ---
    $previewConfig = $null
    if ($Config -and $Config.PSObject.Properties.Name -contains "PreviewEnvironments") {
        $previewConfig = $Config.PreviewEnvironments
    }
    if ($previewConfig -and $previewConfig.Enabled) {
        $required["tag:GetResources"]   = "cleanup-ecs-previews.ps1 discovering preview resources by tag"
        $required["ecs:DeleteService"]  = "remove-ecs-preview.ps1 tearing down a per-PR ECS service"
        $required["ecs:TagResource"]    = "deploy-ecs-preview.ps1 tagging the per-PR service for cleanup"
        $required["elasticloadbalancing:CreateTargetGroup"]            = "deploy-ecs-preview.ps1 creating a per-PR target group"
        $required["elasticloadbalancing:DeleteTargetGroup"]            = "remove-ecs-preview.ps1 tearing down a per-PR target group"
        $required["elasticloadbalancing:DescribeTargetGroups"]         = "locating the per-PR target group by name"
        $required["elasticloadbalancing:ModifyTargetGroupAttributes"]  = "deploy-ecs-preview.ps1 setting deregistration delay"
        $required["elasticloadbalancing:CreateRule"]                   = "deploy-ecs-preview.ps1 creating a per-PR listener rule"
        $required["elasticloadbalancing:DeleteRule"]                   = "remove-ecs-preview.ps1 tearing down a per-PR listener rule"
        $required["elasticloadbalancing:ModifyRule"]                   = "deploy-ecs-preview.ps1 updating an existing per-PR rule"
        $required["elasticloadbalancing:DescribeRules"]                = "finding a free listener-rule priority"
        $required["elasticloadbalancing:DescribeListeners"]            = "locating the ALB listener the rule attaches to"
        $required["elasticloadbalancing:AddTags"]                      = "tagging per-PR ELB resources for cleanup"

        $routingMode = "path"
        if ($previewConfig.PSObject.Properties.Name -contains "RoutingMode" -and $previewConfig.RoutingMode) {
            $routingMode = "$($previewConfig.RoutingMode)".ToLowerInvariant()
        }
        if ($routingMode -eq "host") {
            $required["route53:ChangeResourceRecordSets"] = "per-PR CNAME create/delete (RoutingMode: host)"
            $required["route53:ListResourceRecordSets"]   = "looking up a per-PR CNAME (RoutingMode: host)"
        }
    }

    $granted = Get-CcmGrantedActionSet -Policy $PolicyObject

    $missing = @()
    foreach ($action in $required.Keys) {
        if (-not (Test-CcmActionInSet -GrantedActions $granted -RequiredAction $action)) {
            $missing += "$action (needed for: $($required[$action]))"
        }
    }

    $missingRecommended = @()
    foreach ($action in $recommended.Keys) {
        if (-not (Test-CcmActionInSet -GrantedActions $granted -RequiredAction $action)) {
            $missingRecommended += "$action (needed for: $($recommended[$action]))"
        }
    }

    [pscustomobject]@{
        Missing            = @($missing)
        MissingRecommended = @($missingRecommended)
        RequiredCount      = $required.Count
        RecommendedCount   = $recommended.Count
    }
}
