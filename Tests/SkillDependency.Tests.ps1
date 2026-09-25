BeforeAll {
    $script:ModuleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:ModuleRoot 'CCM.psd1') -Force
}

Describe 'ConvertFrom-CcmSkillRequirement' {
    It 'parses a single entry' {
        $r = @(ConvertFrom-CcmSkillRequirement -Requirement 'my-skill>=1.0.0')
        $r.Count | Should -Be 1
        $r[0].SkillName  | Should -Be 'my-skill'
        $r[0].MinVersion | Should -Be '1.0.0'
    }

    It 'parses several comma-separated entries' {
        $r = @(ConvertFrom-CcmSkillRequirement -Requirement 'my-skill>=1.0.0, other-skill>=2.3.4')
        $r.Count | Should -Be 2
        $r[1].SkillName  | Should -Be 'other-skill'
        $r[1].MinVersion | Should -Be '2.3.4'
    }

    It 'tolerates whitespace around the operator' {
        $r = @(ConvertFrom-CcmSkillRequirement -Requirement '  my-skill >= 1.0.0  ')
        $r[0].SkillName  | Should -Be 'my-skill'
        $r[0].MinVersion | Should -Be '1.0.0'
    }

    It 'accepts a prerelease minimum' {
        $r = @(ConvertFrom-CcmSkillRequirement -Requirement 'my-skill>=1.0.0-beta.1')
        $r[0].MinVersion | Should -Be '1.0.0-beta.1'
    }

    It 'returns nothing for an empty string' {
        @(ConvertFrom-CcmSkillRequirement -Requirement '').Count | Should -Be 0
    }

    It 'returns nothing for whitespace' {
        @(ConvertFrom-CcmSkillRequirement -Requirement '   ').Count | Should -Be 0
    }

    It 'throws when the operator is missing' {
        { ConvertFrom-CcmSkillRequirement -Requirement 'my-skill 1.0.0' } |
            Should -Throw -ExpectedMessage "*Invalid requires entry*"
    }

    It 'throws when the version is not semver' {
        { ConvertFrom-CcmSkillRequirement -Requirement 'my-skill>=1.0' } |
            Should -Throw -ExpectedMessage "*Invalid requires entry*"
    }

    It 'throws when the name has illegal characters' {
        { ConvertFrom-CcmSkillRequirement -Requirement 'My_Skill>=1.0.0' } |
            Should -Throw -ExpectedMessage "*Invalid requires entry*"
    }

    It 'tolerates a trailing comma' {
        $r = @(ConvertFrom-CcmSkillRequirement -Requirement 'my-skill>=1.0.0,')
        $r.Count | Should -Be 1
        $r[0].SkillName  | Should -Be 'my-skill'
        $r[0].MinVersion | Should -Be '1.0.0'
    }

    It 'tolerates an empty segment between entries' {
        $r = @(ConvertFrom-CcmSkillRequirement -Requirement 'my-skill>=1.0.0,,other-skill>=2.0.0')
        $r.Count | Should -Be 2
        $r[0].SkillName  | Should -Be 'my-skill'
        $r[0].MinVersion | Should -Be '1.0.0'
        $r[1].SkillName  | Should -Be 'other-skill'
        $r[1].MinVersion | Should -Be '2.0.0'
    }

    It 'throws when a malformed entry appears alongside a valid one' {
        { ConvertFrom-CcmSkillRequirement -Requirement 'my-skill>=1.0.0, base-skill 2.0.0' } |
            Should -Throw -ExpectedMessage "*Invalid requires entry*"
    }
}

Describe 'Test-CcmSkillDependencyGraph' {
    It 'accepts a graph with no dependencies' {
        $graph = @{
            'my-skill'    = @{ Version = '1.0.0'; Requires = '' }
            'other-skill' = @{ Version = '2.0.0'; Requires = '' }
        }
        @(Test-CcmSkillDependencyGraph -Skill $graph).Count | Should -Be 0
    }

    It 'accepts a satisfied same-repo dependency' {
        $graph = @{
            'my-skill'   = @{ Version = '1.0.0'; Requires = 'base-skill>=1.0.0' }
            'base-skill' = @{ Version = '1.2.0'; Requires = '' }
        }
        @(Test-CcmSkillDependencyGraph -Skill $graph).Count | Should -Be 0
    }

    It 'rejects a same-repo dependency below the declared minimum' {
        $graph = @{
            'my-skill'   = @{ Version = '1.0.0'; Requires = 'base-skill>=2.0.0' }
            'base-skill' = @{ Version = '1.2.0'; Requires = '' }
        }
        $errors = @(Test-CcmSkillDependencyGraph -Skill $graph)
        $errors.Count | Should -Be 1
        $errors[0]    | Should -BeLike '*my-skill*base-skill>=2.0.0*1.2.0*'
    }

    It 'ignores a dependency that lives in another repo' {
        # Not present in the map: the pipeline checks the feed for these.
        $graph = @{ 'my-skill' = @{ Version = '1.0.0'; Requires = 'elsewhere-skill>=1.0.0' } }
        @(Test-CcmSkillDependencyGraph -Skill $graph).Count | Should -Be 0
    }

    It 'reports a malformed entry instead of throwing' {
        $graph = @{ 'my-skill' = @{ Version = '1.0.0'; Requires = 'base-skill 1.0.0' } }
        $errors = @(Test-CcmSkillDependencyGraph -Skill $graph)
        $errors.Count | Should -Be 1
        $errors[0]    | Should -BeLike '*my-skill*Invalid requires entry*'
    }

    It 'rejects a self-dependency' {
        $graph = @{ 'my-skill' = @{ Version = '1.0.0'; Requires = 'my-skill>=1.0.0' } }
        $errors = @(Test-CcmSkillDependencyGraph -Skill $graph)
        $errors | Where-Object { $_ -like '*cycle*' } | Should -Not -BeNullOrEmpty
    }

    It 'rejects a two-node cycle' {
        $graph = @{
            'skill-a' = @{ Version = '1.0.0'; Requires = 'skill-b>=1.0.0' }
            'skill-b' = @{ Version = '1.0.0'; Requires = 'skill-a>=1.0.0' }
        }
        $errors = @(Test-CcmSkillDependencyGraph -Skill $graph)
        $errors | Where-Object { $_ -like '*cycle*' } | Should -Not -BeNullOrEmpty
    }

    It 'accepts a diamond, which is not a cycle' {
        $graph = @{
            'top'   = @{ Version = '1.0.0'; Requires = 'left>=1.0.0, right>=1.0.0' }
            'left'  = @{ Version = '1.0.0'; Requires = 'base>=1.0.0' }
            'right' = @{ Version = '1.0.0'; Requires = 'base>=1.0.0' }
            'base'  = @{ Version = '1.0.0'; Requires = '' }
        }
        @(Test-CcmSkillDependencyGraph -Skill $graph).Count | Should -Be 0
    }

    It 'compares versions numerically, not as strings' {
        # '10.0.0' -lt '9.0.0' as a string comparison; as versions it is not.
        $graph = @{
            'my-skill'   = @{ Version = '1.0.0'; Requires = 'base-skill>=9.0.0' }
            'base-skill' = @{ Version = '10.0.0'; Requires = '' }
        }
        @(Test-CcmSkillDependencyGraph -Skill $graph).Count | Should -Be 0
    }
}

Describe 'New-CcmSkillNuspecContent' {
    It 'produces the exact 15-line nuspec a no-requires skill produced before dependency support existed' {
        # This is the backward-compatibility guarantee the whole feature
        # depends on: pinned byte-for-byte, not just by shape, so a change to
        # this function that alters even one existing line for every skill is
        # caught here.
        $lines = New-CcmSkillNuspecContent -PackageId 'skill-my-skill' -Version '1.0.0' `
            -Description 'An example skill.' -SkillDirectory 'C:\repo\my-skill' `
            -ContentTarget 'content\my-skill'

        $expected = @(
            '<?xml version="1.0" encoding="utf-8"?>',
            '<package xmlns="http://schemas.microsoft.com/packaging/2010/07/nuspec.xsd">',
            '  <metadata>',
            '    <id>skill-my-skill</id>',
            '    <version>1.0.0</version>',
            '    <authors>Stefano Sinigardi</authors>',
            '    <owners>Stefano Sinigardi</owners>',
            '    <description>An example skill.</description>',
            '    <requireLicenseAcceptance>false</requireLicenseAcceptance>',
            '    <tags>claude-skill codex</tags>',
            '  </metadata>',
            '  <files>',
            '    <file src="C:\repo\my-skill\**\*" target="content\my-skill" exclude="**\*.log;**\.git\**" />',
            '  </files>',
            '</package>'
        )

        @($lines).Count | Should -Be 15
        $lines | Should -Be $expected
    }

    It 'places <dependencies> inside <metadata>, one <dependency> per entry, with the right id and version' {
        $lines = New-CcmSkillNuspecContent -PackageId 'skill-my-skill' -Version '1.0.0' `
            -Description 'An example skill.' -SkillDirectory 'C:\repo\my-skill' `
            -ContentTarget 'content\my-skill' `
            -Dependency @(
                [pscustomobject]@{ Id = 'skill-base-skill'; MinVersion = '1.0.0' }
                [pscustomobject]@{ Id = 'skill-other-skill'; MinVersion = '2.3.4' }
            )

        $metadataOpen  = [array]::IndexOf($lines, '  <metadata>')
        $metadataClose = [array]::IndexOf($lines, '  </metadata>')
        $depOpen       = [array]::IndexOf($lines, '    <dependencies>')
        $depClose      = [array]::IndexOf($lines, '    </dependencies>')

        $metadataOpen  | Should -BeGreaterOrEqual 0
        $depOpen       | Should -BeGreaterThan $metadataOpen
        $depClose      | Should -BeLessThan $metadataClose

        $dependencyLines = @($lines | Where-Object { $_ -match '<dependency ' })
        $dependencyLines.Count | Should -Be 2
        $dependencyLines[0] | Should -BeLike '*id="skill-base-skill"*version="1.0.0"*'
        $dependencyLines[1] | Should -BeLike '*id="skill-other-skill"*version="2.3.4"*'
    }

    It 'produces valid, parseable XML when the skill declares no dependencies' {
        $lines = New-CcmSkillNuspecContent -PackageId 'skill-my-skill' -Version '1.0.0' `
            -Description 'An example skill.' -SkillDirectory 'C:\repo\my-skill' `
            -ContentTarget 'content\my-skill'

        { [xml]($lines -join "`n") } | Should -Not -Throw
    }

    It 'produces valid, parseable XML when the skill declares dependencies' {
        $lines = New-CcmSkillNuspecContent -PackageId 'skill-my-skill' -Version '1.0.0' `
            -Description 'An example skill.' -SkillDirectory 'C:\repo\my-skill' `
            -ContentTarget 'content\my-skill' `
            -Dependency @([pscustomobject]@{ Id = 'skill-base-skill'; MinVersion = '1.0.0' })

        $xmlText = $lines -join "`n"
        { [xml]$xmlText } | Should -Not -Throw
        $xml = [xml]$xmlText
        $xml.package.metadata.dependencies.dependency.id      | Should -Be 'skill-base-skill'
        $xml.package.metadata.dependencies.dependency.version | Should -Be '1.0.0'
    }

    It 'trims a description over 3900 characters and appends an ellipsis' {
        $longDesc = 'x' * 4000
        $lines = New-CcmSkillNuspecContent -PackageId 'skill-my-skill' -Version '1.0.0' `
            -Description $longDesc -SkillDirectory 'C:\repo\my-skill' -ContentTarget 'content\my-skill'

        $descriptionLine = $lines | Where-Object { $_ -match '<description>' }
        $descriptionLine | Should -Be ('    <description>' + ('x' * 3900) + '...</description>')
    }

    It 'XML-escapes special characters in the description' {
        $lines = New-CcmSkillNuspecContent -PackageId 'skill-my-skill' -Version '1.0.0' `
            -Description 'Tom & Jerry <chase>' -SkillDirectory 'C:\repo\my-skill' -ContentTarget 'content\my-skill'

        $descriptionLine = $lines | Where-Object { $_ -match '<description>' }
        $descriptionLine | Should -Be '    <description>Tom &amp; Jerry &lt;chase&gt;</description>'
    }
}
