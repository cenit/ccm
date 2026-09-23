# Pester tests for Get-CcmImageBuildArgs, which assembles the --build-arg list
# for a container image build and injects APP_VERSION.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot ".." "CCM.psd1") -Force
}

Describe "Get-CcmImageBuildArgs - APP_VERSION injection" {
    It "injects APP_VERSION when the caller passes no build args at all" {
        $built = Get-CcmImageBuildArgs -Version '1.2.3'

        $built | Should -Be @('--build-arg', 'APP_VERSION=1.2.3')
    }

    It "injects APP_VERSION ahead of the caller's own build args" {
        $built = Get-CcmImageBuildArgs -Version '1.2.3' -BuildArgs 'VITE_API_URL=https://example.com'

        $built | Should -Be @(
            '--build-arg', 'APP_VERSION=1.2.3',
            '--build-arg', 'VITE_API_URL=https://example.com'
        )
    }

    It "pairs every caller build arg with its own --build-arg flag" {
        $built = Get-CcmImageBuildArgs -Version '9.9.9' -BuildArgs @('A=1', 'B=2', 'C=3')

        # 1 injected pair + 3 caller pairs
        $built.Count | Should -Be 8
        ($built | Where-Object { $_ -eq '--build-arg' }).Count | Should -Be 4
    }

    It "accepts a non-semantic version, such as a preview image tag" {
        # Preview builds resolve Version from an image tag like pr-<id>-<sha>.
        # Reporting that verbatim is more useful than reporting nothing.
        $built = Get-CcmImageBuildArgs -Version 'pr-42-abc1234'

        $built | Should -Be @('--build-arg', 'APP_VERSION=pr-42-abc1234')
    }
}

Describe "Get-CcmImageBuildArgs - caller override" {
    It "does not inject when the caller supplies its own APP_VERSION" {
        $built = Get-CcmImageBuildArgs -Version '1.2.3' -BuildArgs 'APP_VERSION=override'

        $built | Should -Be @('--build-arg', 'APP_VERSION=override')
    }

    It "never emits APP_VERSION twice, which would leave the winner up to the builder" {
        $built = Get-CcmImageBuildArgs -Version '1.2.3' -BuildArgs @('X=1', 'APP_VERSION=override', 'Y=2')

        ($built | Where-Object { $_ -like 'APP_VERSION=*' }).Count | Should -Be 1
        $built | Should -Contain 'APP_VERSION=override'
        $built | Should -Not -Contain 'APP_VERSION=1.2.3'
    }
}

Describe "Get-CcmImageBuildArgs - degenerate input" {
    It "omits APP_VERSION rather than emitting an empty one when no version is known" {
        # An empty APP_VERSION is worse than none: the image would report a blank
        # version instead of falling back to the Dockerfile's own ARG default.
        $built = Get-CcmImageBuildArgs -Version ''

        $built | Should -BeNullOrEmpty
    }

    It "skips blank entries in the caller's build args" {
        $built = Get-CcmImageBuildArgs -Version '1.0.0' -BuildArgs @('A=1', '', '  ')

        $built | Should -Be @('--build-arg', 'APP_VERSION=1.0.0', '--build-arg', 'A=1')
    }

    It "returns an array even for a single pair, so splatting stays predictable" {
        $built = Get-CcmImageBuildArgs -Version '1.0.0'

        $built -is [array] | Should -BeTrue
    }
}
