BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $moduleRoot "CCM.psd1") -Force
}

Describe "ECS preview identity helpers" {
    It "creates AWS-safe deterministic names within target group limits" {
        $identity = New-CcmEcsPreviewIdentity `
            -ProjectName "very-long-enterprise-application-name" `
            -PullRequestId "12345" `
            -SourceBranch "feature/preview-environments"

        $identity.ServiceName | Should -Be "very-long-enterprise-application-name-pr-12345"
        $identity.TargetGroupName.Length | Should -BeLessOrEqual 32
        $identity.TargetGroupName | Should -Match "^[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?$"
        $identity.PathPrefix | Should -Be "/_pr/12345"
    }

    It "avoids target group names that start with the reserved internal prefix" {
        $identity = New-CcmEcsPreviewIdentity `
            -ProjectName "internal-api" `
            -PullRequestId "7"

        $identity.TargetGroupName | Should -Not -Match "^internal-"
        $identity.TargetGroupName.Length | Should -BeLessOrEqual 32
    }

    It "uses a hash suffix when truncation is required to prevent collisions" {
        $first = New-CcmEcsPreviewIdentity `
            -ProjectName "long-shared-prefix-application-alpha" `
            -PullRequestId "99"
        $second = New-CcmEcsPreviewIdentity `
            -ProjectName "long-shared-prefix-application-beta" `
            -PullRequestId "99"

        $first.TargetGroupName | Should -Not -Be $second.TargetGroupName
    }

    It "seeds the truncated target group name with SourceBranch" {
        # Documents why teardown must know the deploy-time branch: with truncation
        # in play, the branch changes the hash and therefore the resource name.
        $withBranch = New-CcmEcsPreviewIdentity `
            -ProjectName "very-long-enterprise-application-name" `
            -PullRequestId "12345" -SourceBranch "refs/heads/feature/a"
        $withoutBranch = New-CcmEcsPreviewIdentity `
            -ProjectName "very-long-enterprise-application-name" `
            -PullRequestId "12345"

        $withBranch.TargetGroupName | Should -Not -Be $withoutBranch.TargetGroupName
    }

    It "reproduces the same target group name for the same branch (teardown round-trip)" {
        $args = @{
            ProjectName   = "very-long-enterprise-application-name"
            PullRequestId = "12345"
            SourceBranch  = "refs/heads/feature/a"
        }
        $atDeploy = New-CcmEcsPreviewIdentity @args
        $atRemoval = New-CcmEcsPreviewIdentity @args

        $atRemoval.TargetGroupName | Should -Be $atDeploy.TargetGroupName
        $atRemoval.ServiceName | Should -Be $atDeploy.ServiceName
    }
}

Describe "Preview teardown resolves the deploy-time target group" {
    # Regression guard: remove-ecs-preview.ps1 used to recompute the identity
    # without SourceBranch, so for truncated names it looked up a target group
    # name that never existed and silently left the real one orphaned.
    BeforeAll { $moduleRoot = Split-Path -Parent $PSScriptRoot }

    It "accepts SourceBranch on remove-ecs-preview.ps1" {
        $removePreview = Get-Command (Join-Path $moduleRoot "remove-ecs-preview.ps1")

        $removePreview.Parameters.Keys | Should -Contain "SourceBranch"
    }

    It "passes SourceBranch into the identity it tears down" {
        $script = Get-Content (Join-Path $moduleRoot "remove-ecs-preview.ps1") -Raw

        $script | Should -Match 'New-CcmEcsPreviewIdentity[\s\S]{0,400}-SourceBranch'
    }

    It "forwards SourceBranch from deploy-ecs-preview.ps1 -ForceRecreate" {
        $script = Get-Content (Join-Path $moduleRoot "deploy-ecs-preview.ps1") -Raw

        $script | Should -Match 'remove-ecs-preview\.ps1"\)[\s\S]{0,300}-SourceBranch'
    }

    It "captures and forwards the SourceBranch tag in cleanup-ecs-previews.ps1" {
        $script = Get-Content (Join-Path $moduleRoot "cleanup-ecs-previews.ps1") -Raw

        $script | Should -Match 'SourceBranch = \$tags\["SourceBranch"\]'
        $script | Should -Match '\$removeScript[\s\S]{0,300}-SourceBranch'
    }
}

Describe "ECS task definition overrides" {
    It "updates existing environment variables and appends new variables on the target container" {
        $taskDefinitionJson = @{
            family = "sample"
            containerDefinitions = @(
                @{
                    name = "web"
                    environment = @(
                        @{ name = "ALLOWED_ORIGINS"; value = "https://prod.example.com" }
                    )
                }
            )
        } | ConvertTo-Json -Depth 10

        $updated = Set-CcmEcsTaskDefinitionOverrides `
            -TaskDefinitionJson $taskDefinitionJson `
            -ContainerName "web" `
            -EnvironmentOverride @(
                "ALLOWED_ORIGINS=https://preview.example.com",
                "FEATURE_FLAG=true"
            ) | ConvertFrom-Json

        $env = @($updated.containerDefinitions[0].environment)
        ($env | Where-Object name -eq "ALLOWED_ORIGINS").value | Should -Be "https://preview.example.com"
        ($env | Where-Object name -eq "FEATURE_FLAG").value | Should -Be "true"
    }

    It "updates existing secrets and appends new secrets on the target container" {
        $taskDefinitionJson = @{
            family = "sample"
            containerDefinitions = @(
                @{
                    name = "web"
                    secrets = @(
                        @{ name = "DATABASE_URL"; valueFrom = "arn:old" }
                    )
                }
            )
        } | ConvertTo-Json -Depth 10

        $updated = Set-CcmEcsTaskDefinitionOverrides `
            -TaskDefinitionJson $taskDefinitionJson `
            -ContainerName "web" `
            -SecretOverride @(
                "DATABASE_URL=arn:new",
                "API_KEY=arn:key"
            ) | ConvertFrom-Json

        $secrets = @($updated.containerDefinitions[0].secrets)
        ($secrets | Where-Object name -eq "DATABASE_URL").valueFrom | Should -Be "arn:new"
        ($secrets | Where-Object name -eq "API_KEY").valueFrom | Should -Be "arn:key"
    }

    It "fails clearly when the target container does not exist" {
        $taskDefinitionJson = @{
            family = "sample"
            containerDefinitions = @(
                @{ name = "web" }
            )
        } | ConvertTo-Json -Depth 10

        {
            Set-CcmEcsTaskDefinitionOverrides `
                -TaskDefinitionJson $taskDefinitionJson `
                -ContainerName "worker" `
                -EnvironmentOverride "FEATURE_FLAG=true"
        } | Should -Throw "*Container 'worker' was not found*"
    }
}

Describe "Resolve-CcmEcsSecretArns" {
    It "resolves a ${..._SECRET_ARN} placeholder by convention (FOO_SECRET_ARN -> prefix/foo)" {
        Mock aws { 'arn:aws:secretsmanager:eu-central-1:123:secret:myproj/db-AbCdEf' } -ModuleName CCM

        $taskDefinitionJson = @{
            family = "sample"
            containerDefinitions = @(
                @{
                    name = "migrations"
                    secrets = @(
                        @{ name = "DATABASE_URL"; valueFrom = '${DB_SECRET_ARN}:DATABASE_URL::' }
                    )
                }
            )
        } | ConvertTo-Json -Depth 10

        $resolved = Resolve-CcmEcsSecretArns `
            -TaskDefinitionJson $taskDefinitionJson `
            -SecretsPrefix "myproj" `
            -AwsRegion "eu-central-1" | ConvertFrom-Json

        $resolved.containerDefinitions[0].secrets[0].valueFrom |
            Should -Be 'arn:aws:secretsmanager:eu-central-1:123:secret:myproj/db-AbCdEf:DATABASE_URL::'
    }

    It "strips a secret whose placeholder cannot be resolved instead of leaving it unresolved" {
        Mock aws { '' } -ModuleName CCM

        $taskDefinitionJson = @{
            family = "sample"
            containerDefinitions = @(
                @{
                    name = "migrations"
                    secrets = @(
                        @{ name = "DATABASE_URL"; valueFrom = '${DB_SECRET_ARN}:DATABASE_URL::' }
                    )
                }
            )
        } | ConvertTo-Json -Depth 10

        $resolved = Resolve-CcmEcsSecretArns `
            -TaskDefinitionJson $taskDefinitionJson `
            -SecretsPrefix "myproj" `
            -AwsRegion "eu-central-1" | ConvertFrom-Json

        $resolved.containerDefinitions[0].PSObject.Properties.Name | Should -Not -Contain "secrets"
    }
}

Describe "ECS preview config schema" {
    BeforeAll {
        $schema = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) "ecs-config.schema.json") -Raw | ConvertFrom-Json
    }

    It "defines preview environments as an optional disabled-by-default block" {
        $schema.properties.PreviewEnvironments | Should -Not -BeNullOrEmpty
        $schema.properties.PreviewEnvironments.properties.Enabled.default | Should -BeFalse
        $schema.properties.PreviewEnvironments.properties.RoutingMode.default | Should -Be "path"
        $schema.properties.PreviewEnvironments.properties.RunMigrations.default | Should -BeFalse
    }

    It "includes cleanup, routing, overrides, and health check settings" {
        $preview = $schema.properties.PreviewEnvironments.properties

        $preview.TtlDays.default | Should -BeGreaterThan 0
        $preview.PathPrefixTemplate.default | Should -Be "/_pr/{id}"
        $preview.EnvironmentOverrides | Should -Not -BeNullOrEmpty
        $preview.SecretOverrides | Should -Not -BeNullOrEmpty
        $preview.HealthCheck | Should -Not -BeNullOrEmpty
    }
}

Describe 'deploy-ecs-preview TaskDefinitionFile passthrough' {
    It 'reads PreviewEnvironments.TaskDefinitionFile and resolves it relative to the project root' {
        $script = Get-Content "$PSScriptRoot/../deploy-ecs-preview.ps1" -Raw
        # The script must read the key and add it to the deploy params hashtable.
        $script | Should -Match 'PreviewEnvironments.*TaskDefinitionFile|Get-CcmPropertyValue \$previewConfig "TaskDefinitionFile"'
        $script | Should -Match '\$deployParams\.TaskDefinitionFile'
    }
}

Describe "Get-CcmEcsLoadBalancerSpecs" {
    BeforeAll {
        $exposed = @(
            [pscustomobject]@{ TargetGroupArn = "arn:tg/nlb-7474"; ContainerName = "neo4j"; ContainerPort = 7474 },
            [pscustomobject]@{ TargetGroupArn = "arn:tg/nlb-6333"; ContainerName = "qdrant"; ContainerPort = 6333 }
        )
    }

    It "builds primary + exposed target group specs for a standard service" {
        $specs = Get-CcmEcsLoadBalancerSpecs `
            -PrimaryTargetGroupArn "arn:tg/primary" `
            -ContainerName "web" `
            -ContainerPort 80 `
            -ExposedTargetGroups $exposed

        $specs | Should -HaveCount 3
        $specs[0] | Should -Be "targetGroupArn=arn:tg/primary,containerName=web,containerPort=80"
        $specs[1] | Should -Be "targetGroupArn=arn:tg/nlb-7474,containerName=neo4j,containerPort=7474"
        $specs[2] | Should -Be "targetGroupArn=arn:tg/nlb-6333,containerName=qdrant,containerPort=6333"
    }

    It "returns only the primary spec when -ExcludeExposedTargetGroups is set (ephemeral/preview services)" {
        $specs = Get-CcmEcsLoadBalancerSpecs `
            -PrimaryTargetGroupArn "arn:tg/pr-9" `
            -ContainerName "web" `
            -ContainerPort 80 `
            -ExposedTargetGroups $exposed `
            -ExcludeExposedTargetGroups

        $specs | Should -HaveCount 1
        $specs[0] | Should -Be "targetGroupArn=arn:tg/pr-9,containerName=web,containerPort=80"
    }

    It "returns only the primary spec when there are no exposed target groups" {
        $specs = Get-CcmEcsLoadBalancerSpecs `
            -PrimaryTargetGroupArn "arn:tg/primary" `
            -ContainerName "web" `
            -ContainerPort 80

        $specs | Should -HaveCount 1
    }
}

Describe "deploy-ecs preview cross-environment isolation" {
    It "never attaches shared ExposedTargetGroups to a service deployed with a TargetGroupArn override" {
        # A TargetGroupArn override marks an ephemeral (PR preview) service. Attaching the
        # shared NLB target groups from infrastructure-config would register the preview's
        # side-car containers (neo4j/qdrant) into PRODUCTION load balancer target groups,
        # letting prod NLB traffic round-robin onto preview databases.
        $script = Get-Content "$PSScriptRoot/../deploy-ecs.ps1" -Raw

        $script | Should -Match 'Get-CcmEcsLoadBalancerSpecs'
        $script | Should -Match 'ExcludeExposedTargetGroups:\$isTargetGroupOverride'
        # The raw inline append of exposed TGs must be gone from both create and update paths.
        $script | Should -Not -Match '\$lbSpecs \+= "targetGroupArn='
    }

    It "captures the TargetGroupArn override flag before the create path clobbers the parameter" {
        # PowerShell variable names are case-insensitive: the create path's
        # `$targetGroupArn = if ($TargetGroupArn) ... else infra` assignment overwrites
        # the parameter, so [bool]$TargetGroupArn is always true after it. The override
        # flag must therefore be captured before that line runs.
        $script = Get-Content "$PSScriptRoot/../deploy-ecs.ps1" -Raw

        $captureIdx = $script.IndexOf('$isTargetGroupOverride = [bool]$TargetGroupArn')
        $clobberIdx = $script.IndexOf('$targetGroupArn = if ($TargetGroupArn)')

        $captureIdx | Should -BeGreaterThan -1
        $clobberIdx | Should -BeGreaterThan -1
        $captureIdx | Should -BeLessThan $clobberIdx
    }
}

Describe "ECS preview script surfaces" {
    BeforeAll {
        $moduleRoot = Split-Path -Parent $PSScriptRoot
    }

    It "exposes deploy-ecs hooks needed by preview deployments" {
        $command = Get-Command (Join-Path $moduleRoot "deploy-ecs.ps1")

        $command.Parameters.Keys | Should -Contain "TargetGroupArn"
        $command.Parameters.Keys | Should -Contain "EnvironmentOverride"
        $command.Parameters.Keys | Should -Contain "SecretOverride"
        $command.Parameters.Keys | Should -Contain "CorsAllowedOrigins"
    }

    It "preserves explicit PR image tags passed by preview deployments" {
        $script = Get-Content (Join-Path $moduleRoot "deploy-ecs.ps1") -Raw

        $script | Should -Match 'Using explicit image tag: \$ImageTag'
        $script | Should -Match 'if \(-not \$ExternalImage -and -not \$ImageTag\)'
    }

    It "provides preview deploy, remove, and cleanup scripts with CI-friendly parameters" {
        $deployPreview = Get-Command (Join-Path $moduleRoot "deploy-ecs-preview.ps1")
        $removePreview = Get-Command (Join-Path $moduleRoot "remove-ecs-preview.ps1")
        $cleanupPreviews = Get-Command (Join-Path $moduleRoot "cleanup-ecs-previews.ps1")

        $deployPreview.Parameters.Keys | Should -Contain "PullRequestId"
        $deployPreview.Parameters.Keys | Should -Contain "ImageTag"
        $deployPreview.Parameters.Keys | Should -Contain "SkipBuild"
        $deployPreview.Parameters.Keys | Should -Contain "ForceRecreate"
        $removePreview.Parameters.Keys | Should -Contain "PreviewId"
        $cleanupPreviews.Parameters.Keys | Should -Contain "AzureDevOpsToken"
        $cleanupPreviews.Parameters.Keys | Should -Contain "DryRun"
    }

    It "keeps listener-rule conditions/actions as JSON arrays for AWS CLI file inputs" {
        $script = Get-Content (Join-Path $moduleRoot "deploy-ecs-preview.ps1") -Raw

        $script | Should -Match "ConvertTo-Json -InputObject"
        $script | Should -Match "Get-CcmNextListenerPriority"
        $script | Should -Match "RulePriorityBandSize"
    }
}
