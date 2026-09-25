function Get-CcmEcsLoadBalancerSpecs {
    <#
    .SYNOPSIS
    Builds the --load-balancers spec list for an ECS create-service/update-service call.

    .DESCRIPTION
    Returns one "targetGroupArn=...,containerName=...,containerPort=..." spec per
    target group attachment: the service's primary target group first, followed by
    any ExposedTargetGroups (extra NLB/ALB target groups for side-car containers,
    recorded in infrastructure-config.json by setup-aws-infrastructure.ps1).

    ExposedTargetGroups are SHARED, long-lived resources that belong to the primary
    (production) service. Ephemeral services — PR previews deployed with a
    TargetGroupArn override — must NOT attach to them: doing so registers the
    preview's side-car containers (e.g. neo4j, qdrant) into the production load
    balancer target groups, so production traffic round-robins onto the preview's
    containers. Pass -ExcludeExposedTargetGroups for such services to attach only
    their own primary target group.

    .PARAMETER PrimaryTargetGroupArn
    ARN of the service's own (primary) target group.

    .PARAMETER ContainerName
    Container that receives primary target group traffic.

    .PARAMETER ContainerPort
    Port of the primary container targeted by the primary target group.

    .PARAMETER ExposedTargetGroups
    Objects with TargetGroupArn, ContainerName, ContainerPort properties (from
    infrastructure-config.json's ExposedTargetGroups).

    .PARAMETER ExcludeExposedTargetGroups
    Attach only the primary target group. Use for ephemeral/preview services so
    they never register into shared production target groups.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PrimaryTargetGroupArn,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ContainerName,

        [Parameter(Mandatory)]
        [ValidateRange(1, 65535)]
        [int]$ContainerPort,

        [object[]]$ExposedTargetGroups = @(),

        [switch]$ExcludeExposedTargetGroups
    )

    $specs = @("targetGroupArn=$PrimaryTargetGroupArn,containerName=$ContainerName,containerPort=$ContainerPort")

    if (-not $ExcludeExposedTargetGroups) {
        foreach ($tg in $ExposedTargetGroups) {
            $specs += "targetGroupArn=$($tg.TargetGroupArn),containerName=$($tg.ContainerName),containerPort=$($tg.ContainerPort)"
        }
    }

    return , $specs
}
