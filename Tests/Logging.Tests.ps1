BeforeAll {
    $script:ModuleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:ModuleRoot 'CCM.psd1') -Force
    $script:TempRoot = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ("ccm-logging-tests-{0}" -f [guid]::NewGuid()))
}

AfterAll {
    Remove-Item $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# Per-Describe tests are added by subsequent tasks.

Describe 'Test-IsContainerizedRepository' {
    BeforeEach {
        $script:dir = New-Item -ItemType Directory -Path (Join-Path $script:TempRoot ([guid]::NewGuid()))
    }
    AfterEach {
        Remove-Item $script:dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'returns $false for an empty directory' {
        Test-IsContainerizedRepository -Path $script:dir.FullName | Should -BeFalse
    }
    It 'returns $true when Dockerfile is at root' {
        New-Item -ItemType File -Path (Join-Path $script:dir.FullName 'Dockerfile') | Out-Null
        Test-IsContainerizedRepository -Path $script:dir.FullName | Should -BeTrue
    }
    It 'returns $true when Containerfile is at root' {
        New-Item -ItemType File -Path (Join-Path $script:dir.FullName 'Containerfile') | Out-Null
        Test-IsContainerizedRepository -Path $script:dir.FullName | Should -BeTrue
    }
    It 'returns $true for compose.yml only' {
        New-Item -ItemType File -Path (Join-Path $script:dir.FullName 'compose.yml') | Out-Null
        Test-IsContainerizedRepository -Path $script:dir.FullName | Should -BeTrue
    }
    It 'returns $true for docker-compose.yaml only' {
        New-Item -ItemType File -Path (Join-Path $script:dir.FullName 'docker-compose.yaml') | Out-Null
        Test-IsContainerizedRepository -Path $script:dir.FullName | Should -BeTrue
    }
    It 'returns $true when .dockerignore is the only signal' {
        New-Item -ItemType File -Path (Join-Path $script:dir.FullName '.dockerignore') | Out-Null
        Test-IsContainerizedRepository -Path $script:dir.FullName | Should -BeTrue
    }
    It 'returns $true for docker/Dockerfile (depth 1)' {
        New-Item -ItemType Directory -Path (Join-Path $script:dir.FullName 'docker') | Out-Null
        New-Item -ItemType File -Path (Join-Path $script:dir.FullName 'docker\Dockerfile') | Out-Null
        Test-IsContainerizedRepository -Path $script:dir.FullName | Should -BeTrue
    }
    It 'returns $false for Dockerfile at depth 2' {
        $sub = New-Item -ItemType Directory -Path (Join-Path $script:dir.FullName 'a\b')
        New-Item -ItemType File -Path (Join-Path $sub.FullName 'Dockerfile') | Out-Null
        Test-IsContainerizedRepository -Path $script:dir.FullName | Should -BeFalse
    }
}

Describe 'Add-IgnorePatternBlock - fresh file' {
    BeforeEach {
        $script:dir = New-Item -ItemType Directory -Path (Join-Path $script:TempRoot ([guid]::NewGuid()))
        $script:f   = Join-Path $script:dir.FullName '.gitignore'
    }
    AfterEach { Remove-Item $script:dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'creates the file with the block when -CreateIfMissing $true' {
        Add-IgnorePatternBlock -Path $script:f -Pattern 'build*.log' -BlockId 'CCM logs' -CreateIfMissing $true | Out-Null
        Test-Path $script:f | Should -BeTrue
        $content = Get-Content -Raw $script:f
        $content | Should -Match '# >>> CCM logs \(managed by Initialize-CcmLogging.*\) >>>'
        $content | Should -Match 'build\*\.log'
        $content | Should -Match '# <<< CCM logs \(managed\) <<<'
    }
    It 'leaves the file absent when -CreateIfMissing $false' {
        Add-IgnorePatternBlock -Path $script:f -Pattern 'build*.log' -BlockId 'CCM logs' -CreateIfMissing $false | Out-Null
        Test-Path $script:f | Should -BeFalse
    }
}

Describe 'Add-IgnorePatternBlock - idempotency and append' {
    BeforeEach {
        $script:dir = New-Item -ItemType Directory -Path (Join-Path $script:TempRoot ([guid]::NewGuid()))
        $script:f   = Join-Path $script:dir.FullName '.gitignore'
    }
    AfterEach { Remove-Item $script:dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'appends a managed block to an existing file without one' {
        "*.tmp`n*.bak`n" | Set-Content -Path $script:f -NoNewline
        Add-IgnorePatternBlock -Path $script:f -Pattern 'build*.log' -BlockId 'CCM logs' -CreateIfMissing $false | Should -BeTrue
        $content = Get-Content -Raw $script:f
        $content | Should -Match '\*\.tmp'
        $content | Should -Match '\*\.bak'
        $content | Should -Match 'build\*\.log'
        $content | Should -Match '# >>> CCM logs'
    }
    It 'is a no-op when the pattern is already inside the block' {
        Add-IgnorePatternBlock -Path $script:f -Pattern 'build*.log' -BlockId 'CCM logs' -CreateIfMissing $true | Should -BeTrue
        $before = Get-Content -Raw $script:f
        Add-IgnorePatternBlock -Path $script:f -Pattern 'build*.log' -BlockId 'CCM logs' -CreateIfMissing $true | Should -BeFalse
        Get-Content -Raw $script:f | Should -Be $before
    }
    It 'appends a new pattern to an existing block' {
        Add-IgnorePatternBlock -Path $script:f -Pattern 'build*.log' -BlockId 'CCM logs' -CreateIfMissing $true | Should -BeTrue
        Add-IgnorePatternBlock -Path $script:f -Pattern 'deploy-ecs*.log' -BlockId 'CCM logs' -CreateIfMissing $true | Should -BeTrue
        $content = Get-Content -Raw $script:f
        $content | Should -Match 'build\*\.log'
        $content | Should -Match 'deploy-ecs\*\.log'
        $startIdx = $content.IndexOf('# >>> CCM logs')
        $endIdx   = $content.IndexOf('# <<< CCM logs')
        $startIdx | Should -BeGreaterOrEqual 0
        $endIdx | Should -BeGreaterThan $startIdx
        $inside = $content.Substring($startIdx, $endIdx - $startIdx)
        $inside | Should -Match 'build\*\.log'
        $inside | Should -Match 'deploy-ecs\*\.log'
    }
}

Describe 'Add-IgnorePatternBlock - line endings and recovery' {
    BeforeEach {
        $script:dir = New-Item -ItemType Directory -Path (Join-Path $script:TempRoot ([guid]::NewGuid()))
        $script:f   = Join-Path $script:dir.FullName '.gitignore'
    }
    AfterEach { Remove-Item $script:dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'preserves CRLF line endings on Windows-style files' {
        [IO.File]::WriteAllText($script:f, "*.tmp`r`n*.bak`r`n")
        Add-IgnorePatternBlock -Path $script:f -Pattern 'build*.log' -BlockId 'CCM logs' -CreateIfMissing $false | Out-Null
        $raw = [IO.File]::ReadAllText($script:f)
        $lfOnly = [regex]::Matches($raw, "(?<!`r)`n").Count
        $lfOnly | Should -Be 0
    }
    It 'preserves LF line endings on Unix-style files' {
        [IO.File]::WriteAllText($script:f, "*.tmp`n*.bak`n")
        Add-IgnorePatternBlock -Path $script:f -Pattern 'build*.log' -BlockId 'CCM logs' -CreateIfMissing $false | Out-Null
        $raw = [IO.File]::ReadAllText($script:f)
        $raw | Should -Not -Match "`r`n"
    }
    It 'recovers a malformed block (start sentinel only) by rewriting it' {
        $broken = "# >>> CCM logs (managed by Initialize-CcmLogging - do not edit between sentinels) >>>`n" +
                  "old-pattern*.log`n" +
                  "*.tmp`n"
        [IO.File]::WriteAllText($script:f, $broken)
        Add-IgnorePatternBlock -Path $script:f -Pattern 'build*.log' -BlockId 'CCM logs' -CreateIfMissing $false | Out-Null
        $content = Get-Content -Raw $script:f
        $content | Should -Match '# >>> CCM logs'
        $content | Should -Match '# <<< CCM logs'
        $content | Should -Match 'build\*\.log'
        $content | Should -Match 'old-pattern\*\.log'
    }
}

Describe 'Add-IgnorePatternBlock - multiple patterns in one call' {
    BeforeEach {
        $script:dir = New-Item -ItemType Directory -Path (Join-Path $script:TempRoot ([guid]::NewGuid()))
        $script:f   = Join-Path $script:dir.FullName '.gitignore'
    }
    AfterEach { Remove-Item $script:dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'creates a fresh file with every pattern in the array, one per line' {
        Add-IgnorePatternBlock -Path $script:f -Pattern @('bandit-report.json', 'coverage.xml', 'npm-audit.json') -BlockId 'CCM ci-checks artifacts' -CreateIfMissing $true -ManagedBy 'ci-checks.ps1' | Should -BeTrue
        $content = Get-Content -Raw $script:f
        $content | Should -Match '# >>> CCM ci-checks artifacts \(managed by ci-checks\.ps1 - do not edit between sentinels\) >>>'
        $content | Should -Match 'bandit-report\.json'
        $content | Should -Match 'coverage\.xml'
        $content | Should -Match 'npm-audit\.json'
        # Each pattern is its own line, not one blob - three real lines between the sentinels.
        $lines = (Get-Content $script:f)
        $startIdx = [array]::IndexOf($lines, '# >>> CCM ci-checks artifacts (managed by ci-checks.ps1 - do not edit between sentinels) >>>')
        $endIdx = [array]::IndexOf($lines, '# <<< CCM ci-checks artifacts (managed) <<<')
        $inside = $lines[($startIdx + 1)..($endIdx - 1)]
        $inside.Count | Should -Be 3
    }

    It 'running the same multi-pattern call twice is idempotent (no duplicate lines, second call is a no-op)' {
        $patterns = @('bandit-report.json', 'coverage.xml', 'npm-audit.json', 'security-reports-staging/')
        Add-IgnorePatternBlock -Path $script:f -Pattern $patterns -BlockId 'CCM ci-checks artifacts' -CreateIfMissing $true -ManagedBy 'ci-checks.ps1' | Should -BeTrue
        $before = Get-Content -Raw $script:f
        Add-IgnorePatternBlock -Path $script:f -Pattern $patterns -BlockId 'CCM ci-checks artifacts' -CreateIfMissing $true -ManagedBy 'ci-checks.ps1' | Should -BeFalse
        Get-Content -Raw $script:f | Should -Be $before
        # No pattern appears more than once. -SimpleMatch already treats
        # $p as a literal string, so it must NOT also be regex-escaped.
        foreach ($p in $patterns) {
            (Select-String -Path $script:f -Pattern $p -SimpleMatch).Count | Should -Be 1
        }
    }

    It 'a second call with a partially-overlapping array only adds the genuinely new patterns' {
        Add-IgnorePatternBlock -Path $script:f -Pattern @('bandit-report.json', 'coverage.xml') -BlockId 'CCM ci-checks artifacts' -CreateIfMissing $true -ManagedBy 'ci-checks.ps1' | Should -BeTrue
        Add-IgnorePatternBlock -Path $script:f -Pattern @('coverage.xml', 'npm-audit.json') -BlockId 'CCM ci-checks artifacts' -CreateIfMissing $true -ManagedBy 'ci-checks.ps1' | Should -BeTrue
        $content = Get-Content -Raw $script:f
        (Select-String -Path $script:f -Pattern 'coverage\.xml').Count | Should -Be 1
        $content | Should -Match 'bandit-report\.json'
        $content | Should -Match 'npm-audit\.json'
    }

    It 'accepts a single string too (back-compat for existing one-pattern callers)' {
        Add-IgnorePatternBlock -Path $script:f -Pattern 'ci-checks*.log' -BlockId 'CCM logs' -CreateIfMissing $true | Should -BeTrue
        (Get-Content -Raw $script:f) | Should -Match 'ci-checks\*\.log'
    }
}

Describe 'Add-IgnorePatternBlock - ManagedBy attribution and backward compatibility' {
    BeforeEach {
        $script:dir = New-Item -ItemType Directory -Path (Join-Path $script:TempRoot ([guid]::NewGuid()))
        $script:f   = Join-Path $script:dir.FullName '.gitignore'
    }
    AfterEach { Remove-Item $script:dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'defaults ManagedBy to Initialize-CcmLogging, matching the wording every pre-existing "CCM logs" block already has on disk' {
        Add-IgnorePatternBlock -Path $script:f -Pattern 'build*.log' -BlockId 'CCM logs' -CreateIfMissing $true | Should -BeTrue
        (Get-Content -Raw $script:f) | Should -Match '# >>> CCM logs \(managed by Initialize-CcmLogging - do not edit between sentinels\) >>>'
    }

    It 'a caller with its own BlockId can supply a different ManagedBy without touching the default' {
        Add-IgnorePatternBlock -Path $script:f -Pattern 'coverage.xml' -BlockId 'CCM ci-checks artifacts' -CreateIfMissing $true -ManagedBy 'ci-checks.ps1' | Should -BeTrue
        (Get-Content -Raw $script:f) | Should -Match '# >>> CCM ci-checks artifacts \(managed by ci-checks\.ps1 - do not edit between sentinels\) >>>'
    }

    It 'recognizes and updates in place a pre-existing "CCM logs" block written before the ManagedBy parameter existed (same hardcoded wording), rather than duplicating it' {
        # Exact text Initialize-CcmLogging has always written (BlockId 'CCM logs',
        # implicit "managed by Initialize-CcmLogging" wording) - simulates a
        # consumer .gitignore that predates this change.
        $legacy = "# >>> CCM logs (managed by Initialize-CcmLogging - do not edit between sentinels) >>>`n" +
                  "ci-checks*.log`n" +
                  "# <<< CCM logs (managed) <<<`n"
        [IO.File]::WriteAllText($script:f, $legacy)

        Add-IgnorePatternBlock -Path $script:f -Pattern 'deploy-ecs*.log' -BlockId 'CCM logs' -CreateIfMissing $true | Should -BeTrue

        $content = Get-Content -Raw $script:f
        # Still exactly one start sentinel and one end sentinel - no duplicate block.
        ([regex]::Matches($content, '# >>> CCM logs')).Count | Should -Be 1
        ([regex]::Matches($content, '# <<< CCM logs')).Count | Should -Be 1
        $content | Should -Match 'ci-checks\*\.log'
        $content | Should -Match 'deploy-ecs\*\.log'

        # Re-running with the exact same request is now idempotent too.
        Add-IgnorePatternBlock -Path $script:f -Pattern 'deploy-ecs*.log' -BlockId 'CCM logs' -CreateIfMissing $true | Should -BeFalse
    }

    It 'two blocks with different BlockId/ManagedBy coexist in the same file without cross-contamination' {
        Add-IgnorePatternBlock -Path $script:f -Pattern 'ci-checks*.log' -BlockId 'CCM logs' -CreateIfMissing $true | Should -BeTrue
        Add-IgnorePatternBlock -Path $script:f -Pattern @('coverage.xml', 'npm-audit.json') -BlockId 'CCM ci-checks artifacts' -CreateIfMissing $true -ManagedBy 'ci-checks.ps1' | Should -BeTrue

        $content = Get-Content -Raw $script:f
        $content | Should -Match '# >>> CCM logs \(managed by Initialize-CcmLogging - do not edit between sentinels\) >>>'
        $content | Should -Match '# >>> CCM ci-checks artifacts \(managed by ci-checks\.ps1 - do not edit between sentinels\) >>>'

        # Re-running both calls again is idempotent for each block independently.
        Add-IgnorePatternBlock -Path $script:f -Pattern 'ci-checks*.log' -BlockId 'CCM logs' -CreateIfMissing $true | Should -BeFalse
        Add-IgnorePatternBlock -Path $script:f -Pattern @('coverage.xml', 'npm-audit.json') -BlockId 'CCM ci-checks artifacts' -CreateIfMissing $true -ManagedBy 'ci-checks.ps1' | Should -BeFalse
    }
}

Describe 'Leveled Write-Ccm* helpers' {
    $cases = @(
        @{ Func = 'Write-CcmInfo';    Marker = '[INFO ]' }
        @{ Func = 'Write-CcmSuccess'; Marker = '[OK   ]' }
        @{ Func = 'Write-CcmWarning'; Marker = '[WARN ]' }
        @{ Func = 'Write-CcmError';   Marker = '[ERROR]' }
        @{ Func = 'Write-CcmStep';    Marker = '[STEP ]' }
    )
    It '<Func> exists as an exported command' -ForEach $cases {
        Get-Command $Func -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It '<Func> emits a line containing <Marker>' -ForEach $cases {
        $captured = & $Func 'hello' 6>&1 | Out-String
        $captured | Should -Match ([regex]::Escape($Marker))
        $captured | Should -Match 'hello'
    }
}

Describe 'Initialize-CcmLogging - happy path' {
    BeforeEach {
        $script:dir = New-Item -ItemType Directory -Path (Join-Path $script:TempRoot ([guid]::NewGuid()))
    }
    AfterEach {
        try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
        Remove-Item $script:dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates a log file at <LogDirectory>/<Name>.log' {
        $state = Initialize-CcmLogging -Name 'unit-test' -LogDirectory $script:dir.FullName -NoIgnorePatching
        try {
            $state.LogPath | Should -Be (Join-Path $script:dir.FullName 'unit-test.log')
            Test-Path $state.LogPath | Should -BeTrue
        } finally {
            Stop-CcmLogging $state
        }
    }
    It 'returns a state object with the documented fields' {
        $state = Initialize-CcmLogging -Name 'unit-test' -LogDirectory $script:dir.FullName -NoIgnorePatching
        try {
            $state.Name | Should -Be 'unit-test'
            $state.LogPath | Should -Not -BeNullOrEmpty
            $state.LogDirectory | Should -Be $script:dir.FullName
            $state.Started | Should -BeOfType [datetime]
            $state.PSObject.Properties.Name | Should -Contain 'RepoRoot'
            $state.PSObject.Properties.Name | Should -Contain 'IsContainerized'
            $state.PSObject.Properties.Name | Should -Contain 'GitignorePatched'
            $state.PSObject.Properties.Name | Should -Contain 'DockerignorePatched'
            $state.PSObject.Properties.Name | Should -Contain 'EventSubscriberId'
            $state.PSObject.Methods['Stop'] | Should -Not -BeNullOrEmpty
        } finally {
            Stop-CcmLogging $state
        }
    }
}

Describe 'Initialize-CcmLogging - ignore-file patching' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    BeforeEach {
        $script:dir = New-Item -ItemType Directory -Path (Join-Path $script:TempRoot ([guid]::NewGuid()))
        Push-Location $script:dir.FullName
        & git init -q 2>$null
        & git config user.email 'test@example.com' 2>$null
        & git config user.name  'test' 2>$null
        Pop-Location
    }
    AfterEach {
        try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
        Remove-Item $script:dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'patches .gitignore with <Name>*.log when in a git repo' {
        $state = Initialize-CcmLogging -Name 'unit-test' -LogDirectory $script:dir.FullName
        try {
            $state.RepoRoot | Should -Not -BeNullOrEmpty
            $state.GitignorePatched | Should -BeTrue
            $gi = Join-Path $script:dir.FullName '.gitignore'
            Test-Path $gi | Should -BeTrue
            (Get-Content -Raw $gi) | Should -Match 'unit-test\*\.log'
        } finally { Stop-CcmLogging $state }
    }
    It 'does not patch .gitignore when -NoIgnorePatching is given' {
        $state = Initialize-CcmLogging -Name 'unit-test' -LogDirectory $script:dir.FullName -NoIgnorePatching
        try {
            $state.GitignorePatched | Should -BeFalse
            (Test-Path (Join-Path $script:dir.FullName '.gitignore')) | Should -BeFalse
        } finally { Stop-CcmLogging $state }
    }
    It 'patches .dockerignore when a Dockerfile is present' {
        New-Item -ItemType File -Path (Join-Path $script:dir.FullName 'Dockerfile') | Out-Null
        $state = Initialize-CcmLogging -Name 'unit-test' -LogDirectory $script:dir.FullName
        try {
            $state.IsContainerized | Should -BeTrue
            $state.DockerignorePatched | Should -BeTrue
            $di = Join-Path $script:dir.FullName '.dockerignore'
            Test-Path $di | Should -BeTrue
            (Get-Content -Raw $di) | Should -Match 'unit-test\*\.log'
        } finally { Stop-CcmLogging $state }
    }
    It 'does NOT create .dockerignore when -NoCreateDockerignore is given' {
        New-Item -ItemType File -Path (Join-Path $script:dir.FullName 'Dockerfile') | Out-Null
        $state = Initialize-CcmLogging -Name 'unit-test' -LogDirectory $script:dir.FullName -NoCreateDockerignore
        try {
            $state.IsContainerized | Should -BeTrue
            $state.DockerignorePatched | Should -BeFalse
            (Test-Path (Join-Path $script:dir.FullName '.dockerignore')) | Should -BeFalse
        } finally { Stop-CcmLogging $state }
    }
}

Describe 'Stop-CcmLogging - idempotency' {
    BeforeEach {
        $script:dir = New-Item -ItemType Directory -Path (Join-Path $script:TempRoot ([guid]::NewGuid()))
    }
    AfterEach {
        try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
        Remove-Item $script:dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'does not throw when called twice' {
        $state = Initialize-CcmLogging -Name 'unit-test' -LogDirectory $script:dir.FullName -NoIgnorePatching
        Stop-CcmLogging $state
        { Stop-CcmLogging $state } | Should -Not -Throw
    }
    It 'unregisters the event subscribers on first call' {
        $state = Initialize-CcmLogging -Name 'unit-test' -LogDirectory $script:dir.FullName -NoIgnorePatching
        $subId = $state.EventSubscriberId
        Stop-CcmLogging $state
        $state.EventSubscriberId | Should -BeNullOrEmpty
        Get-EventSubscriber -SubscriptionId $subId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
    It '$state.Stop() works as a script method' {
        $state = Initialize-CcmLogging -Name 'unit-test' -LogDirectory $script:dir.FullName -NoIgnorePatching
        { $state.Stop() } | Should -Not -Throw
        $state.Stopped | Should -BeTrue
    }
}

Describe 'Initialize-CcmLogging - safety net under uncaught throw' {
    It 'closes the transcript when the calling script throws (engine-exit handler)' {
        $dir = New-Item -ItemType Directory -Path (Join-Path $script:TempRoot ([guid]::NewGuid()))
        $childScript = Join-Path $dir.FullName 'child.ps1'
        $logPath = Join-Path $dir.FullName 'child.log'
        $modulePath = Join-Path $script:ModuleRoot 'CCM.psd1'
        $childContent = @"
Import-Module '$modulePath' -Force
`$ccmLog = Initialize-CcmLogging -Name 'child' -LogDirectory '$($dir.FullName)' -NoIgnorePatching
Write-CcmInfo 'before-throw'
throw 'simulated failure'
"@
        Set-Content -Path $childScript -Value $childContent

        $pwshExe = (Get-Process -Id $PID).Path
        & $pwshExe -NoProfile -File $childScript 2>&1 | Out-Null

        Test-Path $logPath | Should -BeTrue
        $raw = Get-Content -Raw $logPath
        $raw | Should -Match 'before-throw'
        $raw | Should -Match 'PowerShell transcript end'

        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
