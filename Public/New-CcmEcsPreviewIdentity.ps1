function New-CcmEcsPreviewIdentity {
    <#
    .SYNOPSIS
    Builds stable AWS-safe names for an ECS PR preview environment.

    .DESCRIPTION
    Produces a preview id, ECS service name, ALB target group name, and path prefix from
    project and pull request metadata. Target group names are shortened with a stable hash
    because AWS limits them to 32 characters.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PullRequestId,

        [string]$SourceBranch = "",

        [string]$PreviewId,

        [string]$PathPrefixTemplate = "/_pr/{id}"
    )

    function ConvertTo-CcmPreviewSlug {
        param([Parameter(Mandatory)][string]$Value)

        $slug = $Value.ToLowerInvariant() -replace '[^a-z0-9-]', '-'
        $slug = $slug -replace '-+', '-'
        $slug = $slug.Trim('-')
        if ([string]::IsNullOrWhiteSpace($slug)) {
            throw "Value '$Value' cannot be converted to an AWS-safe name."
        }
        return $slug
    }

    function Get-CcmPreviewHash {
        param([Parameter(Mandatory)][string]$Value)

        $sha1 = [System.Security.Cryptography.SHA1]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
            $hashBytes = $sha1.ComputeHash($bytes)
            return (($hashBytes | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 8)
        }
        finally {
            $sha1.Dispose()
        }
    }

    function Limit-CcmTargetGroupName {
        param(
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][string]$HashSeed
        )

        $safe = ConvertTo-CcmPreviewSlug $Name
        if ($safe.StartsWith('internal-')) {
            $safe = "p-$safe"
        }

        if ($safe.Length -le 32) {
            return $safe.Trim('-')
        }

        $hash = Get-CcmPreviewHash $HashSeed
        $prefixLength = 32 - $hash.Length - 1
        $prefix = $safe.Substring(0, [Math]::Min($safe.Length, $prefixLength)).Trim('-')
        if ([string]::IsNullOrWhiteSpace($prefix)) {
            $prefix = 'preview'
        }

        $shortName = "$prefix-$hash"
        if ($shortName.StartsWith('internal-')) {
            $shortName = "p-$($shortName.Substring(0, [Math]::Min(30, $shortName.Length)))"
        }

        return $shortName.Trim('-')
    }

    $safeProject = ConvertTo-CcmPreviewSlug $ProjectName
    $safePreviewId = if ($PreviewId) {
        ConvertTo-CcmPreviewSlug $PreviewId
    } else {
        ConvertTo-CcmPreviewSlug $PullRequestId
    }

    $serviceName = "$safeProject-pr-$safePreviewId"
    if ($serviceName.Length -gt 255) {
        $hash = Get-CcmPreviewHash "$ProjectName|$PullRequestId|$SourceBranch"
        $serviceName = "$($serviceName.Substring(0, 246).Trim('-'))-$hash"
    }

    $targetGroupName = Limit-CcmTargetGroupName `
        -Name "$safeProject-pr-$safePreviewId" `
        -HashSeed "$ProjectName|$PullRequestId|$SourceBranch"

    if ($targetGroupName -notmatch '^[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?$') {
        throw "Generated target group name '$targetGroupName' is not valid for AWS."
    }

    $pathPrefix = $PathPrefixTemplate.Replace('{project}', $safeProject).Replace('{id}', $safePreviewId)
    if (-not $pathPrefix.StartsWith('/')) {
        $pathPrefix = "/$pathPrefix"
    }
    $pathPrefix = $pathPrefix.TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($pathPrefix)) {
        $pathPrefix = "/_pr/$safePreviewId"
    }

    [pscustomobject]@{
        PreviewId       = $safePreviewId
        PullRequestId   = $PullRequestId
        ServiceName     = $serviceName
        TargetGroupName = $targetGroupName
        PathPrefix      = $pathPrefix
    }
}
