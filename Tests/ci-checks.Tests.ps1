# Pester tests for Get-CiPlan (pure stack/linter detection in ci-checks.ps1).
BeforeAll {
    # Dot-source the script with -WhatIfDetectOnly so it defines functions without executing gates.
    . "$PSScriptRoot/../ci-checks.ps1" -DetectOnly
}

Describe 'Get-CiPlan' {
    BeforeEach {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cicheck_" + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null
    }
    AfterEach {
        if (Test-Path $script:tmp) { Remove-Item $script:tmp -Recurse -Force }
    }

    It 'detects ruff when [tool.ruff] is present' {
        Set-Content "$script:tmp/pyproject.toml" "[tool.ruff]`nline-length = 100`n"
        $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile (Join-Path $script:tmp 'missing.json')
        $plan.HasBackend | Should -BeTrue
        $plan.Linter | Should -Be 'ruff'
    }

    It 'detects black-isort when [tool.black] is present and no ruff' {
        Set-Content "$script:tmp/pyproject.toml" "[tool.black]`nline-length = 100`n"
        $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile (Join-Path $script:tmp 'missing.json')
        $plan.Linter | Should -Be 'black-isort'
    }

    It 'detects frontend when frontend/package.json exists' {
        New-Item -ItemType Directory -Path "$script:tmp/frontend" -Force | Out-Null
        Set-Content "$script:tmp/frontend/package.json" '{ "scripts": { "lint": "eslint ." } }'
        $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile (Join-Path $script:tmp 'missing.json')
        $plan.HasFrontend | Should -BeTrue
        $plan.FrontendLint | Should -BeTrue
    }

    # Frontend test gate: autodetected from the package.json script (same shape
    # as FrontendLint above) with a kill switch, so a project with a real suite
    # starts gating without opting in. The placeholder case is the one that
    # matters: `npm init` writes a `test` script that exits 1 by design, and
    # treating that as "has tests" would fail every adopter that never wrote any.
    Context 'Frontend test gate detection' {
        BeforeEach {
            New-Item -ItemType Directory -Path "$script:tmp/frontend" -Force | Out-Null
        }

        It 'detects FrontendTest when package.json has a real test script' {
            Set-Content "$script:tmp/frontend/package.json" '{ "scripts": { "test": "vitest run" } }'
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile (Join-Path $script:tmp 'missing.json')
            $plan.FrontendTest | Should -BeTrue
            $plan.FrontendTestScript | Should -Be 'test'
        }

        It 'ignores the npm init placeholder test script' {
            # `npm init -y` writes exactly this. It exits 1 unconditionally, so
            # running it would turn "this project has no frontend tests" into a
            # red build on the next CCM ref bump.
            Set-Content "$script:tmp/frontend/package.json" @'
{ "scripts": { "test": "echo \"Error: no test specified\" && exit 1" } }
'@
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile (Join-Path $script:tmp 'missing.json')
            $plan.HasFrontend | Should -BeTrue
            $plan.FrontendTest | Should -BeFalse
        }

        It 'reports FrontendTest false when package.json has no test script' {
            Set-Content "$script:tmp/frontend/package.json" '{ "scripts": { "lint": "eslint ." } }'
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile (Join-Path $script:tmp 'missing.json')
            $plan.FrontendTest | Should -BeFalse
        }

        It 'ci.skipFrontendTests forces FrontendTest false while leaving the other frontend gates on' {
            Set-Content "$script:tmp/frontend/package.json" '{ "scripts": { "lint": "eslint .", "test": "vitest run" } }'
            $cfg = Join-Path $script:tmp 'ecs-config.json'
            Set-Content $cfg '{ "ProjectName": "x", "ci": { "skipFrontendTests": true } }'
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile $cfg
            $plan.FrontendTest | Should -BeFalse
            $plan.HasFrontend | Should -BeTrue
            $plan.FrontendLint | Should -BeTrue
        }

        It 'honors a ci.frontendTestScript override for suites not named "test"' {
            Set-Content "$script:tmp/frontend/package.json" '{ "scripts": { "test": "vitest", "test:ci": "vitest run --reporter=junit" } }'
            $cfg = Join-Path $script:tmp 'ecs-config.json'
            Set-Content $cfg '{ "ProjectName": "x", "ci": { "frontendTestScript": "test:ci" } }'
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile $cfg
            $plan.FrontendTest | Should -BeTrue
            $plan.FrontendTestScript | Should -Be 'test:ci'
        }

        It 'reports FrontendTest false when ci.frontendTestScript names a script that does not exist' {
            Set-Content "$script:tmp/frontend/package.json" '{ "scripts": { "test": "vitest run" } }'
            $cfg = Join-Path $script:tmp 'ecs-config.json'
            Set-Content $cfg '{ "ProjectName": "x", "ci": { "frontendTestScript": "test:ci" } }'
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile $cfg
            $plan.FrontendTest | Should -BeFalse
        }

        It 'honors ci.frontendDir when detecting the test script' {
            New-Item -ItemType Directory -Path "$script:tmp/web" -Force | Out-Null
            Set-Content "$script:tmp/web/package.json" '{ "scripts": { "test": "vitest run" } }'
            $cfg = Join-Path $script:tmp 'ecs-config.json'
            Set-Content $cfg '{ "ProjectName": "x", "ci": { "frontendDir": "web" } }'
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile $cfg
            $plan.FrontendDir | Should -Be 'web'
            $plan.FrontendTest | Should -BeTrue
        }
    }

    It 'reports FrontendTest false and the default script name on a repo with no frontend' {
        $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile (Join-Path $script:tmp 'missing.json')
        $plan.FrontendTest | Should -BeFalse
        $plan.FrontendTestScript | Should -Be 'test'
    }

    It 'honors ci.skipLinting, ci.pipAuditIgnores and ci.npmAuditIgnores from ecs-config.json' {
        Set-Content "$script:tmp/pyproject.toml" "[tool.ruff]`n"
        $cfg = Join-Path $script:tmp 'ecs-config.json'
        Set-Content $cfg '{ "ProjectName": "x", "ci": { "skipLinting": true, "pipAuditIgnores": ["CVE-1"], "npmAuditIgnores": ["GHSA-aaaa-bbbb-cccc"] } }'
        $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile $cfg
        $plan.Linter | Should -Be 'none'
        $plan.PipAuditIgnores | Should -Contain 'CVE-1'
        $plan.NpmAuditIgnores | Should -Contain 'GHSA-aaaa-bbbb-cccc'
    }

    It 'defaults NpmAuditIgnores to an empty array when ci block is absent' {
        $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile (Join-Path $script:tmp 'missing.json')
        $plan.NpmAuditIgnores | Should -BeNullOrEmpty
        , $plan.NpmAuditIgnores | Should -BeOfType [array]
    }

    It 'reports no backend / no frontend on an empty repo' {
        $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile (Join-Path $script:tmp 'missing.json')
        $plan.HasBackend | Should -BeFalse
        $plan.HasFrontend | Should -BeFalse
    }

    It 'returns SourcePaths as an array even when it resolves to a single path' {
        # Regression: a single-element result must stay an array. If it collapses to a
        # scalar string, `python -m black @srcArgs` splats the string char-by-char and
        # black fails with "Path 'b' does not exist." (the 'b' of 'backend/').
        New-Item -ItemType Directory -Path "$script:tmp/backend" -Force | Out-Null
        $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile (Join-Path $script:tmp 'missing.json')
        $plan.SourcePaths -is [array] | Should -BeTrue
        $plan.SourcePaths | Should -Contain 'backend/'
    }

    It 'defaults SourcePaths to an array of src/ when there is no backend dir' {
        $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile (Join-Path $script:tmp 'missing.json')
        $plan.SourcePaths -is [array] | Should -BeTrue
        $plan.SourcePaths | Should -Contain 'src/'
    }

    It 'defaults TestPaths to an array of tests/ and CovTarget to backend' {
        $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile (Join-Path $script:tmp 'missing.json')
        $plan.TestPaths -is [array] | Should -BeTrue
        $plan.TestPaths | Should -Contain 'tests/'
        $plan.CovTarget | Should -Be 'backend'
    }

    It 'honors ci.testPaths and ci.covTarget overrides from ecs-config.json' {
        $cfg = Join-Path $script:tmp 'ecs-config.json'
        Set-Content $cfg '{ "ProjectName": "x", "ci": { "testPaths": ["backend/tests", "tests"], "covTarget": "backend" } }'
        $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile $cfg
        $plan.TestPaths -is [array] | Should -BeTrue
        $plan.TestPaths | Should -Contain 'backend/tests'
        $plan.TestPaths | Should -Contain 'tests'
        $plan.CovTarget | Should -Be 'backend'
    }

    It 'keeps a single-element ci.testPaths override as an array' {
        # Same char-by-char splat regression as SourcePaths: a lone override path
        # must stay an array so `python -m pytest @testArgs` gets 'backend/tests',
        # not 'b','a','c','k',...
        $cfg = Join-Path $script:tmp 'ecs-config.json'
        Set-Content $cfg '{ "ProjectName": "x", "ci": { "testPaths": ["backend/tests"] } }'
        $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile $cfg
        $plan.TestPaths -is [array] | Should -BeTrue
        $plan.TestPaths | Should -Contain 'backend/tests'
    }

    It 'defaults PipLicenseIgnores to an empty array when ci block is absent' {
        $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile (Join-Path $script:tmp 'missing.json')
        $plan.PipLicenseIgnores | Should -BeNullOrEmpty
        , $plan.PipLicenseIgnores | Should -BeOfType [array]
    }

    It 'honors ci.pipLicenseIgnores from a non-ecs config file (e.g. ci-config.json)' {
        $cfg = Join-Path $script:tmp 'ci-config.json'
        Set-Content $cfg '{ "ci": { "pipLicenseIgnores": ["pyinstaller", "pyinstaller-hooks-contrib"] } }'
        $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile $cfg
        $plan.PipLicenseIgnores -is [array] | Should -BeTrue
        $plan.PipLicenseIgnores | Should -Contain 'pyinstaller'
        $plan.PipLicenseIgnores | Should -Contain 'pyinstaller-hooks-contrib'
    }

    # Regression coverage for two bugs found while wiring TestMarkers through
    # Get-CiPlan, both of which fail SILENTLY (green suite, wrong behavior):
    #  1. $PSBoundParameters inside a function reflects only that function's own
    #     bound parameters, never the caller's - so TestMarkersSet must be
    #     resolved by the caller and passed in explicitly, not re-derived here.
    #  2. PowerShell variable names are case-insensitive, so a local named
    #     $testMarkers would be the SAME slot as the [string]-typed $TestMarkers
    #     parameter, silently coercing an intended $null to "".
    Context 'TestMarkers precedence (ci.testMarkers vs -TestMarkers)' {
        It 'is null when ci.testMarkers is absent and -TestMarkers is not passed' {
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile (Join-Path $script:tmp 'missing.json')
            $plan.TestMarkers | Should -Be $null
        }

        It 'honors ci.testMarkers when -TestMarkers is not passed' {
            $cfg = Join-Path $script:tmp 'ecs-config.json'
            Set-Content $cfg '{ "ProjectName": "x", "ci": { "testMarkers": "not slow" } }'
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile $cfg
            $plan.TestMarkers | Should -Be 'not slow'
        }

        It 'an explicitly passed -TestMarkers overrides ci.testMarkers' {
            $cfg = Join-Path $script:tmp 'ecs-config.json'
            Set-Content $cfg '{ "ProjectName": "x", "ci": { "testMarkers": "not slow" } }'
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile $cfg -TestMarkers 'fast' -TestMarkersSet:$true
            $plan.TestMarkers | Should -Be 'fast'
        }

        It 'an explicitly passed empty -TestMarkers clears ci.testMarkers, distinguishably from absent/null' {
            # This is the case that matters most: '' means "no -m flag, run
            # everything" (the weekly full-test schedule), which is only
            # distinguishable from the default/absent case if it stays a real
            # empty string and never collapses back to $null.
            $cfg = Join-Path $script:tmp 'ecs-config.json'
            Set-Content $cfg '{ "ProjectName": "x", "ci": { "testMarkers": "not slow" } }'
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile $cfg -TestMarkers '' -TestMarkersSet:$true
            $plan.TestMarkers | Should -Not -Be $null
            $plan.TestMarkers | Should -BeOfType [string]
            $plan.TestMarkers | Should -Be ''
        }
    }

    # ci.hasBackend: an explicit override for Python backends that predate
    # pyproject.toml (requirements.txt-only layouts), where pyproject.toml
    # autodetection alone would silently skip pytest/bandit/pip-audit/
    # pip-licenses/lint. Tri-state (absent/true/false) plus the skipBackend
    # interaction, the one most likely to rot per review feedback.
    Context 'ci.hasBackend override' {
        It 'autodetects HasBackend false when ci.hasBackend is absent and there is no pyproject.toml' {
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile (Join-Path $script:tmp 'missing.json')
            $plan.HasBackend | Should -BeFalse
        }

        It 'autodetects HasBackend true when ci.hasBackend is absent and pyproject.toml is present' {
            Set-Content "$script:tmp/pyproject.toml" "[tool.ruff]`n"
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile (Join-Path $script:tmp 'missing.json')
            $plan.HasBackend | Should -BeTrue
        }

        It 'ci.hasBackend:true forces HasBackend true even with no pyproject.toml' {
            $cfg = Join-Path $script:tmp 'ecs-config.json'
            Set-Content $cfg '{ "ProjectName": "x", "ci": { "hasBackend": true } }'
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile $cfg
            $plan.HasBackend | Should -BeTrue
        }

        It 'ci.hasBackend:false forces HasBackend false even with pyproject.toml present' {
            Set-Content "$script:tmp/pyproject.toml" "[tool.ruff]`n"
            $cfg = Join-Path $script:tmp 'ecs-config.json'
            Set-Content $cfg '{ "ProjectName": "x", "ci": { "hasBackend": false } }'
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile $cfg
            $plan.HasBackend | Should -BeFalse
        }

        It 'ci.skipBackend:true still wins over an explicit ci.hasBackend:true' {
            $cfg = Join-Path $script:tmp 'ecs-config.json'
            Set-Content $cfg '{ "ProjectName": "x", "ci": { "hasBackend": true, "skipBackend": true } }'
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile $cfg
            $plan.HasBackend | Should -BeFalse
        }
    }

    # Strict-typing gate. Explicit ci.mypyPaths still wins, but the gate now also
    # turns itself on wherever mypy's own config can live, on the same "declared
    # config = intent" principle as the ruff / black-isort autodetection.
    # ci.skipMypy is the kill switch for a project that keeps a [tool.mypy] block
    # for editors or pre-commit without a CI-clean run.
    Context 'mypy gate detection' {
        It 'leaves MypyPaths empty when nothing declares mypy config' {
            Set-Content "$script:tmp/pyproject.toml" "[tool.ruff]`n"
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile (Join-Path $script:tmp 'missing.json')
            $plan.MypyPaths | Should -BeNullOrEmpty
            , $plan.MypyPaths | Should -BeOfType [array]
        }

        It 'autodetects from mypy.ini and targets SourcePaths' {
            New-Item -ItemType Directory -Path "$script:tmp/backend" -Force | Out-Null
            Set-Content "$script:tmp/mypy.ini" "[mypy]`nstrict = True`n"
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile (Join-Path $script:tmp 'missing.json')
            $plan.MypyPaths -is [array] | Should -BeTrue
            $plan.MypyPaths | Should -Contain 'backend/'
        }

        It 'autodetects from .mypy.ini' {
            Set-Content "$script:tmp/.mypy.ini" "[mypy]`nstrict = True`n"
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile (Join-Path $script:tmp 'missing.json')
            $plan.MypyPaths | Should -Not -BeNullOrEmpty
        }

        It 'autodetects from [tool.mypy] in pyproject.toml' {
            Set-Content "$script:tmp/pyproject.toml" "[tool.ruff]`n`n[tool.mypy]`nstrict = true`n"
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile (Join-Path $script:tmp 'missing.json')
            $plan.MypyPaths | Should -Contain 'src/'
        }

        It 'autodetects from [mypy] in setup.cfg' {
            Set-Content "$script:tmp/setup.cfg" "[metadata]`nname = x`n`n[mypy]`nstrict = True`n"
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile (Join-Path $script:tmp 'missing.json')
            $plan.MypyPaths | Should -Not -BeNullOrEmpty
        }

        It 'does not autodetect from an unrelated setup.cfg section' {
            Set-Content "$script:tmp/setup.cfg" "[metadata]`nname = x`n[flake8]`nmax-line-length = 100`n"
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile (Join-Path $script:tmp 'missing.json')
            $plan.MypyPaths | Should -BeNullOrEmpty
        }

        It 'an explicit ci.mypyPaths overrides the autodetected SourcePaths' {
            Set-Content "$script:tmp/pyproject.toml" "[tool.mypy]`n"
            New-Item -ItemType Directory -Path "$script:tmp/backend" -Force | Out-Null
            $cfg = Join-Path $script:tmp 'ecs-config.json'
            Set-Content $cfg '{ "ProjectName": "x", "ci": { "mypyPaths": ["backend/app"] } }'
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile $cfg
            $plan.MypyPaths | Should -Contain 'backend/app'
            $plan.MypyPaths | Should -Not -Contain 'backend/'
        }

        It 'keeps a single-element ci.mypyPaths override as an array' {
            # Same char-by-char splat regression as SourcePaths/TestPaths: a lone
            # override must stay an array so `python -m mypy @mypyArgs` receives
            # 'backend/app', not 'b','a','c','k',...
            $cfg = Join-Path $script:tmp 'ecs-config.json'
            Set-Content $cfg '{ "ProjectName": "x", "ci": { "mypyPaths": ["backend/app"] } }'
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile $cfg
            $plan.MypyPaths -is [array] | Should -BeTrue
            $plan.MypyPaths.Count | Should -Be 1
        }

        It 'ci.skipMypy disables the autodetected gate' {
            Set-Content "$script:tmp/mypy.ini" "[mypy]`n"
            $cfg = Join-Path $script:tmp 'ecs-config.json'
            Set-Content $cfg '{ "ProjectName": "x", "ci": { "skipMypy": true } }'
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile $cfg
            $plan.MypyPaths | Should -BeNullOrEmpty
        }

        It 'ci.skipMypy wins over an explicit ci.mypyPaths' {
            # Same kill-switch precedence as ci.skipBackend over ci.hasBackend:
            # the skip must be a reliable off switch whatever else is configured.
            $cfg = Join-Path $script:tmp 'ecs-config.json'
            Set-Content $cfg '{ "ProjectName": "x", "ci": { "mypyPaths": ["backend/app"], "skipMypy": true } }'
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile $cfg
            $plan.MypyPaths | Should -BeNullOrEmpty
        }

        It 'honors ci.sourcePaths when autodetecting the mypy targets' {
            Set-Content "$script:tmp/mypy.ini" "[mypy]`n"
            $cfg = Join-Path $script:tmp 'ecs-config.json'
            Set-Content $cfg '{ "ProjectName": "x", "ci": { "sourcePaths": ["src/my_package"] } }'
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile $cfg
            $plan.MypyPaths | Should -Contain 'src/my_package'
        }
    }

    # ci.auditRequirements: additional requirements files that ship to
    # production but are NOT installed into the CI venv, so the CVE gate
    # above never sees them (e.g. an aws-ecs project's disjoint
    # backend/requirements.txt). Covers detection (Get-CiPlan) plus the
    # missing-file behavior (Assert-AuditRequirementsExist), which is split
    # into its own throwing function specifically so it's testable without
    # invoking `exit` (which would kill the Pester process, not just fail
    # an assertion).
    Context 'ci.auditRequirements' {
        It 'defaults AuditRequirements to an empty array when ci block is absent' {
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile (Join-Path $script:tmp 'missing.json')
            $plan.AuditRequirements | Should -BeNullOrEmpty
            , $plan.AuditRequirements | Should -BeOfType [array]
        }

        It 'honors a single ci.auditRequirements path' {
            $cfg = Join-Path $script:tmp 'ecs-config.json'
            Set-Content $cfg '{ "ProjectName": "x", "ci": { "auditRequirements": ["backend/requirements.txt"] } }'
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile $cfg
            $plan.AuditRequirements -is [array] | Should -BeTrue
            $plan.AuditRequirements | Should -Contain 'backend/requirements.txt'
            $plan.AuditRequirements.Count | Should -Be 1
        }

        It 'honors multiple ci.auditRequirements paths' {
            $cfg = Join-Path $script:tmp 'ecs-config.json'
            Set-Content $cfg '{ "ProjectName": "x", "ci": { "auditRequirements": ["backend/requirements.txt", "worker/requirements.txt"] } }'
            $plan = Get-CiPlan -RepoRoot $script:tmp -ConfigFile $cfg
            $plan.AuditRequirements -is [array] | Should -BeTrue
            $plan.AuditRequirements | Should -Contain 'backend/requirements.txt'
            $plan.AuditRequirements | Should -Contain 'worker/requirements.txt'
            $plan.AuditRequirements.Count | Should -Be 2
        }

        It 'Assert-AuditRequirementsExist throws on a nonexistent path rather than passing silently' {
            { Assert-AuditRequirementsExist -RepoRoot $script:tmp -AuditRequirements @('does/not/exist-requirements.txt') } |
                Should -Throw -ExpectedMessage '*does/not/exist-requirements.txt*'
        }

        It 'Assert-AuditRequirementsExist does not throw when every path exists' {
            New-Item -ItemType Directory -Path "$script:tmp/backend" -Force | Out-Null
            Set-Content "$script:tmp/backend/requirements.txt" "fastapi==0.100.0`n"
            { Assert-AuditRequirementsExist -RepoRoot $script:tmp -AuditRequirements @('backend/requirements.txt') } |
                Should -Not -Throw
        }
    }

    Context 'npm licence expressions' {
        # The gate this backs read `$_.licenses` against a CSV whose column is
        # `license`, so every comparison ran against $null and the gate passed
        # unconditionally on every repo using it. These cases pin both
        # halves of the fix: what must now fail, and what must still pass.
        It 'rejects <Expression>' -ForEach @(
            @{ Expression = 'GPL-3.0-or-later' }
            @{ Expression = 'AGPL-3.0' }
            @{ Expression = 'GPL-2.0-only OR GPL-3.0-only' }
            @{ Expression = 'GNU General Public License v3 (GPLv3)' }
            # AND is not a choice: every term binds, so one GPL term binds.
            @{ Expression = 'MIT AND GPL-3.0-or-later' }
        ) {
            Test-SpdxCopyleftOnly -Expression $Expression | Should -BeTrue
        }

        It 'accepts <Expression>' -ForEach @(
            @{ Expression = 'MIT' }
            @{ Expression = 'Apache-2.0' }
            # The case that reaches many projects, through exceljs -> jszip.
            # OR is a CHOICE, so the MIT side is available and nothing is owed.
            @{ Expression = '(MIT OR GPL-3.0-or-later)' }
            @{ Expression = 'GPL-3.0-or-later OR MIT' }
            # Mixed case, because SPDX operators appear that way in the wild.
            @{ Expression = '(MIT or GPL-3.0-or-later)' }
            # LGPL stays permitted, matching the pip gate.
            @{ Expression = 'LGPL-3.0' }
            @{ Expression = 'GNU Lesser General Public License' }
            # An absent licence is license-checker's `(UNKNOWN)` case, and it is
            # not this gate's business to reject it.
            @{ Expression = '' }
        ) {
            Test-SpdxCopyleftOnly -Expression $Expression | Should -BeFalse
        }
    }
}

# $CiReportArtifactPatterns lists every root-level artifact ci-checks.ps1 can
# itself produce (bandit/pip/npm reports, pytest's coverage/junit output, the
# security-reports-staging/ directory) so it can be patched into a consumer's
# .gitignore/.dockerignore via Add-IgnorePatternBlock before any gate runs.
# Defined at script scope (before the -DetectOnly early return), so dot-
# sourcing with -DetectOnly in BeforeAll above makes it available here without
# running any gate.
Describe 'CiReportArtifactPatterns' {
    It 'is defined and is an array' {
        $CiReportArtifactPatterns | Should -Not -BeNullOrEmpty
        , $CiReportArtifactPatterns | Should -BeOfType [array]
    }

    It 'covers every fixed-name report artifact the Python gates can produce' {
        $CiReportArtifactPatterns | Should -Contain 'bandit-report.json'
        $CiReportArtifactPatterns | Should -Contain 'pip-licenses.csv'
        $CiReportArtifactPatterns | Should -Contain 'coverage.xml'
        $CiReportArtifactPatterns | Should -Contain '.coverage'
        $CiReportArtifactPatterns | Should -Contain 'test-unit.xml'
    }

    It 'covers pip-audit.json and the dynamically-named ci.auditRequirements reports via a single glob' {
        # Real filenames these can take: 'pip-audit.json' (CI-venv gate) and
        # 'pip-audit-<sanitized-manifest-path>.json' (one per ci.auditRequirements
        # entry, name derived from the config-supplied path - see ci-checks.ps1's
        # $reqReportName). Confirm the glob covers both shapes, not just the
        # literal string.
        $CiReportArtifactPatterns | Should -Contain 'pip-audit*.json'
        'pip-audit.json' -like 'pip-audit*.json' | Should -BeTrue
        'pip-audit-backend-requirements.txt.json' -like 'pip-audit*.json' | Should -BeTrue
    }

    It 'covers every fixed-name report artifact the frontend gates can produce' {
        $CiReportArtifactPatterns | Should -Contain 'npm-licenses.csv'
        $CiReportArtifactPatterns | Should -Contain 'npm-audit.json'
        # Not produced by ci-checks itself: it is the documented filename a
        # project's frontend test script writes its JUnit report to, so the
        # template's existing '**/test-*.xml' publish picks it up. Ignored here
        # for the same reason as pytest's test-unit.xml - a CI-generated report
        # that must never be committed.
        $CiReportArtifactPatterns | Should -Contain 'test-frontend.xml'
    }

    It 'covers the always-created security-reports-staging directory' {
        $CiReportArtifactPatterns | Should -Contain 'security-reports-staging/'
    }
}

Describe 'linter gate invocation' {
    BeforeAll {
        # Whole-line `#` comments stripped before matching, because the fix's own comment has to name the broken `python -m isort`
        # form in order to explain it, and a raw text search would then "fail" on
        # the prose describing the bug rather than on the invocation causing it.
        $script:CiChecks = ((Get-Content "$PSScriptRoot/../ci-checks.ps1") |
            Where-Object { $_.Trim() -notmatch '^#' }) -join "`n"
    }

    It 'invokes isort through its console script, not python -m' {
        # isort 9.0.0 ships an __main__.py with no code object, so `python -m isort`
        # dies with "No code object available for isort.__main__; 'isort' is a package
        # and cannot be directly executed" -- exit 1, before it lints anything.
        #
        # Every repo on the black-isort linter breaks the moment it resolves isort 9,
        # and the ceiling is typically open (`isort>=5.13.2`), so this arrives on its
        # own with no change on the consumer's side. The console script works
        # identically on 8 and 9, and Enable-PythonVenv has already put the venv's
        # Scripts/ (bin/ on Linux) on PATH by the time the gates run.
        #
        # black, flake8, mypy, bandit, pip_audit and pytest all still support -m and
        # are deliberately left alone: one change, for the one tool that broke.
        $script:CiChecks | Should -Not -Match 'python\s+-m\s+isort'
        $script:CiChecks | Should -Match "Invoke-Gate 'Code style: isort --check-only'\s*\{\s*isort --check-only"
    }
}

Describe 'PYTHONUTF8 environment setup' {
    BeforeAll {
        # Same stripped-comment technique as 'linter gate invocation' above,
        # re-derived here rather than shared across Describes: the fix's own
        # comment names 'python -m black' etc. to explain the failure mode, so
        # a raw text search would trip over the prose describing the bug
        # rather than the invocations it describes.
        $script:CiChecksUtf8 = ((Get-Content "$PSScriptRoot/../ci-checks.ps1") |
            Where-Object { $_.Trim() -notmatch '^#' }) -join "`n"
    }

    It 'sets PYTHONUTF8 before every Python tool invocation it reaches' {
        # Regression guard for the false-green isort bug: on a build agent
        # whose ANSI codepage isn't UTF-8 (cp1252 on typical Windows
        # agents), isort 9.x hits an encoding error on a source file it can't
        # decode, prints a warning, SKIPS that file, and still exits 0 - a
        # genuine sort violation in it sails through undetected. PYTHONUTF8=1
        # removes the cause, but only if it is actually in effect before ANY
        # Python process starts, setup-venv's own pip installs included; a
        # later placement (e.g. next to the isort gate specifically) would
        # leave every invocation before it unprotected.
        #
        # This can't be verified by actually running the script (setup-venv
        # needs network + a real venv, and -DetectOnly intentionally returns
        # before this code ever runs - see the -DetectOnly branch above), so
        # this asserts positional order in the un-commented source instead:
        # a real proxy for execution order here, since the script runs its
        # top-level statements linearly and none of these calls sit inside a
        # function that could be invoked out of that order.
        $utf8Index = $script:CiChecksUtf8.IndexOf('$env:PYTHONUTF8')
        $utf8Index | Should -BeGreaterThan -1 -Because 'ci-checks.ps1 should set PYTHONUTF8'

        $pythonInvocations = @(
            '& "$ScriptDir/setup-venv.ps1"'
            'python -m black'
            'isort --check-only'
            'python -m flake8'
            'python -m mypy'
            'python -m bandit'
            'python -m pytest'
        )
        foreach ($probe in $pythonInvocations) {
            $probeIndex = $script:CiChecksUtf8.IndexOf($probe)
            $probeIndex | Should -BeGreaterThan -1 -Because "expected to find '$probe' in ci-checks.ps1"
            $probeIndex | Should -BeGreaterThan $utf8Index -Because "PYTHONUTF8 must be set before '$probe' runs"
        }
    }
}
