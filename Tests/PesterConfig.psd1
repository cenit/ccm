# Local-development Pester configuration (see "Testing" in README.md).
# CI does not read this file: .github/workflows/ci.yml builds its own
# configuration inline, with code coverage enabled and per-OS output paths.
@{
    Run = @{
        Path = './Tests'
        Exit = $true
    }
    TestResult = @{
        Enabled = $true
        OutputFormat = 'NUnitXml'
        OutputPath = './pester-results.xml'
    }
    CodeCoverage = @{
        Enabled = $false
    }
    Output = @{
        Verbosity = 'Detailed'
    }
}
