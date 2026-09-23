Describe 'deploy-ecs.ps1 pre-build hook' {
    BeforeAll {
        $script:Path = Join-Path (Split-Path -Parent $PSScriptRoot) 'deploy-ecs.ps1'
        $errors = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:Path, [ref]$null, [ref]$errors
        )
        $errors | Should -BeNullOrEmpty

        $script:HookIf = $script:Ast.FindAll(
            {
                $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and
                $args[0].Clauses[0].Item1.Extent.Text -match 'preBuildScript'
            }, $true) | Select-Object -First 1
    }

    It 'guards the hook on the same condition that guards the build' {
        # The hook prepares a BUILD context. On a deploy-only run (-SkipBuild or
        # -ExternalImage -- what the PR-preview and Deploy stages pass) its
        # output is discarded, and it fails outright when the work needs
        # something only the build stage is given. A repo whose hook fetched a
        # model with a credential from `extraEnv` built fine and then died in
        # PreviewDeploy, which gets no such credential and needs none.
        $script:HookIf | Should -Not -BeNullOrEmpty -Because 'the hook is invoked from an if statement'
        $script:HookIf.Clauses[0].Item1.Extent.Text |
            Should -Match 'EffectiveSkipBuild' -Because @'
deploy-ecs.ps1 runs pre-build.ps1 on deploy-only invocations. Gate it on
-not $EffectiveSkipBuild, the same variable Step 1 uses.
'@
    }

    It 'reads EffectiveSkipBuild only after it has been assigned' {
        # A text-level guard would pass even if the assignment moved below the
        # hook -- $EffectiveSkipBuild would then be $null, `-not $null` is true,
        # and the hook would silently run on every deploy again. This is the
        # assertion that actually keeps the fix working.
        $assignment = $script:Ast.FindAll(
            {
                $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $args[0].Left.Extent.Text -eq '$EffectiveSkipBuild'
            }, $true) | Select-Object -First 1

        $assignment | Should -Not -BeNullOrEmpty
        $because = '$EffectiveSkipBuild must hold its real value by the time the hook is gated on it'
        $assignment.Extent.StartLineNumber |
            Should -BeLessThan $script:HookIf.Extent.StartLineNumber -Because $because
    }
}
