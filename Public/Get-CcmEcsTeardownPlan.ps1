function Get-CcmEcsTeardownPlan {
    <#
    .SYNOPSIS
    Returns the ordered list of AWS resources that make up a CCM-provisioned ECS
    stack, for teardown.

    .DESCRIPTION
    Covers the core serving stack setup-aws-infrastructure.ps1 always creates -
    ECS service, ALB listeners/load balancer, target group, cluster, IAM roles,
    security groups - in reverse dependency order, so that
    remove-aws-infrastructure.ps1 can delete them without tripping over AWS
    dependency errors: a load balancer cannot be deleted while a listener
    references it, a cluster cannot be deleted while a service is active, and
    a security group cannot be deleted while a live network interface still
    references it.

    This plan deliberately does NOT cover setup-aws-infrastructure.ps1's
    optional capabilities: an NLB and its target group(s) (-EnableNlb),
    DynamoDB tables (-EnableDynamoDb), an Aurora cluster/instance/subnet group
    (-EnableAurora), or Secrets Manager secrets. For an NLB-fronted project in
    particular, this plan's Route53Record entry points at the NLB, not the
    ALB - deleting only the DNS record and the ALB leaves the NLB (and its
    billing) running, and its ENIs can also block the ALB security group's
    delete. remove-aws-infrastructure.ps1 scans for these after the teardown
    and reports what it finds, but never deletes them - check manually before
    relying on this plan alone.

    Every plan item's Name is derived from ProjectName, with one exception:
    Route53Record's Name is the caller-supplied CustomDomainName, lowercased,
    since a custom domain is never itself part of the project name. The
    lowercasing matters: Route 53 stores record names lowercased, and
    remove-aws-infrastructure.ps1 matches this Name against them with a
    case-sensitive JMESPath '==' - an uppercase letter here would make a
    still-live record look absent and leave a dangling alias behind.

    That exception is deliberate, and stays that way: this function knows
    nothing about config files. When ecs-config.json omits CustomDomainName,
    it is remove-aws-infrastructure.ps1 - the executor - that resolves the
    name to "<ProjectName>.<ParentDomain>", mirroring how
    setup-aws-infrastructure.ps1 derived it when the record was created, and
    passes the result here as an ordinary caller-supplied value.

    This function deliberately accepts NO parameter for a VPC, subnet or
    VPC-endpoint security group. Those are shared across every project in an
    account, and a teardown that could name them could sever connectivity for
    unrelated projects. Being unable to express them is a stronger guarantee
    than filtering them out.

    ProjectName is restricted to alphanumerics and hyphens (starting with an
    alphanumeric) for the same reason, one level down: several AWS CLI
    commands this plan feeds into take shorthand filters such as
    "Name=group-name,Values=<value>", where a comma ends the value early and
    starts a new one, and EC2 filter values accept "*" as a wildcard. An
    unrestricted ProjectName could resolve a lookup to an unrelated - possibly
    shared - resource. Rejecting the characters that make that possible here,
    structurally, is stronger than sanitizing them downstream.

    CustomDomainName is restricted to a hostname charset (letters, digits,
    dots and hyphens, starting with an alphanumeric) for the same class of
    reason: remove-aws-infrastructure.ps1 interpolates it, unescaped, into a
    JMESPath --query expression ("...Name=='<value>.'"). A value containing a
    single quote closes that string early and lets the rest of the value
    extend the expression - e.g. "x' || 'a'=='a" turns the filter into
    "Name=='x' || 'a'=='a.'", which is still valid JMESPath and matches every
    record set in the zone, all of which would then be deleted. One field
    over from the ProjectName case above, same fix: reject the character that
    makes it possible, structurally, rather than sanitize it downstream.

    Deletion of the container registry and the log groups is opt-in: both hold
    history that is not recoverable, and a caller renaming a stack usually
    wants them gone while a caller recovering from a bad deploy does not.

    .PARAMETER ProjectName
    The project name, matching ecs-config.json's ProjectName. Must start with
    an alphanumeric character and contain only alphanumerics and hyphens.

    .PARAMETER CustomDomainName
    Optional. The Route 53 record to remove, e.g. "my-app.example.com". When
    given, must contain only letters, digits, dots and hyphens, and start
    with an alphanumeric; an empty string (no custom domain) is also
    accepted.

    .PARAMETER IncludeEcr
    Also remove the ECR repository and every image in it. Irreversible.

    .PARAMETER IncludeLogs
    Also remove the CloudWatch log groups and their retained events.

    .OUTPUTS
    An array of PSCustomObject with Order (int), Kind (string) and Name
    (string), ascending by Order.

    .EXAMPLE
    Get-CcmEcsTeardownPlan -ProjectName "my-app" -IncludeEcr -IncludeLogs
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]*\z')]
        [string]$ProjectName,

        # Empty string is deliberately accepted alongside a real hostname:
        # callers that always bind this parameter (e.g.
        # remove-aws-infrastructure.ps1, which passes whatever
        # ecs-config.json's CustomDomainName resolves to, including nothing)
        # bind $null as "", and that must mean "no custom domain" here, not a
        # validation failure - the "$CustomDomainName" truthiness check below
        # already treats it that way.
        [ValidatePattern('^([a-zA-Z0-9][a-zA-Z0-9.-]*)?\z')]
        [string]$CustomDomainName,

        [switch]$IncludeEcr,

        [switch]$IncludeLogs
    )

    $plan = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([int]$Order, [string]$Kind, [string]$Name)
        $plan.Add([pscustomobject]@{ Order = $Order; Kind = $Kind; Name = $Name })
    }

    # 10-40: the serving path, innermost first.
    & $add 10 "EcsService"   "$ProjectName-service"
    & $add 20 "AlbListeners" "$ProjectName-alb"
    & $add 30 "Alb"          "$ProjectName-alb"
    & $add 40 "TargetGroup"  "$ProjectName-tg"

    # 50: the cluster, once it holds no service.
    & $add 50 "EcsCluster" "$ProjectName-cluster"

    # 60-70: opt-in, irreversible history.
    if ($IncludeLogs) {
        & $add 60 "LogGroup" "/ecs/$ProjectName"
        & $add 61 "LogGroup" "/ecs/$ProjectName-migrations"
    }
    if ($IncludeEcr) {
        & $add 70 "EcrRepository" $ProjectName
    }

    # 80: roles, after nothing can still assume them.
    & $add 80 "IamRole" "$ProjectName-execution-role"
    & $add 81 "IamRole" "$ProjectName-task-role"

    # 90: security groups last - an SG referenced by a live ENI fails with
    # DependencyViolation, and the ENIs only disappear once the tasks and the
    # load balancer are gone.
    & $add 90 "SecurityGroup" "$ProjectName-alb-sg"
    & $add 91 "SecurityGroup" "$ProjectName-ecs-sg"

    # 100: DNS, independent of the AWS teardown order. Lowercased - see the
    # Route53Record exception in the .DESCRIPTION.
    if ($CustomDomainName) {
        & $add 100 "Route53Record" $CustomDomainName.ToLowerInvariant()
    }

    return @($plan | Sort-Object Order)
}
