function Resolve-CcmEcsSecretArns {
    <#
    .SYNOPSIS
    Resolves ${..._SECRET_ARN} placeholders in an ECS task definition JSON document.

    .DESCRIPTION
    ECS requires the full Secrets Manager ARN (including the random suffix) in a
    task definition's containerDefinitions[].secrets[].valueFrom. Task definition
    files instead carry a friendly ${FOO_SECRET_ARN} placeholder so they don't need
    per-environment editing. This looks up each placeholder's secret by convention
    (FOO_SECRET_ARN -> "$SecretsPrefix/foo") via `aws secretsmanager describe-secret`
    and substitutes the resolved ARN. Any placeholder that can't be resolved has its
    containing secrets[] entry stripped, since ECS rejects a task definition that
    still references an unresolved ${..._SECRET_ARN} placeholder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TaskDefinitionJson,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SecretsPrefix,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AwsRegion
    )

    $taskDef = $TaskDefinitionJson

    $secretArnPattern = '\$\{(\w+_SECRET_ARN)\}'
    $secretPlaceholders = [regex]::Matches($taskDef, $secretArnPattern) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    foreach ($placeholder in $secretPlaceholders) {
        # Derive secret name from placeholder: AZURE_OPENAI_SECRET_ARN -> azure-openai
        $secretSuffix = ($placeholder -replace '_SECRET_ARN$', '' -replace '_', '-').ToLower()
        $secretName = "$SecretsPrefix/$secretSuffix"
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $secretArn = aws secretsmanager describe-secret --secret-id $secretName --region $AwsRegion --query "ARN" --output text 2>$null
        $ErrorActionPreference = $prevEAP
        if ($LASTEXITCODE -eq 0 -and $secretArn -and $secretArn -ne "None") {
            Write-Host "  Resolved secret: $secretName -> $secretArn" -ForegroundColor Cyan
            $taskDef = $taskDef -replace [regex]::Escape("`${$placeholder}"), $secretArn
        } else {
            Write-Warning "Could not resolve secret '$secretName' for placeholder `${$placeholder}"
            Write-Warning "Ensure the secret exists in Secrets Manager before deploying."
        }
    }

    # Remove secret entries whose ARN placeholders could not be resolved.
    # ECS rejects task definitions containing invalid valueFrom values,
    # so we strip any secrets that still reference ${..._SECRET_ARN}.
    # Only perform the JSON round-trip when there are actually unresolved placeholders.
    $unresolvedSecretPattern = '\$\{\w+_SECRET_ARN\}'
    if ($taskDef -match $unresolvedSecretPattern) {
        $taskDefObj = $taskDef | ConvertFrom-Json
        foreach ($container in $taskDefObj.containerDefinitions) {
            if ($container.secrets) {
                $resolved = @($container.secrets | Where-Object { $_.valueFrom -notmatch $unresolvedSecretPattern })
                $removed  = @($container.secrets | Where-Object { $_.valueFrom -match $unresolvedSecretPattern })
                if ($removed.Count -gt 0) {
                    $removedNames = ($removed | ForEach-Object { $_.name }) -join ', '
                    Write-Warning "Removing unresolved secrets from container '$($container.name)': $removedNames"
                    Write-Warning "The application will start without these environment variables."
                    if ($resolved.Count -gt 0) {
                        $container.secrets = $resolved
                    } else {
                        $container.PSObject.Properties.Remove('secrets')
                    }
                }
            }
        }
        $taskDef = $taskDefObj | ConvertTo-Json -Depth 20
    }

    $taskDef
}
