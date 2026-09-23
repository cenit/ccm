# Pester tests for Get-CcmVenvBootstrapPackages, the selection rule behind
# setup-venv.ps1's "refresh stale pip/setuptools" step.
BeforeAll {
    $script:ModuleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:ModuleRoot "CCM.psd1") -Force
}

Describe "Get-CcmVenvBootstrapPackages" {
    It "returns both bootstrap packages when both are installed" {
        # Shape of real `uv pip list --format json` output: one compact line.
        $json = '[{"name":"pip","version":"24.0"},{"name":"setuptools","version":"65.5.0"}]'

        Get-CcmVenvBootstrapPackages -PipListJson $json | Should -Be @('pip', 'setuptools')
    }

    It "returns only the bootstrap package that is present" {
        $json = '[{"name":"pip","version":"24.0"},{"name":"requests","version":"2.32.3"}]'

        Get-CcmVenvBootstrapPackages -PipListJson $json | Should -Be @('pip')
    }

    It "returns setuptools alone when pip was never pulled in" {
        $json = '[{"name":"setuptools","version":"65.5.0"},{"name":"wheel","version":"0.43.0"}]'

        Get-CcmVenvBootstrapPackages -PipListJson $json | Should -Be @('setuptools')
    }

    It "leaves a bare venv bare" {
        # The documented intent: a venv that never pulled pip in stays bare, so
        # nothing is upgraded and setup-venv.ps1 skips the uv call entirely.
        $json = '[{"name":"requests","version":"2.32.3"},{"name":"httpx","version":"0.27.0"}]'

        @(Get-CcmVenvBootstrapPackages -PipListJson $json).Count | Should -Be 0
    }

    It "returns nothing for an empty package list" {
        @(Get-CcmVenvBootstrapPackages -PipListJson '[]').Count | Should -Be 0
    }

    It "orders pip before setuptools regardless of listing order" {
        $json = '[{"name":"setuptools","version":"65.5.0"},{"name":"pip","version":"24.0"}]'

        Get-CcmVenvBootstrapPackages -PipListJson $json | Should -Be @('pip', 'setuptools')
    }

    It "matches package names case-insensitively" {
        $json = '[{"name":"Pip","version":"24.0"},{"name":"SetupTools","version":"65.5.0"}]'

        Get-CcmVenvBootstrapPackages -PipListJson $json | Should -Be @('pip', 'setuptools')
    }

    It "accepts the string array a native command emits over several lines" {
        # Contract test: `& uv pip list` yields string[] when the output spans
        # lines, so the function must take that shape as well as a single string.
        $lines = @(
            '[',
            '  {"name": "pip", "version": "24.0"},',
            '  {"name": "setuptools", "version": "65.5.0"}',
            ']'
        )

        Get-CcmVenvBootstrapPackages -PipListJson $lines | Should -Be @('pip', 'setuptools')
    }

    It "degrades to no upgrades on malformed JSON instead of throwing" {
        # This runs at the very end of an otherwise successful venv setup; a
        # failure to parse an optional listing must not fail the whole setup.
        { Get-CcmVenvBootstrapPackages -PipListJson 'not json at all' } | Should -Not -Throw
        @(Get-CcmVenvBootstrapPackages -PipListJson 'not json at all').Count | Should -Be 0
    }

    It "handles empty, whitespace and null input" {
        @(Get-CcmVenvBootstrapPackages -PipListJson '').Count | Should -Be 0
        @(Get-CcmVenvBootstrapPackages -PipListJson "   `n  ").Count | Should -Be 0
        @(Get-CcmVenvBootstrapPackages -PipListJson $null).Count | Should -Be 0
    }

    It "ignores entries without a usable name" {
        $json = '[{"version":"1.0"},{"name":null},{"name":"pip","version":"24.0"}]'

        Get-CcmVenvBootstrapPackages -PipListJson $json | Should -Be @('pip')
    }
}

Describe "Get-CcmVenvBootstrapPackages against real uv output" -Skip:(-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    It "selects the packages uv reports in a freshly seeded venv" {
        $venv = Join-Path ([System.IO.Path]::GetTempPath()) ("ccm-venv-" + [Guid]::NewGuid().ToString('N'))
        $previousVirtualEnv = $env:VIRTUAL_ENV
        try {
            & uv venv $venv 2>$null | Out-Null
            $env:VIRTUAL_ENV = $venv
            & uv pip install --quiet pip setuptools 2>$null | Out-Null

            $listing = & uv pip list --format json 2>$null
            $LASTEXITCODE | Should -Be 0

            Get-CcmVenvBootstrapPackages -PipListJson $listing | Should -Be @('pip', 'setuptools')
        }
        finally {
            $env:VIRTUAL_ENV = $previousVirtualEnv
            if (Test-Path $venv) { Remove-Item $venv -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe "setup-venv.ps1 bootstrap refresh" {
    BeforeAll { $script:Script = Get-Content (Join-Path $script:ModuleRoot "setup-venv.ps1") -Raw }

    It "selects the packages to upgrade through the shared function" {
        $script:Script | Should -Match "Get-CcmVenvBootstrapPackages"
    }

    It "only upgrades when at least one bootstrap package is present" {
        $script:Script | Should -Match '\$bootstrap_packages\.Count -gt 0'
        $script:Script | Should -Match 'pip install --upgrade'
    }

    It "fails the setup when the upgrade itself fails" {
        $script:Script | Should -Match 'Unable to upgrade bootstrap tooling'
    }
}
