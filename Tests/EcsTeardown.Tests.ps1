# Pester tests for Get-CcmEcsTeardownPlan and remove-aws-infrastructure.ps1.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot ".." "CCM.psd1") -Force
    $script:ScriptPath = Join-Path $PSScriptRoot ".." "remove-aws-infrastructure.ps1"
}

Describe "Get-CcmEcsTeardownPlan - resource set" {
    It "derives every name from the project name" {
        $plan = Get-CcmEcsTeardownPlan -ProjectName "my-app"
        foreach ($item in $plan) {
            $item.Name | Should -Match '^(my-app|/ecs/my-app)'
        }
    }

    It "includes the core substrate by default" {
        $kinds = (Get-CcmEcsTeardownPlan -ProjectName "my-app").Kind
        $kinds | Should -Contain "EcsService"
        $kinds | Should -Contain "Alb"
        $kinds | Should -Contain "TargetGroup"
        $kinds | Should -Contain "EcsCluster"
        $kinds | Should -Contain "IamRole"
        $kinds | Should -Contain "SecurityGroup"
    }

    It "omits ECR and log groups unless explicitly requested" {
        $kinds = (Get-CcmEcsTeardownPlan -ProjectName "my-app").Kind
        $kinds | Should -Not -Contain "EcrRepository"
        $kinds | Should -Not -Contain "LogGroup"
    }

    It "includes ECR only with -IncludeEcr" {
        $plan = Get-CcmEcsTeardownPlan -ProjectName "my-app" -IncludeEcr
        ($plan | Where-Object Kind -eq "EcrRepository").Name | Should -Be "my-app"
    }

    It "includes both log groups with -IncludeLogs" {
        $names = (Get-CcmEcsTeardownPlan -ProjectName "my-app" -IncludeLogs |
            Where-Object Kind -eq "LogGroup").Name
        $names | Should -Contain "/ecs/my-app"
        $names | Should -Contain "/ecs/my-app-migrations"
    }

    It "includes the Route 53 record only when a custom domain is given" {
        (Get-CcmEcsTeardownPlan -ProjectName "my-app").Kind | Should -Not -Contain "Route53Record"

        $plan = Get-CcmEcsTeardownPlan -ProjectName "my-app" -CustomDomainName "my-app.example.com"
        ($plan | Where-Object Kind -eq "Route53Record").Name | Should -Be "my-app.example.com"
    }

    It "makes the Route 53 record the only name not derived from the project name" {
        # Deliberately a domain that does not happen to start with the project
        # name, so a naive prefix check can't accidentally call it "derived".
        $plan = Get-CcmEcsTeardownPlan -ProjectName "my-app" -CustomDomainName "example.com" -IncludeEcr -IncludeLogs
        $nonDerived = @($plan | Where-Object { $_.Name -notmatch '^(my-app|/ecs/my-app)' })
        $nonDerived.Count | Should -Be 1
        $nonDerived[0].Kind | Should -Be "Route53Record"
        $nonDerived[0].Name | Should -Be "example.com"
    }

    It "lowercases the Route 53 record name" {
        # Route 53 stores record names lowercased, and the JMESPath match in
        # remove-aws-infrastructure.ps1 ("Name=='<value>.'") is
        # case-sensitive: an uppercase CustomDomainName would report a
        # still-live record as "Absent, skipped" and leave a dangling alias
        # pointing at a deleted load balancer.
        $plan = Get-CcmEcsTeardownPlan -ProjectName "my-app" -CustomDomainName "My-App.Example.COM"
        ($plan | Where-Object Kind -eq "Route53Record").Name | Should -BeExactly "my-app.example.com"
    }
}

Describe "Get-CcmEcsTeardownPlan - ProjectName validation" {
    It "rejects a ProjectName containing a comma" {
        # The exact injection this guards: AWS CLI shorthand filters are
        # "Name=key,Values=v1,v2,...", so a comma in ProjectName can append an
        # attacker- or typo-controlled extra filter value.
        { Get-CcmEcsTeardownPlan -ProjectName "shared-vpce-sg,x" } | Should -Throw
    }

    It "rejects a ProjectName containing an asterisk" {
        # EC2 filter values accept "*" as a wildcard; an unrestricted
        # ProjectName could match every security group in the region.
        # (Not "*,x": that also contains a comma, so it would pass against a
        # pattern that only banned commas and would not isolate this case.)
        { Get-CcmEcsTeardownPlan -ProjectName "my-app*" } | Should -Throw
    }

    It "accepts an ordinary dash-lowercase ProjectName" {
        { Get-CcmEcsTeardownPlan -ProjectName "my-app" } | Should -Not -Throw
    }

    It "rejects a ProjectName with a trailing newline" {
        # Same '$' vs '\z' gap as the CustomDomainName trailing-newline case
        # below: a naive '...$' pattern would accept "my-app`n" because .NET
        # regex '$' matches immediately before a trailing newline too.
        { Get-CcmEcsTeardownPlan -ProjectName "my-app`n" } | Should -Throw
    }
}

Describe "Get-CcmEcsTeardownPlan - CustomDomainName validation" {
    It "rejects a CustomDomainName containing a single quote" {
        # The exact injection this guards: remove-aws-infrastructure.ps1
        # interpolates CustomDomainName unescaped into a JMESPath --query
        # expression ("...Name=='<value>.'"). A single quote closes that
        # string early, so "x' || 'a'=='a" would broaden the query to match
        # (and later delete) every record set in the zone.
        { Get-CcmEcsTeardownPlan -ProjectName "my-app" -CustomDomainName "x' || 'a'=='a" } | Should -Throw
    }

    It "rejects a CustomDomainName with a trailing newline" {
        # In .NET regex, an un-anchored '$' also matches immediately before a
        # trailing newline, so "my-app.example.com`n" would slip past a
        # pattern ending in '$'. A value like that would build a query
        # matching nothing, and a still-live record would then be reported as
        # absent - the pattern uses \z (absolute end of string) instead.
        { Get-CcmEcsTeardownPlan -ProjectName "my-app" -CustomDomainName "my-app.example.com`n" } | Should -Throw
    }

    It "accepts an ordinary hostname" {
        { Get-CcmEcsTeardownPlan -ProjectName "my-app" -CustomDomainName "my-app.example.com" } | Should -Not -Throw
    }

    It "accepts an explicitly empty CustomDomainName as 'no custom domain'" {
        # remove-aws-infrastructure.ps1 always binds -CustomDomainName,
        # including as $null (coerced to "") when ecs-config.json has none -
        # that must not throw, or every project without a custom domain
        # would fail here.
        { Get-CcmEcsTeardownPlan -ProjectName "my-app" -CustomDomainName "" } | Should -Not -Throw
        (Get-CcmEcsTeardownPlan -ProjectName "my-app" -CustomDomainName "").Kind | Should -Not -Contain "Route53Record"
    }
}

Describe "Get-CcmEcsTeardownPlan - shared resources" {
    It "never emits a VPC, subnet or endpoint security group" {
        # The exact failure this guards: a teardown that deleted "the security
        # groups named in the config" would sever VPC-endpoint connectivity for
        # every other project in a shared account.
        $shared = @(
            "vpc-0000000000000dead", "subnet-0000000000000aaaa",
            "subnet-0000000000000bbbb", "subnet-0000000000000cccc",
            "sg-0000000000000shared"
        )
        $plan = Get-CcmEcsTeardownPlan -ProjectName "my-app" -IncludeEcr -IncludeLogs

        foreach ($id in $shared) {
            $plan.Name | Should -Not -Contain $id
        }
        $plan.Name | Where-Object { $_ -match '^(vpc|subnet)-' } | Should -BeNullOrEmpty
    }

    It "accepts no parameter that could carry a shared resource id" {
        # Structural guarantee: the function cannot delete what it cannot be told about.
        $params = (Get-Command Get-CcmEcsTeardownPlan).Parameters.Keys
        $params | Should -Not -Contain "VpcId"
        $params | Should -Not -Contain "SubnetIds"
        $params | Should -Not -Contain "VpcEndpointSecurityGroupId"
    }
}

Describe "Get-CcmEcsTeardownPlan - ordering" {
    It "returns items in ascending dependency order" {
        $orders = (Get-CcmEcsTeardownPlan -ProjectName "my-app" -IncludeEcr -IncludeLogs).Order
        $sorted = $orders | Sort-Object
        ($orders -join ",") | Should -Be ($sorted -join ",")
    }

    It "deletes the service before the cluster that contains it" {
        $plan = Get-CcmEcsTeardownPlan -ProjectName "my-app"
        $service = ($plan | Where-Object Kind -eq "EcsService").Order
        $cluster = ($plan | Where-Object Kind -eq "EcsCluster").Order
        $service | Should -BeLessThan $cluster
    }

    It "deletes listeners before the load balancer, and the load balancer before its target group" {
        $plan = Get-CcmEcsTeardownPlan -ProjectName "my-app"
        $listeners = ($plan | Where-Object Kind -eq "AlbListeners").Order
        $alb = ($plan | Where-Object Kind -eq "Alb").Order
        $tg = ($plan | Where-Object Kind -eq "TargetGroup").Order

        $listeners | Should -BeLessThan $alb
        $alb | Should -BeLessThan $tg
    }

    It "deletes security groups last of the AWS resources" {
        # An SG still referenced by a live ENI fails with DependencyViolation.
        $plan = Get-CcmEcsTeardownPlan -ProjectName "my-app" -IncludeEcr -IncludeLogs
        $sg = ($plan | Where-Object Kind -eq "SecurityGroup" | Select-Object -First 1).Order
        $others = ($plan | Where-Object { $_.Kind -notin @("SecurityGroup", "Route53Record") }).Order |
            Measure-Object -Maximum

        $sg | Should -BeGreaterThan $others.Maximum
    }
}

Describe "remove-aws-infrastructure.ps1" {
    It "parses as valid PowerShell" {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$null, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }

    It "supports -WhatIf with a high confirm impact" {
        $text = Get-Content $script:ScriptPath -Raw
        $text | Should -Match 'SupportsShouldProcess'
        $text | Should -Match "ConfirmImpact\s*=\s*'High'"
    }

    It "refuses when the project name disagrees with the config" {
        $text = Get-Content $script:ScriptPath -Raw
        $text | Should -Match 'does not match'
    }

    It "uses the shared plan function rather than an inline resource list" {
        (Get-Content $script:ScriptPath -Raw) | Should -Match 'Get-CcmEcsTeardownPlan'
    }

    It "reports a resource that failed to delete as FAILED, still present - not absent" {
        # This is the line operators read during the real teardown acceptance
        # run. Cheap source-grep rather than an AWS mock: it confirms the
        # distinct "still present" wording survives, so a failed delete can
        # never be misread as a clean absence.
        (Get-Content $script:ScriptPath -Raw) | Should -Match 'FAILED, still present'
    }

    It "resets the per-item error flag before each resource, so one item's failure can't taint the next" {
        # A single occurrence would also pass with the per-item reset deleted
        # (the regression this test exists to catch), since the top-level
        # declaration alone still matches '$script:HadItemError = $false'.
        # Requiring two occurrences - the declaration before the loop, and
        # the reset inside it - is what actually distinguishes them.
        $matches = [regex]::Matches((Get-Content $script:ScriptPath -Raw), '\$script:HadItemError\s*=\s*\$false')
        $matches.Count | Should -BeGreaterOrEqual 2
    }

    It "never deletes zone-owned NS or SOA record sets" {
        # A project serving the zone apex (setup-route53-zone.ps1
        # -IncludeApex) has CustomDomainName equal to the apex, where the
        # deliberate name-only record match also returns the zone's own NS
        # and SOA. Route 53 refuses to delete those at the apex, so
        # attempting it would end every apex teardown in spurious FAILED
        # lines for record sets nobody can or should delete - they must be
        # filtered out by Type before the delete loop.
        $text = Get-Content $script:ScriptPath -Raw
        $text | Should -Match "'NS'"
        $text | Should -Match "'SOA'"
    }
}

Describe "remove-aws-infrastructure.ps1 - out-of-scope leftover scan" {
    BeforeAll {
        $script:Text = Get-Content $script:ScriptPath -Raw
    }

    It "probes for the NLB and its billing after the teardown" {
        # The plan deliberately never covers the NLB, but an NLB left behind
        # keeps billing and its ENIs can block the ALB security group's
        # delete - the script must at least LOOK for it and say so.
        $script:Text | Should -Match '\$ProjectName-nlb'
    }

    It "probes for the Aurora cluster, config-declared DynamoDB tables and project secrets" {
        $script:Text | Should -Match 'describe-db-clusters'
        $script:Text | Should -Match 'describe-table'
        $script:Text | Should -Match 'list-secrets'
    }

    It "reports leftovers as out of scope and still present, never deletes them" {
        # Data-bearing resources (DynamoDB, Aurora, secrets) and the NLB are
        # reported for manual attention only - no rds/dynamodb/secretsmanager
        # delete verb may appear anywhere in this script.
        $script:Text | Should -Match 'STILL PRESENT \(out of scope\)'
        $script:Text | Should -Not -Match 'delete-db-cluster'
        $script:Text | Should -Not -Match 'delete-table'
        $script:Text | Should -Not -Match 'delete-secret'
    }

    It "makes zero AWS calls under -WhatIf, leftover scan included" {
        # The dry-run contract this PR advertises: -WhatIf never makes a
        # single AWS call. The scan is read-only, which makes it tempting to
        # run it anyway - this test is what keeps it gated.
        $sandbox = Join-Path ([IO.Path]::GetTempPath()) ("ccm-whatif-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $sandbox | Out-Null
        try {
            $marker = Join-Path $sandbox "aws-was-called"
            # An ExternalScript outranks an Application in command discovery,
            # so an aws.ps1 prepended to PATH intercepts every `aws` call.
            # The marker write MUST be raw .NET IO: the caller's -WhatIf
            # propagates into this stub, and a ShouldProcess-aware cmdlet
            # like Set-Content would silently skip the write - leaving a
            # stub that can never observe anything (the same trap as the
            # 2>$file redirection documented in the PR).
            Set-Content -LiteralPath (Join-Path $sandbox "aws.ps1") -Value @"
[IO.File]::AppendAllText('$marker', ([string]`$args) + [Environment]::NewLine)
exit 1
"@
            @{
                ProjectName         = "my-app"
                AwsRegion           = "eu-central-1"
                CustomDomainName    = "my-app.example.com"
                Route53HostedZoneId = "Z00000000000000000000"
                EnableNlb           = $true
                EnableAurora        = $true
                EnableDynamoDb      = $true
                DynamoDbTables      = @(@{ Name = "my-app-data"; PartitionKey = @{ Name = "id" } })
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $sandbox "ecs-config.json")

            $childCmd = "`$env:PATH = '$sandbox' + [IO.Path]::PathSeparator + `$env:PATH; " +
                "& '$($script:ScriptPath)' -ProjectName my-app -ConfigFile '$(Join-Path $sandbox "ecs-config.json")' -IncludeEcr -IncludeLogs -WhatIf"
            $output = & pwsh -NoProfile -NonInteractive -Command $childCmd 2>&1 | Out-String

            $LASTEXITCODE | Should -Be 0 -Because "a -WhatIf run must succeed without AWS access. Output: $output"
            Test-Path $marker | Should -BeFalse -Because "a -WhatIf run must not make a single AWS call. Output: $output"
        } finally {
            Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
        }
    }
}

Describe "CCM.psd1 manifest registration" {
    It "exports Get-CcmEcsTeardownPlan and lists its file" {
        $manifest = Get-Content (Join-Path $PSScriptRoot ".." "CCM.psd1") -Raw
        $manifest | Should -Match "'Get-CcmEcsTeardownPlan'"
        $manifest | Should -Match "Public\\Get-CcmEcsTeardownPlan\.ps1"
    }
}

Describe "remove-aws-infrastructure.ps1 - behavioural, against a stub AWS CLI" {
    # These run the real script in a child pwsh with an aws.ps1 stub
    # shadowing the real CLI on PATH (an ExternalScript outranks an
    # Application in command discovery). A .ps1 rather than a .cmd is
    # load-bearing twice over: the script's JMESPath --query arguments
    # contain '|', which PowerShell passes to a .cmd unquoted and cmd.exe
    # then parses as a pipe; and the stub's stderr must go through
    # PowerShell's error stream (Write-Error, with ErrorActionPreference
    # reset to Continue - the caller's 'Stop' propagates in) for the
    # script's `2>$errFile` capture to see it, where [Console]::Error would
    # bypass redirection and make every error look empty.
    #
    # The stub models the world after a successful teardown: every lookup
    # answers NotFound (or, for the tests below, a chosen failure), except
    # route53 list-resource-record-sets, which answers exit 0 with an empty
    # list - the shared hosted zone outlives every project, so a zone-level
    # error is deliberately NOT treated as record absence by the script.
    BeforeAll {
        function script:New-TeardownSandbox {
            param([Parameter(Mandatory)][string]$StubStdErr)
            $sandbox = Join-Path ([IO.Path]::GetTempPath()) ("ccm-stub-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $sandbox | Out-Null
            Set-Content -LiteralPath (Join-Path $sandbox "aws.ps1") -Value @"
`$ErrorActionPreference = 'Continue'
[IO.File]::AppendAllText('$(Join-Path $sandbox 'aws-calls.log')', ([string]`$args) + [Environment]::NewLine)
if (([string]`$args) -match 'list-resource-record-sets') { '[]'; exit 0 }
Write-Error '$StubStdErr'
exit 254
"@
            @{
                ProjectName         = "my-app"
                AwsRegion           = "eu-central-1"
                CustomDomainName    = "my-app.example.com"
                Route53HostedZoneId = "Z00000000000000000000"
                EnableNlb           = $true
                EnableAurora        = $true
                EnableDynamoDb      = $true
                DynamoDbTables      = @(@{ Name = "my-app-data"; PartitionKey = @{ Name = "id" } })
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $sandbox "ecs-config.json")
            return $sandbox
        }

        function script:Invoke-TeardownWithStub {
            param([Parameter(Mandatory)][string]$Sandbox)
            $childCmd = "`$env:PATH = '$Sandbox' + [IO.Path]::PathSeparator + `$env:PATH; " +
                "& '$($script:ScriptPath)' -ProjectName my-app -ConfigFile '$(Join-Path $Sandbox "ecs-config.json")' -IncludeEcr -IncludeLogs -Confirm:`$false"
            $output = & pwsh -NoProfile -NonInteractive -Command $childCmd 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
        }
    }

    It "treats NotFound everywhere as a fully retired stack: all absent, no leftovers, exit 0" {
        # The safe re-run the docs promise: a second REAL run after teardown
        # finds nothing, and that - not -WhatIf - is the proof of completion.
        $sandbox = New-TeardownSandbox -StubStdErr "An error occurred (NotFound) when calling the operation"
        try {
            $run = Invoke-TeardownWithStub -Sandbox $sandbox
            $run.ExitCode | Should -Be 0 -Because "a clean retirement must not signal failure. Output: $($run.Output)"
            $run.Output | Should -Match 'Absent, skipped: Route53Record'
            $run.Output | Should -Not -Match 'FAILED, still present'
            $run.Output | Should -Match 'None found\.'
            $run.Output | Should -Match 'Nothing remained - this stack is already fully retired\.'
        } finally {
            Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
        }
    }

    It "treats AccessDenied everywhere as failure: FAILED lines, no all-clear, non-zero exit" {
        # An expired SSO session must never look like a retired stack - and
        # the failure must also reach anything scripting this (CI, a
        # runbook): text alone is not machine-readable, the exit code is.
        $sandbox = New-TeardownSandbox -StubStdErr "An error occurred (AccessDenied) when calling the operation: not authorized"
        try {
            $run = Invoke-TeardownWithStub -Sandbox $sandbox
            $run.Output | Should -Match 'FAILED, still present'
            $run.Output | Should -Match 'NOT confirmed fully retired'
            $run.Output | Should -Not -Match 'Nothing remained'
            $run.ExitCode | Should -Not -Be 0 -Because "a teardown that failed must exit non-zero, exactly as setup-azure-devops-iam.ps1 -Remove does. Output: $($run.Output)"
        } finally {
            Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
        }
    }
}

Describe "remove-aws-infrastructure.ps1 - Route 53 record name resolution" {
    # setup-aws-infrastructure.ps1 does not require ecs-config.json to carry
    # CustomDomainName: with Route53HostedZoneId and ParentDomain both present
    # and CustomDomainName absent, it DERIVES "<ProjectName>.<ParentDomain>"
    # and creates the record under that name. That is the recommended shape -
    # storing the key hardcodes a hostname that goes stale on a rename - so a
    # teardown that only READ the key planned no Route53Record at all for
    # those projects: no plan entry, no FAILED line, just a clean-sweep report
    # with the record still live and pointing at a deleted load balancer.
    #
    # These run the real script in a child pwsh against an `aws` stub that
    # answers NotFound to everything (an already-retired stack) and an empty
    # list to route53 list-resource-record-sets, so the printed plan and the
    # closing summary are the observable behaviour - not a source grep, which
    # could not tell a derivation that runs from one that is merely written
    # down.
    BeforeAll {
        function script:Invoke-TeardownWithConfig {
            param([Parameter(Mandatory)][hashtable]$Config)
            $sandbox = Join-Path ([IO.Path]::GetTempPath()) ("ccm-domain-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $sandbox | Out-Null
            try {
                Set-Content -LiteralPath (Join-Path $sandbox "aws.ps1") -Value @"
`$ErrorActionPreference = 'Continue'
if (([string]`$args) -match 'list-resource-record-sets') { '[]'; exit 0 }
Write-Error 'An error occurred (NotFound) when calling the operation'
exit 254
"@
                $configPath = Join-Path $sandbox "ecs-config.json"
                $Config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath
                $childCmd = "`$env:PATH = '$sandbox' + [IO.Path]::PathSeparator + `$env:PATH; " +
                    "& '$($script:ScriptPath)' -ProjectName my-app -ConfigFile '$configPath' -Confirm:`$false"
                $output = & pwsh -NoProfile -NonInteractive -Command $childCmd 2>&1 | Out-String
                return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
            } finally {
                Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
            }
        }
    }

    # No angle brackets in these It names: Pester treats "<Name>" in a test
    # name as a -ForEach/-TestCases placeholder and expands it away, so
    # "derives <ProjectName>.<ParentDomain>" would report as "derives .".
    It "derives ProjectName.ParentDomain when the config has a zone and parent domain but no CustomDomainName" {
        # The bug this fix exists for: without the derivation the record below
        # never even reaches the plan, and the run still ends "Nothing
        # remained - this stack is already fully retired."
        $run = Invoke-TeardownWithConfig -Config @{
            ProjectName         = "my-app"
            AwsRegion           = "eu-central-1"
            ParentDomain        = "example.com"
            Route53HostedZoneId = "Z00000000000000000000"
        }
        $run.Output | Should -Match "Route53Record\s+my-app\.example\.com" -Because "the derived name must appear in the printed plan. Output: $($run.Output)"
        $run.Output | Should -Match "Route53Record 'my-app\.example\.com'" -Because "the derived record must actually be processed, not just printed. Output: $($run.Output)"
        $run.ExitCode | Should -Be 0 -Because "a retired stack must not signal failure. Output: $($run.Output)"
    }

    It "prefers an explicit CustomDomainName over the derived one" {
        # Derivation is the fallback, never an override: a project that pins a
        # hostname unrelated to its name must still tear down that hostname.
        $run = Invoke-TeardownWithConfig -Config @{
            ProjectName         = "my-app"
            AwsRegion           = "eu-central-1"
            CustomDomainName    = "www.example.com"
            ParentDomain        = "example.com"
            Route53HostedZoneId = "Z00000000000000000000"
        }
        $run.Output | Should -Match "Route53Record\s+www\.example\.com"
        $run.Output | Should -Not -Match "my-app\.example\.com" -Because "the derived name must not be planned alongside, or instead of, the explicit one. Output: $($run.Output)"
    }

    It "derives nothing when ParentDomain is absent" {
        # Same gate as setup's ($Route53HostedZoneId -and $ParentDomain): with
        # no ParentDomain, setup created no record, so there is no derived
        # name to look for.
        $run = Invoke-TeardownWithConfig -Config @{
            ProjectName         = "my-app"
            AwsRegion           = "eu-central-1"
            Route53HostedZoneId = "Z00000000000000000000"
        }
        $run.Output | Should -Not -Match "Route53Record"
        $run.Output | Should -Match "Nothing remained"
        $run.ExitCode | Should -Be 0 -Because "Output: $($run.Output)"
    }

    It "derives nothing when Route53HostedZoneId is absent" {
        # The other half of the same gate. Setup skips the record entirely
        # when the zone id is missing (it says so and points at
        # setup-route53-zone.ps1), and the teardown's Route53Record branch
        # cannot even look one up without a zone id - it reports "cannot
        # check/delete ... no Route53HostedZoneId in config" and fails the
        # run. Deriving here would turn every correct teardown of such a
        # project into a permanent red failure over a record that never
        # existed.
        $run = Invoke-TeardownWithConfig -Config @{
            ProjectName  = "my-app"
            AwsRegion    = "eu-central-1"
            ParentDomain = "example.com"
        }
        $run.Output | Should -Not -Match "Route53Record"
        $run.Output | Should -Match "Nothing remained"
        $run.ExitCode | Should -Be 0 -Because "Output: $($run.Output)"
    }

    It "fails loudly and withholds the all-clear when the derived name would violate the plan function's charset" {
        # ParentDomain is operator-supplied and unvalidated, so the derived
        # name can fail Get-CcmEcsTeardownPlan's ValidatePattern - the pattern
        # that stops a single quote closing the JMESPath string in
        # "...Name=='<value>.'" and widening the query to every record set in
        # the zone. Binding it anyway throws a parameter-binding error that
        # reads as a crash rather than a diagnosis; dropping it silently
        # leaves the record behind under a clean-sweep report. This script
        # never prints a false all-clear, so it must do neither.
        $run = Invoke-TeardownWithConfig -Config @{
            ProjectName         = "my-app"
            AwsRegion           = "eu-central-1"
            ParentDomain        = "x' || 'a'=='a"
            Route53HostedZoneId = "Z00000000000000000000"
        }
        $run.Output | Should -Match "ERROR: cannot derive the Route 53 record name" -Because "Output: $($run.Output)"
        $run.Output | Should -Not -Match "Route53Record" -Because "an unusable name must not be planned. Output: $($run.Output)"
        $run.Output | Should -Not -Match "Nothing remained" -Because "every other resource is absent, so only the error may withhold the all-clear. Output: $($run.Output)"
        $run.Output | Should -Match "NOT confirmed fully retired"
        $run.ExitCode | Should -Not -Be 0 -Because "anything scripting this (CI, a retirement runbook) reads the exit code, not the red text. Output: $($run.Output)"
    }

    It "checks the derived name against the same pattern Get-CcmEcsTeardownPlan enforces" {
        # One rule, two copies: the ValidatePattern attribute (which throws)
        # and the script's pre-check (which diagnoses). If they drift, the
        # pre-check stops catching what the attribute rejects and the crash it
        # exists to prevent comes back - so require the script to carry the
        # attribute's pattern verbatim.
        $planPattern = @((Get-Command Get-CcmEcsTeardownPlan).Parameters['CustomDomainName'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidatePatternAttribute] })[0].RegexPattern
        (Get-Content $script:ScriptPath -Raw).Contains($planPattern) |
            Should -BeTrue -Because "the teardown script must pre-check against '$planPattern', the plan function's own pattern"
    }
}

Describe "setup-azure-devops-iam.ps1 -Remove" {
    BeforeAll {
        $script:IamScript = Join-Path $PSScriptRoot ".." "setup-azure-devops-iam.ps1"
        $script:IamText = Get-Content $script:IamScript -Raw
    }

    It "declares a Remove switch" {
        $script:IamText | Should -Match '\[switch\]\$Remove'
    }

    It "documents it" {
        $script:IamText | Should -Match '\.PARAMETER Remove'
    }

    It "deletes access keys before the user, which IAM requires" {
        $script:IamText | Should -Match 'list-access-keys'
        $script:IamText | Should -Match 'delete-access-key'
    }

    It "detaches the policy before deleting it" {
        $script:IamText | Should -Match 'detach-user-policy'
        $script:IamText | Should -Match 'delete-user'
    }

    It "also removes an inline policy, independently of the managed-policy path" {
        # The policy may have been attached via put-user-policy (inline, for
        # a policy small enough to fit under IAM's inline size limit) rather
        # than attach-user-policy (customer-managed) - which one was used
        # depends on the policy's size at creation time. Only handling the
        # managed path leaves an inline-attached policy on the user, which
        # makes the final delete-user fail.
        $script:IamText | Should -Match 'list-user-policies'
        $script:IamText | Should -Match 'delete-user-policy'
    }

    It "only reports success once nothing has failed" {
        # "Removal complete." must be gated on an error tracker, not printed
        # unconditionally - the same "FAILED, still present" honesty
        # principle remove-aws-infrastructure.ps1 uses for its own summary.
        $script:IamText | Should -Match '\$hadRemovalError'
        $script:IamText | Should -Match 'if\s*\(\s*\$hadRemovalError\s*\)'
        $script:IamText | Should -Match 'FAILED, still present'
        $script:IamText | Should -Match 'Removal complete'
    }

    It "supports ShouldProcess" {
        $script:IamText | Should -Match 'SupportsShouldProcess'
    }

    It "declares removal high-impact, so -Remove prompts for confirmation by default" {
        # remove-aws-infrastructure.ps1 already declares ConfirmImpact 'High'
        # and prompts per resource; deleting the deploy user and its
        # credentials is no less destructive, and an asymmetric default
        # (one teardown prompts, the other silently proceeds) is exactly how
        # an operator gets surprised. Unattended runs opt out explicitly
        # with -Confirm:$false.
        $script:IamText | Should -Match "ConfirmImpact\s*=\s*'High'"
    }

    It "parses as valid PowerShell" {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $script:IamScript, [ref]$null, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }
}

Describe "setup-azure-devops-iam.ps1 -Remove - behavioural, against a stub AWS CLI" {
    # Same stub-on-PATH technique as the teardown block above (see its comment
    # for why the stub is a .ps1 and why its stderr goes through Write-Error),
    # but driving the CONFIRMATION PROMPTS rather than AWS failures.
    #
    # A declined prompt is the one outcome the script's $hadRemovalError
    # tracker cannot see: nothing failed, so the tracker stays $false and the
    # run used to fall through to "Removal complete." while the deploy
    # identity - and its long-lived static access key - was still live.
    #
    # Answers are piped on stdin, which a ShouldProcess prompt reads when the
    # child is NOT started with -NonInteractive (with it, the prompt errors
    # instead of being answered). The stub models a user that really exists
    # and owns one access key, so there are exactly two prompts to answer:
    # delete the access key, then delete the user.
    BeforeAll {
        $script:IamScriptPath = Join-Path $PSScriptRoot ".." "setup-azure-devops-iam.ps1"

        function script:New-IamSandbox {
            $sandbox = Join-Path ([IO.Path]::GetTempPath()) ("ccm-iam-stub-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $sandbox | Out-Null
            Set-Content -LiteralPath (Join-Path $sandbox "aws.ps1") -Value @"
`$ErrorActionPreference = 'Continue'
`$a = [string]`$args
[IO.File]::AppendAllText('$(Join-Path $sandbox 'aws-calls.log')', `$a + [Environment]::NewLine)
if (`$a -match 'get-caller-identity') { '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/stub"}'; exit 0 }
if (`$a -match 'list-access-keys')    { '["AKIAEXAMPLE00000000"]'; exit 0 }
if (`$a -match 'list-user-policies')  { '[]'; exit 0 }
if (`$a -match 'get-policy')          { Write-Error 'An error occurred (NoSuchEntity) when calling the GetPolicy operation'; exit 254 }
exit 0
"@
            @{ ProjectName = "my-app"; AwsRegion = "eu-central-1" } |
                ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sandbox "ecs-config.json")
            return $sandbox
        }

        function script:Invoke-IamRemoveWithStub {
            param(
                [Parameter(Mandatory)][string]$Sandbox,
                [string]$Answers,
                [string]$ExtraArgs = ""
            )
            $childCmd = "`$env:PATH = '$Sandbox' + [IO.Path]::PathSeparator + `$env:PATH; " +
                "& '$($script:IamScriptPath)' -Remove -ConfigFile '$(Join-Path $Sandbox "ecs-config.json")' -AwsAccountId 123456789012 $ExtraArgs"
            # Run the child in its own console rather than piping into it.
            #
            # These cases exist to answer a ConfirmImpact 'High' prompt, and a
            # console host writes that prompt to the console it is attached to,
            # not to stdout -- so redirecting stdout does not capture it.
            # Piping the answers in works, but the prompt text and its
            # "[Y] Yes  [A] Yes to All" line still land on the terminal of
            # whoever ran the suite, interleaved with whatever else is drawing
            # there.
            #
            # Start-Process gives the child its own hidden console, so the
            # prompt is written there and goes nowhere. Answers arrive from a
            # file and both streams come back from files, which is also closer
            # to how the script runs unattended than a pipe is.
            # `exit $LASTEXITCODE` is load-bearing: pwsh -File returns the
            # wrapper's own exit code, which is 0 whatever the script it called
            # did, whereas -Command propagated $LASTEXITCODE for free. Without
            # this line these cases assert an exit code the harness invented,
            # and a script that stopped reporting failure would still pass.
            $childScript = Join-Path $Sandbox 'child-invocation.ps1'
            Set-Content -LiteralPath $childScript -Value "$childCmd`nexit `$LASTEXITCODE" -Encoding utf8
            $answerFile = Join-Path $Sandbox 'answers.txt'
            Set-Content -LiteralPath $answerFile -Value $Answers -Encoding utf8
            $stdoutFile = Join-Path $Sandbox 'child-stdout.txt'
            $stderrFile = Join-Path $Sandbox 'child-stderr.txt'

            $startArgs = @{
                FilePath               = 'pwsh'
                ArgumentList           = @('-NoProfile', '-File', $childScript)
                RedirectStandardInput  = $answerFile
                RedirectStandardOutput = $stdoutFile
                RedirectStandardError  = $stderrFile
                Wait                   = $true
                PassThru               = $true
            }
            # -WindowStyle is Windows-only and errors elsewhere; on other
            # platforms there is no console to leak onto in the first place.
            if ($IsWindows) { $startArgs.WindowStyle = 'Hidden' }
            $process = Start-Process @startArgs

            $stdout = Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue
            $stderr = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue

            [pscustomobject]@{
                ExitCode = $process.ExitCode
                Output   = "$stdout`n$stderr"
                AwsCalls = (Get-Content -LiteralPath (Join-Path $Sandbox 'aws-calls.log') -Raw -ErrorAction SilentlyContinue)
            }
        }
    }

    It "declining every prompt reports INCOMPLETE and exits non-zero, never an all-clear" {
        $sandbox = New-IamSandbox
        try {
            $run = Invoke-IamRemoveWithStub -Sandbox $sandbox -Answers "N`nN`n"
            $run.AwsCalls | Should -Not -Match 'delete-access-key' -Because "a declined prompt must not delete anything"
            $run.AwsCalls | Should -Not -Match 'delete-user'
            $run.Output   | Should -Match 'SKIPPED'
            $run.Output   | Should -Match 'INCOMPLETE, still present'
            $run.Output   | Should -Not -Match 'Removal complete'
            $run.ExitCode | Should -Not -Be 0 -Because "nothing was removed, so nothing may report success. Output: $($run.Output)"
        } finally {
            Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
        }
    }

    It "a PARTIAL decline is still not a completion" {
        # The realistic and most dangerous case: the operator accepts the
        # access-key deletion, then declines deleting the user. Real work
        # happened, nothing failed - and the old code called that "Removal
        # complete." while an IAM user was left behind.
        $sandbox = New-IamSandbox
        try {
            $run = Invoke-IamRemoveWithStub -Sandbox $sandbox -Answers "Y`nN`n"
            $run.AwsCalls | Should -Match 'delete-access-key' -Because "the accepted prompt must still act"
            $run.AwsCalls | Should -Not -Match 'delete-user' -Because "the declined prompt must not"
            $run.Output   | Should -Match 'INCOMPLETE, still present'
            $run.Output   | Should -Not -Match 'Removal complete'
            $run.ExitCode | Should -Not -Be 0 -Because "a half-removed identity must not look retired to a runbook. Output: $($run.Output)"
        } finally {
            Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
        }
    }

    It "accepting everything still reports completion and exits 0" {
        # Regression guard: the decline tracking must not make a genuinely
        # successful unattended removal look incomplete.
        $sandbox = New-IamSandbox
        try {
            $run = Invoke-IamRemoveWithStub -Sandbox $sandbox -ExtraArgs '-Confirm:$false'
            $run.AwsCalls | Should -Match 'delete-access-key'
            $run.AwsCalls | Should -Match 'delete-user'
            $run.Output   | Should -Match 'Removal complete'
            $run.Output   | Should -Not -Match 'INCOMPLETE'
            $run.ExitCode | Should -Be 0 -Because "a clean removal must not signal failure. Output: $($run.Output)"
        } finally {
            Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
        }
    }

    It "-WhatIf still reports a dry run, not an incomplete removal" {
        # Ordering guard, and the reason the decline check sits AFTER the
        # -WhatIf check: -WhatIf drives every ShouldProcess gate false as
        # well, so the decline counter is at its maximum on a dry run. If the
        # two checks were swapped, every -WhatIf would report INCOMPLETE and
        # exit 1 - turning the safe preview into a fake failure.
        $sandbox = New-IamSandbox
        try {
            $run = Invoke-IamRemoveWithStub -Sandbox $sandbox -ExtraArgs '-WhatIf'
            $run.AwsCalls | Should -Not -Match 'delete-access-key'
            $run.Output   | Should -Match 'Dry run - nothing was removed'
            $run.Output   | Should -Not -Match 'INCOMPLETE'
            $run.ExitCode | Should -Be 0 -Because "a dry run is not a failure. Output: $($run.Output)"
        } finally {
            Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
        }
    }
}

Describe "CCM version bump" {
    It "is at least 1.21.0" {
        $manifest = Import-PowerShellDataFile (Join-Path $PSScriptRoot ".." "CCM.psd1")
        [version]$manifest.ModuleVersion | Should -BeGreaterOrEqual ([version]"1.21.0")
    }
}
