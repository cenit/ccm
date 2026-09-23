BeforeAll {
    $script:ModuleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:ModuleRoot 'CCM.psd1') -Force
}

Describe 'Resolve-CcmContainerRuntime' {

    Context 'auto-detect (no preference)' {
        It 'prefers wslc when all three are present' {
            Mock Get-Command -ModuleName CCM -ParameterFilter { $Name -in @('wslc','docker','podman') } -MockWith { [pscustomobject]@{ Name = $Name } }
            (Resolve-CcmContainerRuntime).Kind | Should -Be 'wslc'
        }

        It 'falls back to docker when wslc is absent' {
            Mock Get-Command -ModuleName CCM -ParameterFilter { $Name -eq 'wslc' } -MockWith { $null }
            Mock Get-Command -ModuleName CCM -ParameterFilter { $Name -in @('docker','podman') } -MockWith { [pscustomobject]@{ Name = $Name } }
            (Resolve-CcmContainerRuntime).Kind | Should -Be 'docker'
        }

        It 'falls back to podman when wslc and docker are absent' {
            Mock Get-Command -ModuleName CCM -ParameterFilter { $Name -in @('wslc','docker') } -MockWith { $null }
            Mock Get-Command -ModuleName CCM -ParameterFilter { $Name -eq 'podman' } -MockWith { [pscustomobject]@{ Name = 'podman' } }
            (Resolve-CcmContainerRuntime).Kind | Should -Be 'podman'
        }

        It 'throws when no runtime is present' {
            Mock Get-Command -ModuleName CCM -ParameterFilter { $Name -in @('wslc','docker','podman') } -MockWith { $null }
            { Resolve-CcmContainerRuntime } | Should -Throw '*No container runtime found*'
        }
    }

    Context 'explicit preference (hard requirement)' {
        It 'returns the requested tool when present' {
            Mock Get-Command -ModuleName CCM -ParameterFilter { $Name -eq 'podman' } -MockWith { [pscustomobject]@{ Name = 'podman' } }
            (Resolve-CcmContainerRuntime -Prefer 'podman').Kind | Should -Be 'podman'
        }

        It 'throws when the requested tool is missing' {
            Mock Get-Command -ModuleName CCM -ParameterFilter { $Name -eq 'wslc' } -MockWith { $null }
            { Resolve-CcmContainerRuntime -Prefer 'wslc' } | Should -Throw '*not found*'
        }
    }

    Context 'compose requirement excludes wslc' {
        It 'skips wslc and returns docker in auto-detect' {
            Mock Get-Command -ModuleName CCM -ParameterFilter { $Name -in @('wslc','docker','podman') } -MockWith { [pscustomobject]@{ Name = $Name } }
            (Resolve-CcmContainerRuntime -RequireCompose).Kind | Should -Be 'docker'
        }

        It 'throws the no-compose message when wslc is explicitly requested' {
            { Resolve-CcmContainerRuntime -Prefer 'wslc' -RequireCompose } | Should -Throw '*no compose support yet*'
        }
    }

    Context 'parameter validation' {
        It 'rejects an unknown -Prefer value' {
            { Resolve-CcmContainerRuntime -Prefer 'containerd' } | Should -Throw
        }
    }
}
