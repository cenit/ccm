function Set-CcmEcsTaskDefinitionOverrides {
    <#
    .SYNOPSIS
    Applies environment and secret overrides to an ECS task definition JSON document.

    .DESCRIPTION
    Updates or appends containerDefinitions[].environment and containerDefinitions[].secrets
    entries for the selected container. Override values must use KEY=VALUE syntax.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TaskDefinitionJson,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ContainerName,

        [string[]]$EnvironmentOverride = @(),

        [string[]]$SecretOverride = @()
    )

    function ConvertFrom-CcmKeyValueOverride {
        param(
            [Parameter(Mandatory)][string]$Override,
            [Parameter(Mandatory)][string]$OverrideType
        )

        $separatorIndex = $Override.IndexOf('=')
        if ($separatorIndex -le 0) {
            throw "$OverrideType override '$Override' must use KEY=VALUE syntax."
        }

        $key = $Override.Substring(0, $separatorIndex).Trim()
        $value = $Override.Substring($separatorIndex + 1)
        if ([string]::IsNullOrWhiteSpace($key)) {
            throw "$OverrideType override '$Override' has an empty key."
        }

        [pscustomobject]@{
            Key   = $key
            Value = $value
        }
    }

    function Set-CcmNamedValue {
        param(
            [Parameter(Mandatory)][object]$Container,
            [Parameter(Mandatory)][string]$PropertyName,
            [Parameter(Mandatory)][string]$ValuePropertyName,
            [Parameter(Mandatory)][object[]]$Overrides
        )

        $items = @()
        if ($Container.PSObject.Properties.Name -contains $PropertyName -and $null -ne $Container.$PropertyName) {
            $items = @($Container.$PropertyName)
        }

        foreach ($override in $Overrides) {
            $existing = $items | Where-Object { $_.name -eq $override.Key } | Select-Object -First 1
            if ($existing) {
                $existing.$ValuePropertyName = $override.Value
            } else {
                $newItem = [pscustomobject]@{ name = $override.Key }
                Add-Member -InputObject $newItem -NotePropertyName $ValuePropertyName -NotePropertyValue $override.Value
                $items += $newItem
            }
        }

        if ($Container.PSObject.Properties.Name -contains $PropertyName) {
            $Container.$PropertyName = $items
        } else {
            Add-Member -InputObject $Container -NotePropertyName $PropertyName -NotePropertyValue $items
        }
    }

    $taskDefinition = $TaskDefinitionJson | ConvertFrom-Json
    $container = @($taskDefinition.containerDefinitions) |
        Where-Object { $_.name -eq $ContainerName } |
        Select-Object -First 1

    if (-not $container) {
        throw "Container '$ContainerName' was not found in the task definition."
    }

    $environmentOverrides = @($EnvironmentOverride | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { ConvertFrom-CcmKeyValueOverride -Override $_ -OverrideType "Environment" })
    $secretOverrides = @($SecretOverride | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { ConvertFrom-CcmKeyValueOverride -Override $_ -OverrideType "Secret" })

    if ($environmentOverrides.Count -gt 0) {
        Set-CcmNamedValue -Container $container -PropertyName "environment" -ValuePropertyName "value" -Overrides $environmentOverrides
    }
    if ($secretOverrides.Count -gt 0) {
        Set-CcmNamedValue -Container $container -PropertyName "secrets" -ValuePropertyName "valueFrom" -Overrides $secretOverrides
    }

    $taskDefinition | ConvertTo-Json -Depth 100
}
