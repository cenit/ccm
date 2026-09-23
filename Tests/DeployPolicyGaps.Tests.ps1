# Pester tests for Get-CcmEcsDeployPolicyGaps, the pre-attach IAM policy gate in
# setup-azure-devops-iam.ps1.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot ".." "CCM.psd1") -Force

    function New-TestPolicy {
        param([string[]]$Actions, [string]$Effect = "Allow")
        [pscustomobject]@{
            Version   = "2012-10-17"
            Statement = @(
                [pscustomobject]@{
                    Effect   = $Effect
                    Action   = $Actions
                    Resource = "*"
                }
            )
        }
    }

    # The actions a plain (non-preview, self-built image) deploy needs.
    $script:BaselineActions = @(
        "ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability",
        "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
        "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages",
        "ecs:RegisterTaskDefinition", "ecs:CreateService", "ecs:UpdateService",
        "ecs:DescribeServices", "ecs:RunTask", "ecs:DescribeTasks",
        "secretsmanager:DescribeSecret", "iam:PassRole"
    )
}

Describe "Get-CcmEcsDeployPolicyGaps - baseline deploy" {
    It "reports no gaps when every action is granted explicitly" {
        $gaps = Get-CcmEcsDeployPolicyGaps -PolicyObject (New-TestPolicy $script:BaselineActions)

        $gaps.Missing | Should -BeNullOrEmpty
        $gaps.MissingRecommended | Should -BeNullOrEmpty
    }

    It "requires the ECR layer-upload actions a container push performs" {
        # A policy with only the two ECR actions the old gate checked: this is
        # exactly the policy that passed validation and then failed at push time.
        $policy = New-TestPolicy @(
            "ecr:GetAuthorizationToken", "ecr:PutImage",
            "ecs:RegisterTaskDefinition", "ecs:CreateService", "ecs:UpdateService",
            "ecs:DescribeServices", "secretsmanager:DescribeSecret", "iam:PassRole"
        )
        $gaps = Get-CcmEcsDeployPolicyGaps -PolicyObject $policy

        $gaps.Missing -join "`n" | Should -Match "ecr:InitiateLayerUpload"
        $gaps.Missing -join "`n" | Should -Match "ecr:UploadLayerPart"
        $gaps.Missing -join "`n" | Should -Match "ecr:CompleteLayerUpload"
        $gaps.Missing -join "`n" | Should -Match "ecr:BatchCheckLayerAvailability"
    }

    It "requires ecs:CreateService, which a first deploy calls even without previews" {
        $policy = New-TestPolicy ($script:BaselineActions | Where-Object { $_ -ne "ecs:CreateService" })
        $gaps = Get-CcmEcsDeployPolicyGaps -PolicyObject $policy

        $gaps.Missing -join "`n" | Should -Match "ecs:CreateService"
    }

    It "reports migration actions as recommended, not required" {
        $policy = New-TestPolicy ($script:BaselineActions | Where-Object { $_ -notin @("ecs:RunTask", "ecs:DescribeTasks") })
        $gaps = Get-CcmEcsDeployPolicyGaps -PolicyObject $policy

        $gaps.Missing | Should -BeNullOrEmpty
        $gaps.MissingRecommended -join "`n" | Should -Match "ecs:RunTask"
        $gaps.MissingRecommended -join "`n" | Should -Match "ecs:DescribeTasks"
    }

    It "drops the build-and-push actions when the image comes from another registry" {
        $config = [pscustomobject]@{ ExternalImage = "ghcr.io/vendor/app@sha256:abc" }
        $policy = New-TestPolicy @(
            "ecs:RegisterTaskDefinition", "ecs:CreateService", "ecs:UpdateService",
            "ecs:DescribeServices", "secretsmanager:DescribeSecret", "iam:PassRole"
        )
        $gaps = Get-CcmEcsDeployPolicyGaps -PolicyObject $policy -Config $config

        $gaps.Missing | Should -BeNullOrEmpty
        $gaps.Missing -join "`n" | Should -Not -Match "ecr:"
    }
}

Describe "Get-CcmEcsDeployPolicyGaps - wildcard matching" {
    It "accepts a service-level wildcard" {
        $policy = New-TestPolicy @("ecr:*", "ecs:*", "secretsmanager:*", "iam:*")
        $gaps = Get-CcmEcsDeployPolicyGaps -PolicyObject $policy

        $gaps.Missing | Should -BeNullOrEmpty
    }

    It "accepts a bare '*' administrator policy" {
        $gaps = Get-CcmEcsDeployPolicyGaps -PolicyObject (New-TestPolicy @("*"))

        $gaps.Missing | Should -BeNullOrEmpty
    }

    It "accepts a partial wildcard within the same service" {
        $policy = New-TestPolicy @(
            "ecr:*", "ecs:Register*", "ecs:Create*", "ecs:Update*", "ecs:Desc*",
            "secretsmanager:DescribeSecret", "iam:PassRole"
        )
        $gaps = Get-CcmEcsDeployPolicyGaps -PolicyObject $policy

        $gaps.Missing | Should -BeNullOrEmpty
    }

    It "does not let a wildcard in one service satisfy another service's action" {
        # 'ecs:Desc*' must not be read as granting 'ecr:DescribeImages'.
        $policy = New-TestPolicy ($script:BaselineActions | Where-Object { $_ -ne "ecr:DescribeImages" })
        $gaps = Get-CcmEcsDeployPolicyGaps -PolicyObject ($policy)
        $gaps.MissingRecommended -join "`n" | Should -Match "ecr:DescribeImages"
    }

    It "ignores actions granted by a Deny statement" {
        $policy = New-TestPolicy $script:BaselineActions -Effect "Deny"
        $gaps = Get-CcmEcsDeployPolicyGaps -PolicyObject $policy

        $gaps.Missing.Count | Should -BeGreaterThan 0
    }
}

Describe "Get-CcmEcsDeployPolicyGaps - preview environments" {
    BeforeAll {
        $script:PreviewPathConfig = [pscustomobject]@{
            PreviewEnvironments = [pscustomobject]@{ Enabled = $true; RoutingMode = "path" }
        }
    }

    It "requires the ELB describe/modify/tag actions the preview scripts call" {
        $gaps = Get-CcmEcsDeployPolicyGaps `
            -PolicyObject (New-TestPolicy $script:BaselineActions) `
            -Config $script:PreviewPathConfig
        $missing = $gaps.Missing -join "`n"

        $missing | Should -Match "elasticloadbalancing:DescribeTargetGroups"
        $missing | Should -Match "elasticloadbalancing:DescribeListeners"
        $missing | Should -Match "elasticloadbalancing:DescribeRules"
        $missing | Should -Match "elasticloadbalancing:ModifyRule"
        $missing | Should -Match "elasticloadbalancing:ModifyTargetGroupAttributes"
        $missing | Should -Match "elasticloadbalancing:AddTags"
        $missing | Should -Match "ecs:TagResource"
        $missing | Should -Match "tag:GetResources"
    }

    It "passes when previews are enabled and the ELB actions are granted" {
        $policy = New-TestPolicy ($script:BaselineActions + @(
            "tag:GetResources", "ecs:DeleteService", "ecs:TagResource", "elasticloadbalancing:*"))
        $gaps = Get-CcmEcsDeployPolicyGaps -PolicyObject $policy -Config $script:PreviewPathConfig

        $gaps.Missing | Should -BeNullOrEmpty
    }

    It "does not require preview actions when previews are disabled" {
        $config = [pscustomobject]@{
            PreviewEnvironments = [pscustomobject]@{ Enabled = $false; RoutingMode = "host" }
        }
        $gaps = Get-CcmEcsDeployPolicyGaps -PolicyObject (New-TestPolicy $script:BaselineActions) -Config $config

        $gaps.Missing | Should -BeNullOrEmpty
    }

    It "requires Route 53 actions only in host routing mode" {
        $policy = New-TestPolicy ($script:BaselineActions + @(
            "tag:GetResources", "ecs:DeleteService", "ecs:TagResource", "elasticloadbalancing:*"))

        $pathGaps = Get-CcmEcsDeployPolicyGaps -PolicyObject $policy -Config $script:PreviewPathConfig
        $pathGaps.Missing | Should -BeNullOrEmpty

        $hostConfig = [pscustomobject]@{
            PreviewEnvironments = [pscustomobject]@{ Enabled = $true; RoutingMode = "Host" }
        }
        $hostGaps = Get-CcmEcsDeployPolicyGaps -PolicyObject $policy -Config $hostConfig
        $hostGaps.Missing -join "`n" | Should -Match "route53:ChangeResourceRecordSets"
        $hostGaps.Missing -join "`n" | Should -Match "route53:ListResourceRecordSets"
    }
}

Describe "setup-azure-devops-iam.ps1 uses the shared gate" {
    It "calls Get-CcmEcsDeployPolicyGaps instead of an inline action list" {
        $script = Get-Content (Join-Path $PSScriptRoot ".." "setup-azure-devops-iam.ps1") -Raw

        $script | Should -Match "Get-CcmEcsDeployPolicyGaps"
        $script | Should -Match "Refusing to attach an incomplete IAM policy"
    }
}
