Describe "azure-pipelines-ecs.yml - pandocDocuments" {
    BeforeAll {
        $script:TemplatePath = Join-Path $PSScriptRoot ".." "azure-pipelines-ecs.yml"
        $script:TemplateText = Get-Content $script:TemplatePath -Raw
    }

    It "declares the parameter" {
        $script:TemplateText | Should -Match '(?m)^\s*-\s*name:\s*pandocDocuments\s*$'
    }

    It "defaults to empty, so no existing consumer changes behaviour" {
        # A default of [] means the each-loop emits no steps at all and the
        # publish is skipped: adopting this must not impose pandoc on every
        # project already extending this template.
        $script:TemplateText | Should -Match 'pandocDocuments[\s\S]{0,120}?default:\s*\[\]'
    }

    It "gates the publish on a non-empty list" {
        $script:TemplateText | Should -Match "if\s+gt\(length\(parameters\.pandocDocuments\),\s*0\)"
    }

    It "uses only placeholder identifiers in its documentation" {
        # CCM ships to people with no connection to any given consumer, and a
        # project's very existence can be the sensitive part - so the template
        # must document itself with placeholders, never with a real project.
        #
        # This asserts POSITIVELY, on the placeholders, rather than listing real
        # consumer names as forbidden needles. A deny-list would have to spell
        # those names out, which would ship the very thing it exists to keep
        # out: the leak would live in this file instead of the template. The
        # deny-list grep is a contributor's pre-PR check, run in their own
        # session, and it deliberately does not belong in the module.
        $examples = [regex]::Matches($script:TemplateText, '(?m)^\s*#\s*(input|output):\s*(\S+)')
        $examples.Count | Should -BeGreaterThan 0 -Because "the parameter documents its own shape"
        foreach ($m in $examples) {
            $m.Groups[2].Value | Should -Match '^docs/my-doc\.(md|pdf)$'
        }
    }

    It "embeds no AWS account id other than the documented placeholder" {
        # Generic, so it catches any real account id without naming one: any
        # 12-digit run that is not the documented placeholder is a leak.
        foreach ($m in [regex]::Matches($script:TemplateText, '\b\d{12}\b')) {
            $m.Value | Should -Be '123456789012'
        }
    }
}

Describe "azure-pipelines-ecs.yml - extraEnv" {
    BeforeAll {
        $script:TemplatePath = Join-Path $PSScriptRoot ".." "azure-pipelines-ecs.yml"
        $script:TemplateText = Get-Content $script:TemplatePath -Raw
    }

    It "declares the parameter" {
        $script:TemplateText | Should -Match '(?m)^\s*-\s*name:\s*extraEnv\s*$'
    }

    It "defaults to an empty mapping, so no existing consumer changes behaviour" {
        # {} means both each-loops emit nothing and every env: block is byte
        # identical to before: adopting this must be a no-op for existing consumers.
        $script:TemplateText | Should -Match 'extraEnv[\s\S]{0,80}?default:\s*\{\}'
    }

    It "reaches both image-build steps, not just production" {
        # A preview build runs the same pre-build.ps1 hook as production, so a
        # credential wired only into BuildImage makes every PR preview fail
        # while master stays green - the slowest possible way to find out.
        $loops = [regex]::Matches(
            $script:TemplateText, '\$\{\{\s*each\s+pair\s+in\s+parameters\.extraEnv\s*\}\}')
        $loops.Count | Should -Be 2
    }

    It "expands as a key/value mapping under env:" {
        $script:TemplateText | Should -Match '\$\{\{\s*pair\.key\s*\}\}:\s*\$\{\{\s*pair\.value\s*\}\}'
    }

    It "never routes extraEnv into build args" {
        # buildArgs become --build-arg and are readable in the image history;
        # the whole point of a separate parameter is that secrets do not go
        # there. Guard the two from ever being joined together.
        $script:TemplateText | Should -Not -Match "join\(\s*'\|\|'\s*,\s*parameters\.extraEnv\s*\)"
        $script:TemplateText | Should -Not -Match 'CCM_BUILD_ARGS:.*parameters\.extraEnv'
    }

    It "uses only placeholder identifiers in its documentation" {
        # Same rule as pandocDocuments above: CCM ships outside any one
        # consumer, so the example must not name a real service or variable.
        $script:TemplateText | Should -Match '(?m)^\s*#\s*MY_REGISTRY_TOKEN:\s*\$\(MY_REGISTRY_TOKEN\)\s*$'
    }
}

Describe "CCM version bump" {
    It "is at least 1.26.0" {
        $manifest = Import-PowerShellDataFile (Join-Path $PSScriptRoot ".." "CCM.psd1")
        [version]$manifest.ModuleVersion | Should -BeGreaterOrEqual ([version]"1.26.0")
    }
}
