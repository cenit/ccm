#! /usr/bin/env pwsh

<#
.SYNOPSIS
    Tears down an ECS stack previously created by setup-aws-infrastructure.ps1.

.DESCRIPTION
    Deletes the AWS resources that make up a CCM-provisioned ECS stack, in the
    dependency order returned by Get-CcmEcsTeardownPlan: the ECS service and
    its listeners/load balancer/target group first, then the cluster, then
    IAM roles, then security groups last (an SG referenced by a live ENI fails
    with DependencyViolation). ECR and CloudWatch log groups are only removed
    with -IncludeEcr / -IncludeLogs, since both hold history that cannot be
    recovered.

    This covers only the core serving stack the teardown plan enumerates. It
    does NOT remove setup-aws-infrastructure.ps1's optional capabilities: an
    NLB and its target group(s) (-EnableNlb), DynamoDB tables
    (-EnableDynamoDb), an Aurora cluster/instance/subnet group
    (-EnableAurora), or Secrets Manager secrets - all of them either bill
    while forgotten or hold data that generic tooling must never delete.
    After the teardown it does, however, SCAN for them (read-only): the NLB
    and the Aurora cluster by derived name, DynamoDB tables from the config,
    secrets by SecretsPrefix. Anything found prints a "STILL PRESENT (out of
    scope)" line, a probe that itself failed prints "UNVERIFIED", and either
    one qualifies the closing all-clear - an NLB in particular can keep
    running (and billing) after this script reports success, and its ENIs
    can block the ALB security group's delete. The scan is skipped under
    -WhatIf, preserving the zero-AWS-calls dry run.

    The Route 53 record it tears down is ecs-config.json's CustomDomainName
    when that key is present, and otherwise "<ProjectName>.<ParentDomain>",
    derived exactly as setup-aws-infrastructure.ps1 derives it and under the
    same condition (Route53HostedZoneId and ParentDomain both present). Most
    projects deliberately do not store CustomDomainName - the key hardcodes a
    hostname that goes stale on a rename - so reading it without deriving it
    left their DNS record behind, dangling at a deleted load balancer, while
    the run reported a clean sweep. If the derived name would not be a valid
    hostname (a malformed ParentDomain), it is reported as an error rather
    than used or quietly dropped: the record is not checked, the all-clear is
    withheld and the run exits non-zero.

    Zone-owned record sets are never deleted: when CustomDomainName is the
    zone apex (possible since setup-route53-zone.ps1 -IncludeApex), the
    name-only Route 53 match also returns the zone's NS and SOA, which are
    filtered out by Type rather than attempted and failed. Derivation never
    produces an apex name - "<ProjectName>.<ParentDomain>" is always a
    subdomain - so that path only ever arises from an explicit
    CustomDomainName.

    This script never accepts and never deletes the shared VPC, its subnets,
    or the VPC-endpoint security group: those are shared by every project in
    the account, and Get-CcmEcsTeardownPlan has no parameter that could carry
    their ids in the first place.

    A non-zero AWS CLI exit code is not, by itself, proof that a resource is
    absent: it is also what an expired SSO session, an AccessDenied, or a
    throttled call looks like, and $ErrorActionPreference = 'Stop' does not
    catch it here ($PSNativeCommandUseErrorActionPreference defaults to
    $false on PowerShell 7). Every lookup and delete below checks
    $LASTEXITCODE and inspects stderr for a recognised "does not exist"
    signal before treating a resource as absent; anything else prints a
    "FAILED, still present" line for that resource, is counted separately
    from the resources that were genuinely absent, withholds the closing
    "Nothing remained" message, and makes the script exit non-zero.

    Supports -WhatIf/-Confirm (ConfirmImpact 'High'): every deletion is
    guarded by ShouldProcess, so a dry run prints the plan and every intended
    action without making a single AWS call - but a -WhatIf run can never
    itself confirm teardown completed: ShouldProcess returns $false before
    Remove-CcmEcsResource ever runs, so no resource is even looked up, every
    per-resource counter stays at zero, and the summary line always reads
    "Removed 0 resource(s), skipped 0 already absent, 0 failed." The actual
    proof a teardown completed is a second REAL run (without -WhatIf) after
    this script has reported success once: that second run is safe precisely
    because every resource is already gone, and it is the run that produces
    the per-resource "Absent, skipped" lines and the closing "Nothing
    remained" message.

.PARAMETER ProjectName
    The project name. Must match ecs-config.json's ProjectName when that file
    is present - this is a deliberate refusal, not a warning, because the most
    likely cause of a mismatch is running the script from the wrong checkout.

.PARAMETER AwsRegion
    AWS region. Defaults to ecs-config.json's AwsRegion, falling back to
    "eu-central-1".

.PARAMETER IncludeEcr
    Also delete the ECR repository and every image in it. Irreversible.

.PARAMETER IncludeLogs
    Also delete the CloudWatch log groups and their retained events.

.PARAMETER ConfigFile
    Path to ecs-config.json. Defaults to the project root (parent of this
    script's directory).

.EXAMPLE
    ./remove-aws-infrastructure.ps1 -ProjectName "my-app" -WhatIf

.EXAMPLE
    ./remove-aws-infrastructure.ps1 -ProjectName "my-app" -IncludeEcr -IncludeLogs
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string]$ProjectName,

    [string]$AwsRegion = "eu-central-1",

    [switch]$IncludeEcr,

    [switch]$IncludeLogs,

    [string]$ConfigFile
)

# Every comparable top-level script (remove-ecs-preview.ps1,
# setup-aws-infrastructure.ps1, deploy-ecs.ps1) self-imports CCM.psd1 so it
# works when invoked directly rather than only from inside an already-loaded
# module session; Get-CcmEcsTeardownPlan and Initialize-CcmLogging need the
# same.
Import-Module (Join-Path $PSScriptRoot "CCM.psd1") -Force

# This is the most destructive script in the module - it needs the same
# audit trail setup-aws-infrastructure.ps1 leaves for what it created.
$ccmLog = Initialize-CcmLogging
trap { Stop-CcmLogging $ccmLog; break }

$ErrorActionPreference = "Stop"

if (-not $ConfigFile) {
    $ConfigFile = Join-Path (Split-Path $PSScriptRoot -Parent) "ecs-config.json"
}

if (Test-Path $ConfigFile) {
    $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    if ($config.ProjectName -and $config.ProjectName -ne $ProjectName) {
        throw "ProjectName '$ProjectName' does not match $ConfigFile's '$($config.ProjectName)'. Refusing to run: this is almost always the wrong checkout."
    }
    if (-not $PSBoundParameters.ContainsKey('AwsRegion') -and $config.AwsRegion) {
        $AwsRegion = $config.AwsRegion
    }
}

# --- AWS CLI invocation & "not found" detection -----------------------------

# AWS's not-found signals across the services this script calls. A non-zero
# $LASTEXITCODE alone cannot distinguish "the resource never existed" (safe to
# treat as absent) from a real failure such as an expired SSO session or
# AccessDenied (must not be) - see the .DESCRIPTION above.
$script:CcmAwsNotFoundSignals = @(
    'NotFound', 'NoSuchEntity', 'ResourceNotFoundException',
    'RepositoryNotFoundException', 'ClusterNotFoundException',
    'LoadBalancerNotFound', 'TargetGroupNotFound'
)

# Set by Remove-CcmEcsResource whenever it hits a failure that does not match
# one of the signals above. Cumulative across the whole run; checked once,
# after the loop, to decide whether the closing "Nothing remained" message
# would be honest to print at all. Never reset once set.
$script:HadTeardownError = $false

# Reset to $false by the main loop immediately before each
# Remove-CcmEcsResource call, so the loop can tell whether THIS SPECIFIC item
# errored - $script:HadTeardownError alone cannot: once any earlier item sets
# it, it would make every later item look like it errored too (or, read the
# other way, an item's own error would be indistinguishable from one already
# recorded by something before it). Without this, a later resource that
# genuinely failed to delete would be reported as "Absent, skipped" - false,
# for the one resource that is definitely still there.
$script:HadItemError = $false

function Invoke-CcmAws {
    <#
    Runs `aws <ArgumentList>`, capturing stdout and stderr separately. stderr
    goes to a temp file rather than through 2>&1, so it never gets merged
    into - or mistaken for - the stdout this script parses.
    #>
    param([Parameter(Mandatory)][string[]]$ArgumentList)
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $stdout = & aws @ArgumentList 2>$errFile
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            StdOut   = $stdout
            StdErr   = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
        }
    }
    finally {
        Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue
    }
}

function Test-CcmAwsNotFound {
    param([string]$StdErr)
    if (-not $StdErr) { return $false }
    foreach ($signal in $script:CcmAwsNotFoundSignals) {
        if ($StdErr -match [regex]::Escape($signal)) { return $true }
    }
    return $false
}

function Write-CcmTeardownError {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    ERROR: $Message" -ForegroundColor Red
    $script:HadTeardownError = $true
    $script:HadItemError = $true
}

function Remove-CcmEcsResource {
    param(
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$AwsRegion,
        [object]$Config
    )

    $cluster = "$ProjectName-cluster"

    switch ($Item.Kind) {
        "EcsService" {
            $lookup = Invoke-CcmAws -ArgumentList @(
                "ecs", "describe-services", "--cluster", $cluster, "--services", $Item.Name,
                "--region", $AwsRegion, "--query", "services[?status!='INACTIVE']|[0].serviceName", "--output", "text"
            )
            if ($lookup.ExitCode -ne 0) {
                if (Test-CcmAwsNotFound -StdErr $lookup.StdErr) { return $false }
                Write-CcmTeardownError "describe-services failed for '$($Item.Name)': $($lookup.StdErr)"
                return $false
            }
            $svc = $lookup.StdOut
            if (-not $svc -or $svc -eq "None") { return $false }

            # Scale to zero first: delete --force on a service with running
            # tasks works, but scaling down first starts the tasks draining
            # sooner. It does NOT, by itself, guarantee the ENIs are gone by
            # the time this function returns - the `wait services-inactive`
            # below is what actually blocks until AWS confirms the service
            # (and its tasks) are gone, which is what protects the
            # security-group deletes at the end of the plan.
            $scaleDown = Invoke-CcmAws -ArgumentList @(
                "ecs", "update-service", "--cluster", $cluster, "--service", $Item.Name,
                "--desired-count", "0", "--region", $AwsRegion
            )
            if ($scaleDown.ExitCode -ne 0 -and -not (Test-CcmAwsNotFound -StdErr $scaleDown.StdErr)) {
                Write-CcmTeardownError "update-service --desired-count 0 failed for '$($Item.Name)': $($scaleDown.StdErr)"
                return $false
            }

            $delete = Invoke-CcmAws -ArgumentList @(
                "ecs", "delete-service", "--cluster", $cluster, "--service", $Item.Name,
                "--force", "--region", $AwsRegion
            )
            if ($delete.ExitCode -ne 0) {
                if (Test-CcmAwsNotFound -StdErr $delete.StdErr) { return $false }
                Write-CcmTeardownError "delete-service failed for '$($Item.Name)': $($delete.StdErr)"
                return $false
            }

            # delete-service --force is asynchronous: the cluster (Order 50)
            # cannot be deleted while it still contains a service, and the
            # Fargate ENIs that block the ecs-sg delete (Order 91) do not
            # release until the service's tasks are fully stopped. Block here
            # until AWS confirms the service itself is INACTIVE.
            Invoke-CcmAws -ArgumentList @(
                "ecs", "wait", "services-inactive", "--cluster", $cluster, "--services", $Item.Name, "--region", $AwsRegion
            ) | Out-Null
            return $true
        }

        "AlbListeners" {
            $albLookup = Invoke-CcmAws -ArgumentList @(
                "elbv2", "describe-load-balancers", "--names", $Item.Name,
                "--region", $AwsRegion, "--query", "LoadBalancers[0].LoadBalancerArn", "--output", "text"
            )
            if ($albLookup.ExitCode -ne 0) {
                if (Test-CcmAwsNotFound -StdErr $albLookup.StdErr) { return $false }
                Write-CcmTeardownError "describe-load-balancers failed for '$($Item.Name)': $($albLookup.StdErr)"
                return $false
            }
            $albArn = $albLookup.StdOut
            if (-not $albArn -or $albArn -eq "None") { return $false }

            $listenersLookup = Invoke-CcmAws -ArgumentList @(
                "elbv2", "describe-listeners", "--load-balancer-arn", $albArn,
                "--region", $AwsRegion, "--query", "Listeners[].ListenerArn", "--output", "json"
            )
            if ($listenersLookup.ExitCode -ne 0) {
                Write-CcmTeardownError "describe-listeners failed for '$($Item.Name)': $($listenersLookup.StdErr)"
                return $false
            }
            $listeners = @($listenersLookup.StdOut | ConvertFrom-Json)
            if ($listeners.Count -eq 0) { return $false }

            $ok = $true
            foreach ($listenerArn in $listeners) {
                $del = Invoke-CcmAws -ArgumentList @("elbv2", "delete-listener", "--listener-arn", $listenerArn, "--region", $AwsRegion)
                if ($del.ExitCode -ne 0) {
                    Write-CcmTeardownError "delete-listener failed for '$listenerArn': $($del.StdErr)"
                    $ok = $false
                }
            }
            return $ok
        }

        "Alb" {
            $lookup = Invoke-CcmAws -ArgumentList @(
                "elbv2", "describe-load-balancers", "--names", $Item.Name,
                "--region", $AwsRegion, "--query", "LoadBalancers[0].LoadBalancerArn", "--output", "text"
            )
            if ($lookup.ExitCode -ne 0) {
                if (Test-CcmAwsNotFound -StdErr $lookup.StdErr) { return $false }
                Write-CcmTeardownError "describe-load-balancers failed for '$($Item.Name)': $($lookup.StdErr)"
                return $false
            }
            $albArn = $lookup.StdOut
            if (-not $albArn -or $albArn -eq "None") { return $false }

            $delete = Invoke-CcmAws -ArgumentList @("elbv2", "delete-load-balancer", "--load-balancer-arn", $albArn, "--region", $AwsRegion)
            if ($delete.ExitCode -ne 0) {
                if (Test-CcmAwsNotFound -StdErr $delete.StdErr) { return $false }
                Write-CcmTeardownError "delete-load-balancer failed for '$($Item.Name)': $($delete.StdErr)"
                return $false
            }

            # The ALB's ENIs linger after the API returns. Deleting the
            # security groups later in the plan fails with
            # DependencyViolation if we do not wait for them to go.
            Invoke-CcmAws -ArgumentList @("elbv2", "wait", "load-balancers-deleted", "--load-balancer-arns", $albArn, "--region", $AwsRegion) | Out-Null
            return $true
        }

        "TargetGroup" {
            $lookup = Invoke-CcmAws -ArgumentList @(
                "elbv2", "describe-target-groups", "--names", $Item.Name,
                "--region", $AwsRegion, "--query", "TargetGroups[0].TargetGroupArn", "--output", "text"
            )
            if ($lookup.ExitCode -ne 0) {
                if (Test-CcmAwsNotFound -StdErr $lookup.StdErr) { return $false }
                Write-CcmTeardownError "describe-target-groups failed for '$($Item.Name)': $($lookup.StdErr)"
                return $false
            }
            $tgArn = $lookup.StdOut
            if (-not $tgArn -or $tgArn -eq "None") { return $false }

            $delete = Invoke-CcmAws -ArgumentList @("elbv2", "delete-target-group", "--target-group-arn", $tgArn, "--region", $AwsRegion)
            if ($delete.ExitCode -ne 0) {
                if (Test-CcmAwsNotFound -StdErr $delete.StdErr) { return $false }
                Write-CcmTeardownError "delete-target-group failed for '$($Item.Name)': $($delete.StdErr)"
                return $false
            }
            return $true
        }

        "EcsCluster" {
            $lookup = Invoke-CcmAws -ArgumentList @(
                "ecs", "describe-clusters", "--clusters", $Item.Name,
                "--region", $AwsRegion, "--query", "clusters[?status!='INACTIVE']|[0].clusterName", "--output", "text"
            )
            if ($lookup.ExitCode -ne 0) {
                if (Test-CcmAwsNotFound -StdErr $lookup.StdErr) { return $false }
                Write-CcmTeardownError "describe-clusters failed for '$($Item.Name)': $($lookup.StdErr)"
                return $false
            }
            $found = $lookup.StdOut
            if (-not $found -or $found -eq "None") { return $false }

            $delete = Invoke-CcmAws -ArgumentList @("ecs", "delete-cluster", "--cluster", $Item.Name, "--region", $AwsRegion)
            if ($delete.ExitCode -ne 0) {
                if (Test-CcmAwsNotFound -StdErr $delete.StdErr) { return $false }
                Write-CcmTeardownError "delete-cluster failed for '$($Item.Name)': $($delete.StdErr)"
                return $false
            }
            return $true
        }

        "LogGroup" {
            $lookup = Invoke-CcmAws -ArgumentList @(
                "logs", "describe-log-groups", "--log-group-name-prefix", $Item.Name,
                "--region", $AwsRegion, "--query", "logGroups[?logGroupName=='$($Item.Name)']|[0].logGroupName", "--output", "text"
            )
            if ($lookup.ExitCode -ne 0) {
                if (Test-CcmAwsNotFound -StdErr $lookup.StdErr) { return $false }
                Write-CcmTeardownError "describe-log-groups failed for '$($Item.Name)': $($lookup.StdErr)"
                return $false
            }
            $found = $lookup.StdOut
            if (-not $found -or $found -eq "None") { return $false }

            $delete = Invoke-CcmAws -ArgumentList @("logs", "delete-log-group", "--log-group-name", $Item.Name, "--region", $AwsRegion)
            if ($delete.ExitCode -ne 0) {
                if (Test-CcmAwsNotFound -StdErr $delete.StdErr) { return $false }
                Write-CcmTeardownError "delete-log-group failed for '$($Item.Name)': $($delete.StdErr)"
                return $false
            }
            return $true
        }

        "EcrRepository" {
            $lookup = Invoke-CcmAws -ArgumentList @("ecr", "describe-repositories", "--repository-names", $Item.Name, "--region", $AwsRegion)
            if ($lookup.ExitCode -ne 0) {
                if (Test-CcmAwsNotFound -StdErr $lookup.StdErr) { return $false }
                Write-CcmTeardownError "describe-repositories failed for '$($Item.Name)': $($lookup.StdErr)"
                return $false
            }

            # --force because the repository still holds images.
            $delete = Invoke-CcmAws -ArgumentList @("ecr", "delete-repository", "--repository-name", $Item.Name, "--force", "--region", $AwsRegion)
            if ($delete.ExitCode -ne 0) {
                if (Test-CcmAwsNotFound -StdErr $delete.StdErr) { return $false }
                Write-CcmTeardownError "delete-repository failed for '$($Item.Name)': $($delete.StdErr)"
                return $false
            }
            return $true
        }

        "IamRole" {
            $lookup = Invoke-CcmAws -ArgumentList @("iam", "get-role", "--role-name", $Item.Name)
            if ($lookup.ExitCode -ne 0) {
                if (Test-CcmAwsNotFound -StdErr $lookup.StdErr) { return $false }
                Write-CcmTeardownError "get-role failed for '$($Item.Name)': $($lookup.StdErr)"
                return $false
            }

            # IAM refuses to delete a role that still has policies attached.
            $attachedLookup = Invoke-CcmAws -ArgumentList @(
                "iam", "list-attached-role-policies", "--role-name", $Item.Name,
                "--query", "AttachedPolicies[].PolicyArn", "--output", "json"
            )
            if ($attachedLookup.ExitCode -ne 0) {
                Write-CcmTeardownError "list-attached-role-policies failed for '$($Item.Name)': $($attachedLookup.StdErr)"
                return $false
            }
            $attached = @($attachedLookup.StdOut | ConvertFrom-Json)
            foreach ($policyArn in $attached) {
                $detach = Invoke-CcmAws -ArgumentList @("iam", "detach-role-policy", "--role-name", $Item.Name, "--policy-arn", $policyArn)
                if ($detach.ExitCode -ne 0) {
                    Write-CcmTeardownError "detach-role-policy failed for '$($Item.Name)' / '$policyArn': $($detach.StdErr)"
                    return $false
                }
            }

            $inlineLookup = Invoke-CcmAws -ArgumentList @(
                "iam", "list-role-policies", "--role-name", $Item.Name, "--query", "PolicyNames[]", "--output", "json"
            )
            if ($inlineLookup.ExitCode -ne 0) {
                Write-CcmTeardownError "list-role-policies failed for '$($Item.Name)': $($inlineLookup.StdErr)"
                return $false
            }
            $inline = @($inlineLookup.StdOut | ConvertFrom-Json)
            foreach ($policyName in $inline) {
                $del = Invoke-CcmAws -ArgumentList @("iam", "delete-role-policy", "--role-name", $Item.Name, "--policy-name", $policyName)
                if ($del.ExitCode -ne 0) {
                    Write-CcmTeardownError "delete-role-policy failed for '$($Item.Name)' / '$policyName': $($del.StdErr)"
                    return $false
                }
            }

            $delete = Invoke-CcmAws -ArgumentList @("iam", "delete-role", "--role-name", $Item.Name)
            if ($delete.ExitCode -ne 0) {
                if (Test-CcmAwsNotFound -StdErr $delete.StdErr) { return $false }
                Write-CcmTeardownError "delete-role failed for '$($Item.Name)': $($delete.StdErr)"
                return $false
            }
            return $true
        }

        "SecurityGroup" {
            $lookup = Invoke-CcmAws -ArgumentList @(
                "ec2", "describe-security-groups",
                "--filters", "Name=group-name,Values=$($Item.Name)",
                "--region", $AwsRegion, "--query", "SecurityGroups[].{GroupId:GroupId,GroupName:GroupName}", "--output", "json"
            )
            if ($lookup.ExitCode -ne 0) {
                if (Test-CcmAwsNotFound -StdErr $lookup.StdErr) { return $false }
                Write-CcmTeardownError "describe-security-groups failed for '$($Item.Name)': $($lookup.StdErr)"
                return $false
            }
            $candidates = @($lookup.StdOut | ConvertFrom-Json)

            # Exact-match only, and refuse on more than one match: security
            # group names are unique per VPC, not per account/region, and a
            # shared account commonly holds many unrelated projects in one
            # VPC. Picking the first result back would be exactly the kind of
            # "close enough" match that could delete a foreign or shared
            # group.
            $exact = @($candidates | Where-Object { $_.GroupName -eq $Item.Name })
            if ($exact.Count -eq 0) { return $false }
            if ($exact.Count -gt 1) {
                Write-CcmTeardownError "found $($exact.Count) security groups named '$($Item.Name)' - refusing to guess which one to delete. Resolve manually."
                return $false
            }
            $sgId = $exact[0].GroupId

            $delete = Invoke-CcmAws -ArgumentList @("ec2", "delete-security-group", "--group-id", $sgId, "--region", $AwsRegion)
            if ($delete.ExitCode -ne 0) {
                if (Test-CcmAwsNotFound -StdErr $delete.StdErr) { return $false }
                # Almost always DependencyViolation from an ENI that has not
                # drained yet. The group still exists - it must be reported
                # as a real leftover, not folded into "absent".
                Write-CcmTeardownError "could not delete security group '$($Item.Name)' ($sgId) - likely a lingering ENI (DependencyViolation). Retry in a few minutes. $($delete.StdErr)"
                return $false
            }
            return $true
        }

        "Route53Record" {
            $zoneId = if ($Config) { $Config.Route53HostedZoneId } else { $null }
            if (-not $zoneId) {
                # No hosted zone id to check against - this record may well
                # still exist. Report it as a real leftover, not "absent".
                Write-CcmTeardownError "cannot check/delete Route 53 record '$($Item.Name)': no Route53HostedZoneId in config."
                return $false
            }

            $lookup = Invoke-CcmAws -ArgumentList @(
                "route53", "list-resource-record-sets", "--hosted-zone-id", $zoneId,
                "--query", "ResourceRecordSets[?Name=='$($Item.Name).']", "--output", "json"
            )
            if ($lookup.ExitCode -ne 0) {
                Write-CcmTeardownError "list-resource-record-sets failed for '$($Item.Name)': $($lookup.StdErr)"
                return $false
            }
            # Filters on Name only, deliberately: a name commonly carries more
            # than one record type (A and AAAA aliases both pointing at the
            # same load balancer), and filtering on a single Type here would
            # silently leave the other alias running. Delete every match -
            # except NS and SOA, which are the zone's own plumbing, not
            # records setup-aws-infrastructure.ps1 ever created. They match
            # when CustomDomainName is the zone apex (possible since
            # setup-route53-zone.ps1 -IncludeApex), and Route 53 refuses to
            # delete them there - attempting it would end every apex teardown
            # with spurious FAILED lines for record sets nobody can or should
            # delete.
            $existingSets = @($lookup.StdOut | ConvertFrom-Json)
            foreach ($zoneOwned in @($existingSets | Where-Object { $_.Type -in @('NS', 'SOA') })) {
                Write-Host "    Skipping zone-owned $($zoneOwned.Type) record set at '$($Item.Name)'" -ForegroundColor DarkGray
            }
            $existingSets = @($existingSets | Where-Object { $_.Type -notin @('NS', 'SOA') })
            if ($existingSets.Count -eq 0) { return $false }

            $ok = $true
            foreach ($recordSet in $existingSets) {
                $tempFile = [System.IO.Path]::GetTempFileName()
                try {
                    $batch = @{ Changes = @(@{ Action = "DELETE"; ResourceRecordSet = $recordSet }) } |
                        ConvertTo-Json -Depth 10 -Compress
                    $batch | Set-Content -LiteralPath $tempFile -Encoding utf8
                    $change = Invoke-CcmAws -ArgumentList @(
                        "route53", "change-resource-record-sets", "--hosted-zone-id", $zoneId,
                        "--change-batch", "file://$tempFile"
                    )
                    if ($change.ExitCode -ne 0) {
                        Write-CcmTeardownError "change-resource-record-sets failed for '$($Item.Name)' ($($recordSet.Type)): $($change.StdErr)"
                        $ok = $false
                    }
                }
                finally {
                    Remove-Item -LiteralPath $tempFile -ErrorAction SilentlyContinue
                }
            }
            return $ok
        }

        default {
            Write-Host "    Unknown resource kind '$($Item.Kind)' - skipped" -ForegroundColor Yellow
            return $false
        }
    }
}

function Find-CcmOutOfScopeLeftover {
    <#
    Read-only probes for the resources the teardown plan deliberately does
    NOT cover: the NLB, the Aurora cluster, config-declared DynamoDB tables
    and the project's Secrets Manager secrets. All of them either bill while
    forgotten (the NLB) or hold data that generic tooling must never delete
    (the rest) - so this function only ever LOOKS, and the scan exists so
    the closing summary cannot read as "fully retired" while one of them is
    still running.

    Returns one object per resource needing manual attention, with Status
    'present' (confirmed still there) or 'unknown' (the probe itself failed,
    so the resource cannot honestly be called absent).
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$AwsRegion,
        [object]$Config
    )

    $found = [System.Collections.Generic.List[object]]::new()
    $report = {
        param([string]$Status, [string]$Description)
        $found.Add([pscustomobject]@{ Status = $Status; Description = $Description })
    }

    # The NLB and Aurora probes run unconditionally rather than only when the
    # config still says EnableNlb/EnableAurora: their names are derivable,
    # the probes are single cheap reads, and config drift (a flag removed
    # after the resource was created) must not hide a leftover that bills.
    $nlb = Invoke-CcmAws -ArgumentList @(
        "elbv2", "describe-load-balancers", "--names", "$ProjectName-nlb",
        "--region", $AwsRegion, "--query", "LoadBalancers[0].LoadBalancerArn", "--output", "text"
    )
    if ($nlb.ExitCode -eq 0 -and $nlb.StdOut -and "$($nlb.StdOut)".Trim() -ne "None") {
        & $report 'present' "NLB '$ProjectName-nlb' (keeps billing; its ENIs can also block a security-group delete)"
    } elseif ($nlb.ExitCode -ne 0 -and -not (Test-CcmAwsNotFound -StdErr $nlb.StdErr)) {
        & $report 'unknown' "NLB '$ProjectName-nlb' (probe failed: $($nlb.StdErr))"
    }

    # DBClusterNotFoundFault carries the 'NotFound' signal, so a genuinely
    # absent cluster is silent here.
    $aurora = Invoke-CcmAws -ArgumentList @(
        "rds", "describe-db-clusters", "--db-cluster-identifier", "$ProjectName-cluster",
        "--region", $AwsRegion, "--query", "DBClusters[0].Status", "--output", "text"
    )
    if ($aurora.ExitCode -eq 0 -and $aurora.StdOut -and "$($aurora.StdOut)".Trim() -ne "None") {
        & $report 'present' "Aurora cluster '$ProjectName-cluster' (holds data)"
    } elseif ($aurora.ExitCode -ne 0 -and -not (Test-CcmAwsNotFound -StdErr $aurora.StdErr)) {
        & $report 'unknown' "Aurora cluster '$ProjectName-cluster' (probe failed: $($aurora.StdErr))"
    }

    # DynamoDB table names are only knowable from the config.
    $tables = if ($Config -and $Config.DynamoDbTables) { @($Config.DynamoDbTables) } else { @() }
    foreach ($table in $tables) {
        if (-not $table -or -not $table.Name) { continue }
        $ddb = Invoke-CcmAws -ArgumentList @(
            "dynamodb", "describe-table", "--table-name", $table.Name, "--region", $AwsRegion
        )
        if ($ddb.ExitCode -eq 0) {
            & $report 'present' "DynamoDB table '$($table.Name)' (holds data)"
        } elseif (-not (Test-CcmAwsNotFound -StdErr $ddb.StdErr)) {
            & $report 'unknown' "DynamoDB table '$($table.Name)' (probe failed: $($ddb.StdErr))"
        }
    }

    # Secrets: prefix-match on SecretsPrefix, defaulting to the project name
    # exactly as setup-aws-infrastructure.ps1 does. The prefix feeds an AWS
    # CLI shorthand filter, so the same separator rules as ProjectName apply:
    # a comma or wildcard could widen this (read-only) scan to other
    # projects' secret NAMES, which must not even be printed here - a value
    # that fails the charset check degrades to "check manually", not to a
    # wider query.
    $secretsPrefix = if ($Config -and $Config.SecretsPrefix) { $Config.SecretsPrefix } else { $ProjectName }
    if ($secretsPrefix -notmatch '^[a-zA-Z0-9][a-zA-Z0-9/_.-]*\z') {
        & $report 'unknown' "secrets under '$secretsPrefix/' (prefix failed validation - check Secrets Manager manually)"
    } else {
        $secrets = Invoke-CcmAws -ArgumentList @(
            "secretsmanager", "list-secrets", "--filters", "Key=name,Values=$secretsPrefix/",
            "--region", $AwsRegion, "--query", "SecretList[].Name", "--output", "json"
        )
        if ($secrets.ExitCode -eq 0) {
            foreach ($secretName in @($secrets.StdOut | ConvertFrom-Json)) {
                & $report 'present' "Secrets Manager secret '$secretName' (holds credentials)"
            }
        } elseif (-not (Test-CcmAwsNotFound -StdErr $secrets.StdErr)) {
            & $report 'unknown' "secrets under '$secretsPrefix/' (probe failed: $($secrets.StdErr))"
        }
    }

    return @($found)
}

# --- Which DNS record to tear down -----------------------------------------
# setup-aws-infrastructure.ps1 does not require ecs-config.json to carry
# CustomDomainName: when Route53HostedZoneId AND ParentDomain are both present
# and CustomDomainName is not, it DERIVES "<ProjectName>.<ParentDomain>" and
# creates the record under that name. That is the recommended configuration -
# storing the key hardcodes a hostname that goes stale the moment the project
# is renamed - so the teardown has to mirror the derivation, or the record
# setup created is left behind dangling at a deleted load balancer while this
# script reports a clean sweep: with no domain to pass, Get-CcmEcsTeardownPlan
# emits no Route53Record item at all, so there is not even a resource to
# report as failed.
#
# The gate is deliberately identical to setup's ($Route53HostedZoneId -and
# $ParentDomain). A laxer one here would plan a record setup never created
# (and, with no zone id, fail every such teardown for a record that does not
# exist); a stricter one would go on leaving records behind.
$customDomain = $null
if ($config -and $config.CustomDomainName) {
    $customDomain = $config.CustomDomainName
} elseif ($config -and $config.ParentDomain -and $config.Route53HostedZoneId) {
    $derivedDomain = "$ProjectName.$($config.ParentDomain)"

    # Must satisfy Get-CcmEcsTeardownPlan's ValidatePattern on
    # CustomDomainName (Public/Get-CcmEcsTeardownPlan.ps1 - keep the two in
    # step; Tests/EcsTeardown.Tests.ps1 asserts this literal still matches the
    # attribute). Binding a value that fails it throws a parameter-binding
    # error that reads as a crash rather than a diagnosis, and swallowing it
    # would silently skip a record this script exists to delete. Neither is
    # acceptable in a script whose whole design is "never print a false
    # all-clear", so report it the same way as any other resource that could
    # not be dealt with: loudly, by name, with the all-clear withheld and a
    # non-zero exit.
    if ($derivedDomain -notmatch '^([a-zA-Z0-9][a-zA-Z0-9.-]*)?\z') {
        Write-CcmTeardownError ("cannot derive the Route 53 record name from ProjectName '$ProjectName' and " +
            "ParentDomain '$($config.ParentDomain)': '$derivedDomain' is not a valid hostname (letters, digits, " +
            "dots and hyphens only, starting with an alphanumeric). This stack's DNS record has NOT been checked " +
            "or deleted. Fix ParentDomain in $ConfigFile, or set CustomDomainName explicitly, then re-run.")
    } else {
        $customDomain = $derivedDomain
        Write-Host "Derived CustomDomainName from ParentDomain: $customDomain" -ForegroundColor Cyan
    }
}

$plan = Get-CcmEcsTeardownPlan -ProjectName $ProjectName `
    -CustomDomainName $customDomain `
    -IncludeEcr:$IncludeEcr -IncludeLogs:$IncludeLogs

Write-Host "Teardown plan for '$ProjectName' in ${AwsRegion}:" -ForegroundColor Cyan
$plan | ForEach-Object { Write-Host ("  [{0,3}] {1,-14} {2}" -f $_.Order, $_.Kind, $_.Name) }
Write-Host ""

$removed = 0
$skipped = 0
$failed = 0

foreach ($item in $plan) {
    $target = "$($item.Kind) '$($item.Name)'"
    if (-not $PSCmdlet.ShouldProcess($target, "Delete")) { continue }

    # Reset per-item, so a later item's own error is never masked - or
    # falsely implied - by an earlier item's error. See the declaration of
    # $script:HadItemError above for why this can't just be inferred from
    # $script:HadTeardownError.
    $script:HadItemError = $false
    $existed = Remove-CcmEcsResource -Item $item -ProjectName $ProjectName -AwsRegion $AwsRegion -Config $config

    if ($existed) {
        $removed++
        Write-Host "  Deleted $target" -ForegroundColor Green
    } elseif ($script:HadItemError) {
        # This resource is not absent - a lookup or delete for it failed for
        # a reason other than "does not exist". Reporting it as "Absent,
        # skipped" would be a false claim about the one resource that is
        # definitely still there.
        $failed++
        Write-Host "  FAILED, still present: $target" -ForegroundColor Red
    } else {
        $skipped++
        Write-Host "  Absent, skipped: $target" -ForegroundColor DarkGray
    }
}

# --- Out-of-scope leftovers: report, never delete ---------------------------
# The plan deliberately covers only the core serving stack; the optional
# capabilities setup-aws-infrastructure.ps1 may have added are only ever
# REPORTED here, so the closing summary cannot read as "fully retired" while
# an NLB is still billing or a database still holds data.
$leftovers = @()
if ($WhatIfPreference) {
    # The scan is read-only, which makes it tempting to run it anyway - but
    # the dry-run contract is "zero AWS calls under -WhatIf", and a
    # behavioural test holds it to that.
    Write-Host ""
    Write-Host "Skipping the out-of-scope leftover scan (NLB, Aurora, DynamoDB, secrets): a -WhatIf run makes no AWS calls." -ForegroundColor DarkGray
} else {
    Write-Host ""
    Write-Host "Scanning for out-of-scope resources this script never deletes (NLB, Aurora, DynamoDB, secrets)..." -ForegroundColor Cyan
    $leftovers = @(Find-CcmOutOfScopeLeftover -ProjectName $ProjectName -AwsRegion $AwsRegion -Config $config)
    if ($leftovers.Count -eq 0) {
        Write-Host "  None found." -ForegroundColor DarkGray
    }
    foreach ($leftover in $leftovers) {
        if ($leftover.Status -eq 'present') {
            Write-Host "  STILL PRESENT (out of scope): $($leftover.Description) - remove manually when retiring this project." -ForegroundColor Yellow
        } else {
            Write-Host "  UNVERIFIED (out of scope): $($leftover.Description)" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "Removed $removed resource(s), skipped $skipped already absent, $failed failed." -ForegroundColor Cyan
if ($script:HadTeardownError) {
    Write-Host "One or more errors were reported above (see ERROR and FAILED lines) - this stack is NOT confirmed fully retired. Resolve them and re-run before trusting a clean result." -ForegroundColor Red
} elseif ($skipped -eq $plan.Count) {
    if ($leftovers.Count -gt 0) {
        Write-Host "Every planned resource is already gone, but the out-of-scope resource(s) listed above still need manual attention before this project is fully retired." -ForegroundColor Yellow
    } else {
        Write-Host "Nothing remained - this stack is already fully retired." -ForegroundColor Green
    }
}

Stop-CcmLogging $ccmLog

# The red text above is not machine-readable; the exit code is. Anything
# scripting this (CI, a retirement runbook) must see a failed teardown fail,
# exactly as setup-azure-devops-iam.ps1 -Remove already does.
if ($script:HadTeardownError) { exit 1 }
