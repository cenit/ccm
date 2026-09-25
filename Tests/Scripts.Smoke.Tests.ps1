BeforeDiscovery {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptFiles = Get-ChildItem -Path $script:RepoRoot -Filter '*.ps1' -File |
        Where-Object { $_.Name -notlike 'Microsoft.*_profile.ps1' }
}

Describe 'AST smoke test: <_.Name>' -ForEach $script:ScriptFiles {
    BeforeAll {
        $script:File = $_
        $tokens = $errors = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $_.FullName, [ref]$tokens, [ref]$errors
        )
        $script:ParseErrors = $errors
        $script:Tokens = $tokens
    }

    It 'parses with no syntax errors' {
        $script:ParseErrors | Should -BeNullOrEmpty
    }

    It 'has a top-level param() block or [CmdletBinding()]' {
        $hasParam = $null -ne $script:Ast.ParamBlock
        $hasCmdletBinding = $script:Ast.FindAll(
            { $args[0] -is [System.Management.Automation.Language.AttributeAst] -and
              $args[0].TypeName.Name -eq 'CmdletBinding' },
            $true
        ).Count -gt 0
        ($hasParam -or $hasCmdletBinding) | Should -BeTrue
    }

    It 'has a comment-based help block' {
        $hasHelp = $script:Tokens | Where-Object {
            $_.Kind -eq 'Comment' -and $_.Text -match '\.SYNOPSIS|\.DESCRIPTION'
        }
        $hasHelp | Should -Not -BeNullOrEmpty
    }

    It 'does not use forbidden patterns' {
        $raw = Get-Content -Raw $script:File.FullName
        $raw | Should -Not -Match 'GIT_SSL_NO_VERIFY\s*=\s*true'
        $raw | Should -Not -Match '--no-verify'
    }
}

Describe 'Logging boilerplate audit: <_.Name>' -ForEach $script:ScriptFiles {
    BeforeAll {
        $script:File = $_
        $script:Raw  = Get-Content -Raw $_.FullName
        $script:UsesLogging = $script:Raw -match 'Start-Transcript|Initialize-CcmLogging'
    }

    It 'calls Initialize-CcmLogging (if it logs at all)' {
        if (-not $script:UsesLogging) { Set-ItResult -Skipped -Because 'script does not use any transcript logging'; return }
        $script:Raw | Should -Match 'Initialize-CcmLogging'
    }
    It 'does not call Start-Transcript directly' {
        if (-not $script:UsesLogging) { Set-ItResult -Skipped -Because 'script does not use any transcript logging'; return }
        $script:Raw | Should -Not -Match 'Start-Transcript\b'
    }
    It 'calls Stop-CcmLogging' {
        if (-not $script:UsesLogging) { Set-ItResult -Skipped -Because 'script does not use any transcript logging'; return }
        $script:Raw | Should -Match 'Stop-CcmLogging'
    }
    It 'does not call Stop-Transcript directly' {
        if (-not $script:UsesLogging) { Set-ItResult -Skipped -Because 'script does not use any transcript logging'; return }
        $script:Raw | Should -Not -Match 'Stop-Transcript\b'
    }
}
