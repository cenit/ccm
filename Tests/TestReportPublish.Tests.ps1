# How a Python test report is produced and published.
#
# CCM owns both ends of this and they have to agree. ci-checks.ps1 writes a JUnit
# report (--junitxml=test-unit.xml) and a Cobertura coverage file (--cov-report=xml),
# and the pipeline templates publish them. Anything that introduces a SECOND reporter
# breaks the agreement in two ways at once: the extra file gets collected by a publish
# task configured for a format it is not in, and its results are published twice.
#
# That is exactly what installing pytest-azurepipelines did. It pulls in pytest-nunit,
# writes an NUnit report to ./test-output.xml, and publishes it itself with
# ##vso[results.publish type=NUnit]. The templates' '**/test-*.xml' JUnit publish then
# collected that NUnit file and warned "Failed to read ... test-output.xml" on every
# build, in every consumer project on these templates.

Describe "Python test reporting has exactly one producer" {
    BeforeAll {
        $setupVenvPath = Join-Path $PSScriptRoot ".." "setup-venv.ps1"
        $script:SetupVenvText = Get-Content $setupVenvPath -Raw
        # Comments only, stripped: the block explaining why the plugin is gone names
        # it, and a test that forbade the word would force the reason to be deleted
        # along with the install. Assert on what the script DOES.
        $script:SetupVenvCode = (
            Get-Content $setupVenvPath | Where-Object { $_ -notmatch '^\s*#' }
        ) -join "`n"
        $script:CiChecksText = Get-Content (Join-Path $PSScriptRoot ".." "ci-checks.ps1") -Raw
    }

    It "does not install pytest-azurepipelines" {
        # A second reporter CCM does not ask for and does not read. Its NUnit report
        # collided with the templates' JUnit publish, and it double-published every
        # run's results once that file was parseable.
        $script:SetupVenvCode | Should -Not -Match 'pytest-azurepipelines'
    }

    It "keeps the reason on record" {
        # The install is one line; why it must not come back is the part worth
        # protecting, and the only place a future contributor will look.
        $script:SetupVenvText | Should -Match 'pytest-azurepipelines'
    }

    It "still installs the packages ci-checks actually invokes" {
        # pytest for the run, pytest-cov because ci-checks always passes --cov.
        $script:SetupVenvText | Should -Match '\bpytest\b'
        $script:SetupVenvText | Should -Match 'pytest-cov'
    }

    It "asks pytest for the JUnit report itself" {
        # The reason nothing else needs to: CCM names the file it publishes.
        $script:CiChecksText | Should -Match '--junitxml=test-unit\.xml'
    }

    It "asks pytest for the coverage report itself" {
        # Removing pytest-azurepipelines must not silently drop coverage: it used to
        # default --cov-report=xml on, and ci-checks passing it explicitly is what
        # makes that removal safe.
        $script:CiChecksText | Should -Match '--cov-report=xml'
    }
}

Describe "The JUnit publish collects only JUnit reports" {
    BeforeAll {
        $script:Templates = @{
            'azure-pipelines-ecs.yml' = Get-Content (Join-Path $PSScriptRoot ".." "azure-pipelines-ecs.yml") -Raw
            'azure-pipelines-cpp.yml' = Get-Content (Join-Path $PSScriptRoot ".." "azure-pipelines-cpp.yml") -Raw
        }
    }

    It "<name> does not collect every test-*.xml in the tree" -ForEach @(
        @{ name = 'azure-pipelines-ecs.yml' }
        @{ name = 'azure-pipelines-cpp.yml' }
    ) {
        # '**/test-*.xml' is a format-blind net: it matches any file a plugin happens
        # to name test-something.xml and hands it to a JUnit parser.
        $script:Templates[$name] | Should -Not -Match "testResultsFiles:\s*'\*\*/test-\*\.xml'"
    }

    It "<name> names the two reports CCM produces" -ForEach @(
        @{ name = 'azure-pipelines-ecs.yml' }
        @{ name = 'azure-pipelines-cpp.yml' }
    ) {
        # Still recursive: ci-checks documents test-frontend.xml at the repo root, but
        # a JS runner's reporter resolves relative to the frontend directory, so the
        # '**/' has to stay or those results silently stop being published.
        $script:Templates[$name] | Should -Match '\*\*/test-unit\.xml'
        $script:Templates[$name] | Should -Match '\*\*/test-frontend\.xml'
    }

    It "<name> still declares the format it parses" -ForEach @(
        @{ name = 'azure-pipelines-ecs.yml' }
        @{ name = 'azure-pipelines-cpp.yml' }
    ) {
        $script:Templates[$name] | Should -Match "testResultsFormat:\s*'JUnit'"
    }
}
