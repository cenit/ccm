#!/usr/bin/env pwsh
<#
.SYNOPSIS
  ci-checks — run the standard Python/frontend quality gates.
.DESCRIPTION
  Single entry point for backend + frontend quality gates, shared by the
  aws-ecs (azure-pipelines-ecs.yml@ccm) and python-package pipeline templates.
  Sets up the Python venv + frontend deps, then runs bandit, pip/npm license +
  CVE gates, lint, pytest, the frontend test suite and the frontend build.
  Auto-detects the stack;
  reads deliberate overrides from the optional "ci" block of a project config
  file — ecs-config.json for aws-ecs projects, or any JSON file (e.g.
  ci-config.json) for python-package projects that don't have one.
.PARAMETER ConfigFile
  Path to the project's JSON config file holding the optional "ci" overrides
  block (default ./ecs-config.json). python-package projects without an
  ecs-config.json typically pass -ConfigFile ./ci-config.json instead.
.PARAMETER PythonVersion
  Python version to pin for the venv (forwarded to setup-venv.ps1).
.PARAMETER DoNotUpdateTOOL
  Forwarded to setup-venv.ps1.
.PARAMETER DisableInteractive
  Forwarded to setup-venv.ps1.
.PARAMETER DetectOnly
  Define functions and return without running setup or gates (for unit tests).
.PARAMETER TestMarkers
  Pytest marker expression (-m). Overrides ci.testMarkers when passed, including
  as an empty string, which means "no -m flag: run everything". Lets one
  pipeline run a fast subset on push and the full suite on a schedule without
  duplicating the config.
#>
param(
    [string]$ConfigFile = "./ecs-config.json",
    [string]$PythonVersion = "",
    [switch]$DoNotUpdateTOOL,
    [switch]$DisableInteractive,
    [switch]$DetectOnly,
    # Pytest marker expression (-m). Overrides ci.testMarkers when passed,
    # including as an empty string, which means "no -m flag: run everything".
    # Lets one pipeline run a fast subset on push and the full suite on a
    # schedule without duplicating the config.
    [string]$TestMarkers
)

$ci_checks_ps1_version = "1.12.2"

# Resolved here, at the SCRIPT's own scope, where $PSBoundParameters correctly
# reflects what was passed to this script invocation (see the comment on
# Get-CiPlan's TestMarkersSet parameter for why this can't be re-derived
# inside that function).
$testMarkersSet = $PSBoundParameters.ContainsKey('TestMarkers')

# ─── Pure detection (unit-tested; no side effects) ───────────────────────────
function Get-CiPlan {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$ConfigFile = "",
        # TestMarkers + TestMarkersSet (rather than re-deriving from
        # $PSBoundParameters in here): $PSBoundParameters inside a function is
        # scoped to THAT function's own bound parameters, not the caller's, so
        # it can never see whether the outer script's -TestMarkers was passed.
        # The caller must resolve ContainsKey('TestMarkers') at its own scope
        # and pass the result in explicitly.
        [string]$TestMarkers = $null,
        [bool]$TestMarkersSet = $false
    )
    $ci = $null
    if ($ConfigFile -and (Test-Path $ConfigFile)) {
        $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        if ($cfg.PSObject.Properties.Name -contains 'ci') { $ci = $cfg.ci }
    }
    # ci.hasBackend explicitly overrides autodetection for projects whose Python
    # backend predates pyproject.toml (requirements.txt-only layouts). Absent =
    # autodetect, i.e. unchanged for every existing consumer. skipBackend still
    # wins, so it stays a reliable kill switch.
    #
    # $null -ne $ci.hasBackend (not a plain truthiness check) is deliberate:
    # $ci.hasBackend being $false must still count as "explicitly set", the
    # same class of bug as -TestMarkers ''. $backendDetected is also
    # deliberately not named $hasBackend - PowerShell variable names are
    # case-insensitive, so that would collide with the [bool] value assigned
    # two lines below via the same slot, same trap as $resolvedTestMarkers.
    $py = Join-Path $RepoRoot 'pyproject.toml'
    $backendDetected = if ($null -ne $ci.hasBackend) { [bool]$ci.hasBackend } else { Test-Path $py }
    $hasBackend = (-not ($ci.skipBackend)) -and $backendDetected

    $frontendDir = if ($ci.frontendDir) { $ci.frontendDir } else { 'frontend' }
    $hasFrontend = (-not ($ci.skipFrontend)) -and (Test-Path (Join-Path $RepoRoot (Join-Path $frontendDir 'package.json')))

    $linter = if ($ci.linter) { [string]$ci.linter } else { 'auto' }
    if ($linter -eq 'auto') {
        if ((Test-Path $py) -and (Select-String -Path $py -Pattern '^\[tool\.ruff' -Quiet)) {
            $linter = 'ruff'
        } elseif ((Test-Path $py) -and (Select-String -Path $py -Pattern '^\[tool\.(black|isort)' -Quiet)) {
            $linter = 'black-isort'
        } else {
            $linter = 'none'
        }
    }
    if ($ci.skipLinting) { $linter = 'none' }

    # Which package.json script holds the suite. Configurable because plenty of
    # frontends keep the CI-shaped run under 'test:ci' / 'test:unit' and leave a
    # bare watch-mode 'test' for developers. Resolved outside the $hasFrontend
    # block so the plan always reports a concrete name.
    $frontendTestScript = if ($ci.frontendTestScript) { [string]$ci.frontendTestScript } else { 'test' }

    $frontendLint = $false
    $frontendTest = $false
    if ($hasFrontend) {
        $pkg = Get-Content (Join-Path $RepoRoot (Join-Path $frontendDir 'package.json')) -Raw | ConvertFrom-Json
        $frontendLint = ($pkg.scripts -and ($pkg.scripts.PSObject.Properties.Name -contains 'lint'))
        if ((-not $ci.skipFrontendTests) -and $pkg.scripts -and ($pkg.scripts.PSObject.Properties.Name -contains $frontendTestScript)) {
            # `npm init` scaffolds "test": "echo \"Error: no test specified\" && exit 1",
            # which exits 1 by design. Treating that as a suite would turn "this
            # project never wrote frontend tests" into a red build the moment it
            # bumps its CCM ref, so the placeholder counts as no suite at all.
            $frontendTest = ([string]$pkg.scripts.$frontendTestScript) -notmatch 'no test specified'
        }
    }

    # Wrap the whole conditional in @(): an if/elseif block emits its value through
    # the pipeline, which unwraps a single-element array back to a scalar string. A
    # scalar SourcePaths then splats char-by-char (`@srcArgs` -> b,a,c,k,...), so
    # black/isort/flake8 receive 'b' instead of 'backend/'. @() forces an array in
    # every branch regardless of element count.
    $sourcePaths = @(
        if ($ci.sourcePaths) { $ci.sourcePaths }
        elseif (Test-Path (Join-Path $RepoRoot 'backend')) { 'backend/' }
        else { 'src/' }
    )

    # Test paths + coverage target are overridable via the ci block for projects
    # whose suite isn't a single root tests/ dir (e.g. split across backend/tests
    # + tests). Defaults preserve the previous hardcoded behaviour. Same @()
    # wrapping as SourcePaths so a single-element override isn't unwrapped to a
    # scalar and then splatted char-by-char into pytest.
    $testPaths = @(
        if ($ci.testPaths) { $ci.testPaths }
        else { 'tests/' }
    )
    $covTarget = if ($ci.covTarget) { [string]$ci.covTarget } else { 'backend' }

    # Marker expression: an explicitly-passed -TestMarkers wins over the config
    # value (TestMarkersSet, resolved by the caller via its own PSBoundParameters,
    # so an intentional empty string still counts).
    #
    # NB: this local is deliberately NOT named $testMarkers. PowerShell variable
    # names are case-insensitive, so $testMarkers and the [string]-typed
    # parameter $TestMarkers would be the SAME variable slot; once a variable
    # has been bound through a [string] parameter, later assignments to it
    # (even $null) get silently coerced to "" instead of staying $null.
    $resolvedTestMarkers = if ($TestMarkersSet) { $TestMarkers }
                           elseif ($ci.testMarkers) { [string]$ci.testMarkers }
                           else { $null }

    # Strict-typing gate. An explicit ci.mypyPaths still wins; otherwise the gate
    # turns itself on when the project declares mypy config in any of the places
    # mypy itself reads it from, and targets SourcePaths. Same "declared config =
    # intent" principle as the ruff / black-isort autodetection above.
    #
    # Unlike a linter config, a [tool.mypy] block is quite often kept only for
    # editors or pre-commit and is NOT backed by a clean full-repo run - so
    # ci.skipMypy is the documented kill switch, and it deliberately wins over an
    # explicit ci.mypyPaths too (same precedence as skipBackend over hasBackend):
    # a skip that some other key can defeat is not a reliable off switch.
    $mypyPaths = @($ci.mypyPaths | Where-Object { $_ })
    if ($mypyPaths.Count -eq 0) {
        $setupCfg = Join-Path $RepoRoot 'setup.cfg'
        $mypyConfigured =
            (Test-Path (Join-Path $RepoRoot 'mypy.ini')) -or
            (Test-Path (Join-Path $RepoRoot '.mypy.ini')) -or
            ((Test-Path $py) -and (Select-String -Path $py -Pattern '^\[tool\.mypy' -Quiet)) -or
            ((Test-Path $setupCfg) -and (Select-String -Path $setupCfg -Pattern '^\[mypy\]' -Quiet))
        # @() for the same reason as SourcePaths itself: a single-element result
        # must not collapse to a scalar and then splat char-by-char into mypy.
        if ($mypyConfigured) { $mypyPaths = @($sourcePaths) }
    }
    if ($ci.skipMypy) { $mypyPaths = @() }

    # Opt-in coverage threshold: absent = coverage reported but never gated.
    $covFailUnder = if ($null -ne $ci.covFailUnder) { $ci.covFailUnder } else { $null }

    # ci.auditRequirements: extra requirements files that must be CVE-scanned
    # even though they are NOT installed into the CI venv - e.g. an aws-ecs
    # project's Dockerfile installs a disjoint backend/requirements.txt, not
    # the root requirements.txt this venv was built from (requirements-dev.txt
    # -r-includes it), so the manifest that actually ships to production was
    # never scanned by the pip-audit gate above. Opt-in, empty by default:
    # unchanged for every existing consumer. Same @() wrapping as
    # SourcePaths/TestPaths - a single-element override must not collapse to
    # a scalar string and then splat char-by-char.
    $auditRequirements = @($ci.auditRequirements | Where-Object { $_ })

    return @{
        HasBackend         = [bool]$hasBackend
        HasFrontend        = [bool]$hasFrontend
        FrontendDir        = $frontendDir
        Linter             = $linter
        FrontendLint       = [bool]$frontendLint
        FrontendTest       = [bool]$frontendTest
        FrontendTestScript = $frontendTestScript
        SourcePaths        = $sourcePaths
        TestPaths          = $testPaths
        TestMarkers        = $resolvedTestMarkers
        CovTarget          = $covTarget
        CovFailUnder       = $covFailUnder
        MypyPaths          = $mypyPaths
        PipAuditIgnores    = @($ci.pipAuditIgnores | Where-Object { $_ })
        AuditRequirements  = $auditRequirements
        NpmAuditIgnores    = @($ci.npmAuditIgnores | Where-Object { $_ })
        PipLicenseIgnores  = @($ci.pipLicenseIgnores | Where-Object { $_ })
        ApiClientDrift     = $ci.apiClientDrift
        # Default $false: plain 'npm ci', with npm's real peer resolution. A
        # project whose install genuinely needs the old behaviour opts in with
        # ci.npmLegacyPeerDeps=true. --legacy-peer-deps skips peer resolution
        # entirely, so a devDependency that ships a required package only as a
        # peer never lands in node_modules and every type-check fails on its
        # re-exports (e.g. @testing-library/react v16, which ships
        # @testing-library/dom only as a peer). Silently masking that class of
        # breakage for everyone is worse than making the projects that actually
        # need the flag declare it.
        NpmLegacyPeerDeps  = [bool]$ci.npmLegacyPeerDeps
    }
}

# ─── Pure validation (unit-tested; throws, never exits) ──────────────────────
# Split out from the pip-audit gate loop so it's unit-testable without
# invoking `exit` directly - exit would terminate the whole Pester process,
# not just fail one assertion. Throws (rather than returning a bool) so the
# gate loop can translate it into the file's usual
# ##vso[task.logissue]/exit 1 shape, while a test can assert with Should
# -Throw. Validates every entry up front, before running any pip-audit, so a
# typo'd path fails immediately rather than after auditing earlier manifests.
function Assert-AuditRequirementsExist {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string[]]$AuditRequirements = @()
    )
    foreach ($reqFile in @($AuditRequirements)) {
        $reqPath = Join-Path $RepoRoot $reqFile
        # A missing/typo'd path must fail loudly, not be silently skipped -
        # that would quietly recreate the exact gap ci.auditRequirements
        # exists to close (a manifest that ships to production going unscanned).
        if (-not (Test-Path $reqPath)) {
            throw "ci.auditRequirements entry not found: $reqFile"
        }
    }
}

# Whether an SPDX licence expression leaves the consumer NO option but strong
# copyleft. Pure and unit-tested, for the same reason as the function above.
#
# `OR` in SPDX is a CHOICE offered to the consumer, not a constraint placed on
# them: `(MIT OR GPL-3.0-or-later)` may be taken as MIT, so it carries no
# copyleft obligation and is not a violation. jszip ships exactly that
# expression and reaches many projects through exceljs, so a gate that
# cannot read the `OR` fails every one of those repos over a licence they are
# free not to choose.
#
# `AND` is the opposite -- every term applies -- so it is deliberately NOT
# split: a single GPL term inside an AND is binding, and the whole expression
# is then a violation.
#
# LGPL stays permitted, matching the pip gate: dynamic linking against a
# replaceable library is not the obligation this gate exists to catch.
function Test-SpdxCopyleftOnly {
    param([string]$Expression)

    if ([string]::IsNullOrWhiteSpace($Expression)) { return $false }

    # license-checker emits an unknown licence as the literal '(UNKNOWN)' and a
    # multi-licence package with parentheses it does not otherwise mean, so the
    # outer wrapping is stripped before the expression is split.
    $alternatives = [regex]::Split($Expression.Trim(), '(?i)\s+OR\s+')
    foreach ($alternative in $alternatives) {
        $term = $alternative.Trim().Trim('(', ')').Trim()
        $isStrongCopyleft = ($term -match '(A?GPL|GNU [A-Za-z ]*General Public License)') -and
                            ($term -notmatch 'Lesser General Public License|LGPL')
        # One permissive alternative is a way out, so the whole expression is
        # acceptable and nothing else needs checking.
        if (-not $isStrongCopyleft) { return $false }
    }
    return $true
}

# ─── Report-artifact ignore patterns ─────────────────────────────────────────
# Every root-level file/directory ci-checks.ps1 itself can produce below, none
# of which are meant to be committed. Kept as a single ordered list (rather
# than inlined at the Add-IgnorePatternBlock call site) so there is one place
# to update when a gate's output filename changes, and so the list is
# assertable from Pester via -DetectOnly without running the whole script.
# pip-audit*.json covers both the CI-venv report (pip-audit.json) and the
# per-manifest reports from ci.auditRequirements, whose names are derived from
# the (arbitrary, config-supplied) requirements file path - see the "pip-audit
# (strict, SHIPPED manifest...)" gate further down.
$CiReportArtifactPatterns = @(
    'bandit-report.json'
    'pip-licenses.csv'
    'pip-audit*.json'
    'coverage.xml'
    '.coverage'
    'test-unit.xml'
    # Not written by ci-checks itself: it is the documented filename a project's
    # frontend test script points its JUnit reporter at, and one of the two names
    # the templates' publish collects alongside pytest's test-unit.xml. Ignored
    # here for the same reason - a CI-generated report that must never be
    # committed.
    'test-frontend.xml'
    'npm-licenses.csv'
    'npm-audit.json'
    'security-reports-staging/'
)

if ($DetectOnly) {
    # Emit the resolved plan so -DetectOnly is actually inspectable from the CLI
    # (e.g. to check TestMarkers precedence) without running gates or triggering
    # side effects: NOT moved past the boilerplate below on purpose, since that
    # would run Initialize-CcmLogging (starts a transcript, patches
    # .gitignore/.dockerignore) and the module imports before returning, and
    # would also compute the plan before $ErrorActionPreference = 'Stop' / the
    # trap are in place, weakening error handling for the real run.
    $RepoRoot = (Get-Location).Path
    $plan = Get-CiPlan -RepoRoot $RepoRoot -ConfigFile $ConfigFile -TestMarkers $TestMarkers -TestMarkersSet:$testMarkersSet
    Write-Host "CI plan: $($plan | ConvertTo-Json -Compress)"
    return
}

# ─── Boilerplate (logging) ───────────────────────────────────────────────────
$script_name = $MyInvocation.MyCommand.Name
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (Test-Path $ScriptDir/utils.psm1) { Import-Module -Name $ScriptDir/utils.psm1 -Force }
if (Test-Path (Join-Path $ScriptDir "CCM.psd1")) { Import-Module -Name (Join-Path $ScriptDir "CCM.psd1") -Force }
$ccmLog = Initialize-CcmLogging
trap { Stop-CcmLogging $ccmLog; break }
$ErrorActionPreference = "Stop"

Write-Host "ci-checks script version ${ci_checks_ps1_version}"
Write-Host "Script name: $script_name"

$RepoRoot = (Get-Location).Path
$plan = Get-CiPlan -RepoRoot $RepoRoot -ConfigFile $ConfigFile -TestMarkers $TestMarkers -TestMarkersSet:$testMarkersSet
Write-Host "CI plan: $($plan | ConvertTo-Json -Compress)"

# ─── Security-report staging (created up front) ──────────────────────────────
# The pipeline publishes these reports with condition: always(), so the staging
# directory MUST exist even when a gate fails — otherwise the publish step errors
# with "PathtoPublish ... Not found" and masks the real gate failure. Create it
# before any gate runs and copy each report the instant it is produced, so a gate
# failure still surfaces the bandit / pip-audit JSON (exactly what's needed then).
$ReportStaging = Join-Path $RepoRoot 'security-reports-staging'
New-Item -ItemType Directory -Force -Path $ReportStaging | Out-Null

# None of the report artifacts above/below (including $ReportStaging itself)
# are meant to be committed - patch them into .gitignore now, before any gate
# can exit 1, the same way Initialize-CcmLogging (already called above) patches
# in its own transcript-log pattern. A separate BlockId keeps this block
# independent of the logging one; $ccmLog.RepoRoot/-IsContainerized are reused
# rather than re-derived, so this only patches when Initialize-CcmLogging
# itself found a repo (and, for .dockerignore, a containerized one) to patch.
if ($ccmLog.RepoRoot) {
    Add-IgnorePatternBlock -Path (Join-Path $ccmLog.RepoRoot '.gitignore') -Pattern $CiReportArtifactPatterns -BlockId 'CCM ci-checks artifacts' -CreateIfMissing $true -ManagedBy 'ci-checks.ps1' | Out-Null
    if ($ccmLog.IsContainerized) {
        Add-IgnorePatternBlock -Path (Join-Path $ccmLog.RepoRoot '.dockerignore') -Pattern $CiReportArtifactPatterns -BlockId 'CCM ci-checks artifacts' -CreateIfMissing $true -ManagedBy 'ci-checks.ps1' | Out-Null
    }
}

function Save-Report {
    # cmdlet-only — does NOT touch $LASTEXITCODE, so it's safe to call between a
    # native command and its exit-code check.
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path $Path) { Copy-Item -Path $Path -Destination $ReportStaging -Force }
}

function Invoke-Gate {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    Write-Host "=== $Name ==="
    & $Body
    if ($LASTEXITCODE -ne 0) {
        Write-Host "##vso[task.logissue type=error]$Name failed (exit $LASTEXITCODE)"
        exit 1
    }
}

# ─── Environment setup ───────────────────────────────────────────────────────
# Force Python's UTF-8 mode for every Python invocation the rest of this
# script can reach: setup-venv's own pip installs, black/isort/flake8, mypy,
# bandit, pip-audit, pytest, and any ci.apiClientDrift schema dump. Set here,
# unconditionally and ahead of the $plan.HasBackend guard below, rather than
# inside it or next to any one gate.
#
# Deliberately NOT inside `if ($plan.HasBackend)`: ci.apiClientDrift is its
# own top-level `if ($plan.ApiClientDrift)` further down, not nested under
# HasBackend, and Get-CiPlan never actually requires HasBackend to be true
# for ApiClientDrift to be set - the two are only linked by convention (a
# schema dump needs a Python backend to produce anything), not by code. A
# project configured that way while HasBackend somehow resolves false would
# still run a Python process with the encoding trap below live if this sat
# inside the guard. Moving it out costs nothing on a frontend-only repo: it's
# an environment variable only Python reads, and python/pip aren't even on
# PATH there.
#
# Caught via isort 9.x, but isort is not the hazard - the agent codepage is.
# A Windows build agent's ANSI codepage (cp1252 on typical Windows agents) is
# what Python falls back to for its default text encoding when nothing
# overrides it, so any Python tool that opens a project source file
# containing a character outside cp1252 can hit an encoding error. isort
# catches that error, prints a UserWarning ("Unable to parse file <path>
# due to 'charmap' codec can't encode character '∈' ... character maps
# to <undefined>"), SKIPS the file, and still exits 0. The gate then
# reports green - a false green, because the file most likely to contain
# that character (say, a docstring with a math symbol) is exactly the file
# that was never linted; a genuine sort violation in it sails through
# undetected. black, flake8, bandit, mypy and pytest all read the same
# project source under the same agent codepage, so scoping this to the
# isort invocation would fix today's report and leave the identical trap
# set for the next tool and the next non-ASCII character.
#
# PYTHONUTF8=1 (Python's UTF-8 mode) makes UTF-8 the default text encoding
# everywhere - locale.getpreferredencoding() and stdio both - independent
# of the OS codepage, which removes the cause rather than papering over one
# tool's symptom. It is also where CPython itself is heading: PEP 686 makes
# UTF-8 mode the default from Python 3.15, so this is a forward-compatible
# default, not a workaround that will need undoing later.
# PYTHONIOENCODING is deliberately NOT set alongside it: UTF-8 mode already
# makes stdio UTF-8, and PYTHONIOENCODING only affects stream encoding, not
# the default-encoding fallback isort's file-open trips over here.
$env:PYTHONUTF8 = '1'

if ($plan.HasBackend) {
    # Hashtable splat binds by NAME. An array splat (@(...)) would bind positionally,
    # and since setup-venv's only positional param is [string]$PythonVersion, the
    # leading '-DisableInteractive' token would land there → 'uv venv --python -DisableInteractive'.
    $venvArgs = @{ DisableInteractive = $true }
    if ($DoNotUpdateTOOL) { $venvArgs.DoNotUpdateTOOL = $true }
    if (Test-Path 'requirements-dev.txt') { $venvArgs.DevRequirements = $true } else { $venvArgs.DevExtras = $true }
    if ($PythonVersion) { $venvArgs.PythonVersion = $PythonVersion }
    & "$ScriptDir/setup-venv.ps1" @venvArgs
    if ($LASTEXITCODE -ne 0) { Write-Host "##vso[task.logissue type=error]setup-venv failed"; exit 1 }
    # Cross-platform venv activation (Scripts/ on Windows, bin/ on Linux; handles uv venvs).
    Enable-PythonVenv -VenvPath (Join-Path $RepoRoot '.venv')
}
if ($plan.HasFrontend) {
    Push-Location $plan.FrontendDir
    if ($plan.NpmLegacyPeerDeps) { npm ci --legacy-peer-deps } else { npm ci }
    if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Host "##vso[task.logissue type=error]npm ci failed"; exit 1 }
    Pop-Location
}

# ─── API client drift gate (opt-in via ecs-config.json ci.apiClientDrift) ─────
# Regenerates an OpenAPI schema + typed client and fails if the committed
# artifacts differ, so a backend API change that lands without a regenerated,
# committed client blocks the build. Runs after venv + npm deps are ready so
# both the schema dump (Python) and the client codegen (npm) can execute; the
# same script call developers run locally exercises this identically.
if ($plan.ApiClientDrift) {
    $drift = $plan.ApiClientDrift
    Write-Host "=== API client drift gate ==="

    # Some schema dumps import the app, which may require settings/env at import
    # time. Export declared dummy (non-secret) env vars before the dump.
    if ($drift.env) {
        foreach ($p in $drift.env.PSObject.Properties) {
            [Environment]::SetEnvironmentVariable($p.Name, [string]$p.Value)
        }
    }

    if ($drift.schemaCommand) {
        Invoke-Expression $drift.schemaCommand
        if ($LASTEXITCODE -ne 0) { Write-Host "##vso[task.logissue type=error]API client drift: schema dump failed"; exit 1 }
    }

    if ($drift.generateCommand) {
        $genDir = if ($drift.generateDir) { [string]$drift.generateDir } else { '.' }
        Push-Location $genDir
        try {
            Invoke-Expression $drift.generateCommand
            if ($LASTEXITCODE -ne 0) { Write-Host "##vso[task.logissue type=error]API client drift: client generation failed"; exit 1 }
        } finally { Pop-Location }
    }

    $driftPaths = @($drift.paths | Where-Object { $_ })
    if ($driftPaths.Count -eq 0) { Write-Host "##vso[task.logissue type=error]ci.apiClientDrift.paths is required"; exit 1 }
    git diff --exit-code -- @driftPaths
    if ($LASTEXITCODE -ne 0) {
        Write-Host "=== Uncommitted regeneration diff ==="
        git --no-pager diff --stat -- @driftPaths
        Write-Host "##vso[task.logissue type=error]API client is out of date — re-run the schema dump + client generation and commit the regenerated files."
        exit 1
    }
    Write-Host "API client is in sync with the backend schema."
}

# ─── Python gates ────────────────────────────────────────────────────────────
if ($plan.HasBackend) {
    # @() guards against a scalar slipping through: splatting a string enumerates its
    # characters, so a bare 'backend/' would pass 'b' as the first source path.
    $srcArgs = @($plan.SourcePaths)

    if ($plan.Linter -eq 'ruff') {
        Invoke-Gate 'Lint: ruff format --check' { python -m ruff format --check @srcArgs }
        Invoke-Gate 'Lint: ruff check'          { python -m ruff check @srcArgs }
    } elseif ($plan.Linter -eq 'black-isort') {
        Invoke-Gate 'Code style: black --check'        { python -m black --check @srcArgs }
        # isort by CONSOLE SCRIPT, not `python -m isort`. isort 9.0.0 ships an
        # __main__.py with no code object, so `-m` dies with "No code object
        # available for isort.__main__" and exits 1 before linting a single file.
        # A consumer needs no change of its own to hit this: the ceiling is
        # typically open (`isort>=5.13.2`), so the next resolve brings 9 in.
        # Enable-PythonVenv has already put the venv's Scripts/ (bin/ on Linux) on
        # PATH, and the console script behaves identically on 8 and 9.
        # black and flake8 still support -m and are deliberately left alone.
        Invoke-Gate 'Code style: isort --check-only'   { isort --check-only @srcArgs }
        Invoke-Gate 'Lint: flake8'                      { python -m flake8 @srcArgs }
    } else {
        Write-Host "Linting skipped (linter=none)"
    }

    # Strict typing, autodetected from declared mypy config or ci.mypyPaths (see
    # Get-CiPlan). Config (strict mode, per-module overrides) comes from the
    # project's mypy.ini / setup.cfg / [tool.mypy]; only the targets are passed.
    if ($plan.MypyPaths.Count -gt 0) {
        $mypyArgs = @($plan.MypyPaths)
        # Preflight: since the gate can now switch itself on from a config block
        # alone, "mypy configured but never added to the dev dependencies" is a
        # realistic first-contact failure. Without this it surfaces as
        # 'MyPy failed (exit 1)' over a 'No module named mypy' traceback, which
        # reads like a type error and sends people looking in the wrong place.
        python -c "import mypy" 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "##vso[task.logissue type=error]mypy is configured for this project (mypy.ini / setup.cfg [mypy] / [tool.mypy], or ci.mypyPaths) but is not installed in the CI venv. Add mypy to requirements-dev.txt or the project's dev extra, or set ci.skipMypy to true."
            exit 1
        }
        Invoke-Gate 'Static analysis: MyPy (per project config)' { python -m mypy @mypyArgs }
    }

    Write-Host "=== Bandit (Python SAST, strict on MEDIUM+) ==="
    python -m bandit -r @srcArgs -f json -o bandit-report.json -ll --exit-zero
    Save-Report 'bandit-report.json'
    python -m bandit -r @srcArgs -ll
    if ($LASTEXITCODE -ne 0) { Write-Host "##vso[task.logissue type=error]Bandit found issues at MEDIUM+ severity"; exit 1 }

    Write-Host "=== License audit: pip (strict, fail on GPL/AGPL) ==="
    pip-licenses --format=csv --output-file pip-licenses.csv
    Save-Report 'pip-licenses.csv'
    $gplDeny = 'GNU General Public License (GPL);GNU General Public License v2 (GPLv2);GNU General Public License v2 or later (GPLv2+);GNU General Public License v3 (GPLv3);GNU General Public License v3 or later (GPLv3+);GNU Affero General Public License v3;GNU Affero General Public License v3 or later (AGPLv3+);GPL;GPLv2;GPLv2+;GPLv3;GPLv3+;AGPL;AGPLv3;AGPLv3+;GPL-2.0;GPL-2.0+;GPL-2.0-only;GPL-2.0-or-later;GPL-3.0;GPL-3.0+;GPL-3.0-only;GPL-3.0-or-later;AGPL-3.0;AGPL-3.0+;AGPL-3.0-only;AGPL-3.0-or-later'
    $plFailed = $false
    # ci.pipLicenseIgnores exempts specific packages from the deny gate + oddball
    # check below — e.g. a build-only tool distributed under GPL-with-exception
    # (PyInstaller's bootloader exception) that never ships in the product itself.
    # Each entry MUST be a documented, deliberate exemption, not a blanket mute.
    $licenseIgnores = @($plan.PipLicenseIgnores)
    if ($licenseIgnores.Count -gt 0) {
        pip-licenses --fail-on="$gplDeny" --ignore-packages @licenseIgnores > $null 2>&1
    } else {
        pip-licenses --fail-on="$gplDeny" > $null 2>&1
    }
    if ($LASTEXITCODE -ne 0) { $plFailed = $true }
    $oddball = Import-Csv pip-licenses.csv | Where-Object {
        $_.Name -notin $licenseIgnores -and
        $_.License -match '(A?GPL|GNU [A-Za-z ]*General Public License)' -and
        $_.License -notmatch 'Lesser General Public License|LGPL'
    }
    if ($plFailed -or $oddball) {
        Write-Host "##vso[task.logissue type=error]GPL/AGPL license found in Python dependencies"
        if ($oddball) { $oddball | Format-Table -AutoSize }
        exit 1
    }
    if ($licenseIgnores.Count -gt 0) {
        Write-Host "Python license check passed (LGPL allowed; exempted: $($licenseIgnores -join ', '))."
    } else {
        Write-Host "Python license check passed (LGPL allowed)."
    }

    Write-Host "=== CVE gate: pip-audit (strict, CI venv) ==="
    $auditArgs = @('--skip-editable', '--format=json', '--output=pip-audit.json')
    foreach ($cve in $plan.PipAuditIgnores) { if ($cve) { $auditArgs += @('--ignore-vuln', $cve) } }
    python -m pip_audit @auditArgs
    Save-Report 'pip-audit.json'
    if ($LASTEXITCODE -ne 0) { Write-Host "##vso[task.logissue type=error]pip-audit found CVEs (CI venv)"; Get-Content pip-audit.json; exit 1 }

    # ci.auditRequirements: scan manifests that ship to production but are NOT
    # installed into the CI venv above - e.g. an aws-ecs project's Dockerfile
    # installs a disjoint backend/requirements.txt, while this venv was built
    # from the root requirements-dev.txt/requirements.txt. Without this, "a
    # CVE fails the build" is only true for the wrong dependency set: the one
    # that never reaches the image gets scanned, and the one that does
    # doesn't. `pip-audit -r <file>` resolves an unpinned manifest to the
    # versions a fresh install would get - the same thing a Docker build
    # does - so this models production without needing a second venv.
    try {
        Assert-AuditRequirementsExist -RepoRoot $RepoRoot -AuditRequirements $plan.AuditRequirements
    } catch {
        Write-Host "##vso[task.logissue type=error]$($_.Exception.Message)"
        exit 1
    }
    # @() so a single-element ci.auditRequirements isn't unwrapped to a
    # scalar and splatted char-by-char (same trap as SourcePaths/TestPaths).
    foreach ($reqFile in @($plan.AuditRequirements)) {
        $reqPath = Join-Path $RepoRoot $reqFile
        # Sanitized, path-derived report name: distinguishes multiple
        # manifests in the report artifact and avoids collisions between
        # same-named requirements.txt files in different subdirectories.
        $reqReportName = "pip-audit-$($reqFile -replace '[\\/]', '-').json"
        Write-Host "=== CVE gate: pip-audit (strict, SHIPPED manifest: $reqFile) ==="
        $reqAuditArgs = @('-r', $reqPath, '--format=json', "--output=$reqReportName")
        foreach ($cve in $plan.PipAuditIgnores) { if ($cve) { $reqAuditArgs += @('--ignore-vuln', $cve) } }
        python -m pip_audit @reqAuditArgs
        Save-Report $reqReportName
        if ($LASTEXITCODE -ne 0) {
            Write-Host "##vso[task.logissue type=error]pip-audit found CVEs in SHIPPED manifest $reqFile (this ships to production and is not covered by the CI-venv gate above)"
            Get-Content $reqReportName
            exit 1
        }
    }
}

# ─── Frontend gates ──────────────────────────────────────────────────────────
if ($plan.HasFrontend) {
    Push-Location $plan.FrontendDir
    try {
        if ($plan.FrontendLint) {
            Write-Host "=== Lint: frontend (npm run lint) ==="
            npm run lint
            if ($LASTEXITCODE -ne 0) { Write-Host "##vso[task.logissue type=error]Frontend lint failed"; exit 1 }
        }
        Write-Host "=== License audit: npm (strict, fail on GPL/AGPL; LGPL allowed) ==="
        npx --yes license-checker --csv --production --out "$RepoRoot/npm-licenses.csv"
        Save-Report "$RepoRoot/npm-licenses.csv"
        # LGPL is permitted (dynamic linking / replaceable libs), matching the Python
        # pip-licenses gate above. Reject only strong copyleft: GPL and AGPL.
        # `$_.license`, SINGULAR. license-checker's --csv header is
        # `"module name","license","repository"`, and this read `$_.licenses`
        # for the whole life of the gate -- a property that does not exist, so
        # every comparison ran against $null, `$violations` was always empty,
        # and the gate passed unconditionally on every repo using it. It
        # has never rejected anything. A gate that cannot fail is worse than no
        # gate, because it is an assurance nobody thinks to re-check.
        #
        # Splitting the SPDX expression is what keeps the fix from trading a
        # silent no-op for a false alarm: see Test-SpdxCopyleftOnly.
        $violations = Import-Csv "$RepoRoot/npm-licenses.csv" |
            Where-Object { Test-SpdxCopyleftOnly -Expression $_.license }
        if ($violations) { Write-Host "##vso[task.logissue type=error]GPL/AGPL license in npm production deps"; $violations | Format-Table -AutoSize; exit 1 }
        Write-Host "npm license check passed."

        Write-Host "=== CVE gate: npm audit (strict, production-only, HIGH+) ==="
        # npm audit has no native per-advisory ignore (unlike pip-audit's
        # --ignore-vuln), so we parse the --json report and evaluate severity
        # ourselves, dropping advisories explicitly allowlisted in ecs-config
        # (ci.npmAuditIgnores) by GHSA id. Each entry MUST be a documented,
        # not-applicable advisory (VEX "not affected"), not a blanket mute.
        # --omit=dev, not --production: npm deprecated the latter and prints
        # "npm warn config production Use `--omit=dev` instead" on every run.
        # Same scope (production dependencies only), no warning.
        npm audit --omit=dev --json | Out-File -Encoding utf8 "$RepoRoot/npm-audit.json"
        Save-Report "$RepoRoot/npm-audit.json"
        $audit = Get-Content "$RepoRoot/npm-audit.json" -Raw | ConvertFrom-Json
        $ignored = @($plan.NpmAuditIgnores)
        $blocking = @()
        $suppressed = @()
        foreach ($name in $audit.vulnerabilities.PSObject.Properties.Name) {
            foreach ($via in @($audit.vulnerabilities.$name.via)) {
                # String `via` = transitive pointer to another vulnerable package;
                # the real advisory object (with severity + GHSA url) is emitted
                # under that package, so only object entries are evaluated here.
                if ($via -is [string]) { continue }
                if ($via.severity -notin @('high', 'critical')) { continue }
                $ghsa = if ($via.url -match '(GHSA-[0-9a-z-]+)') { $Matches[1] } else { [string]$via.url }
                if ($ignored -contains $ghsa -or $ignored -contains ([string]$via.url)) {
                    $suppressed += "$ghsa ($name): $($via.title)"
                } else {
                    $blocking += "$($via.severity.ToUpper()) $ghsa ($name): $($via.title)"
                }
            }
        }
        if ($suppressed.Count -gt 0) {
            # No silent caps: always surface what the allowlist muted this run.
            Write-Host "npm audit: suppressed $($suppressed.Count) allowlisted HIGH+ advisory(ies):"
            $suppressed | Sort-Object -Unique | ForEach-Object { Write-Host "  - $_" }
        }
        if ($blocking.Count -gt 0) {
            Get-Content "$RepoRoot/npm-audit.json"
            $blocking | Sort-Object -Unique | ForEach-Object { Write-Host "  ! $_" }
            Write-Host "##vso[task.logissue type=error]npm audit found HIGH+ vulns"; exit 1
        }
        Write-Host "npm audit passed."
    } finally { Pop-Location }
}

# ─── Tests ───────────────────────────────────────────────────────────────────
if ($plan.HasBackend) {
    Write-Host "=== Pytest ==="
    # @() so a single-element TestPaths override doesn't splat char-by-char.
    $testArgs = @($plan.TestPaths)
    # Empty string = deliberate "run everything"; only a non-empty expression
    # becomes an -m flag.
    if (-not [string]::IsNullOrWhiteSpace($plan.TestMarkers)) {
        $testArgs += @('-m', $plan.TestMarkers)
        Write-Host "Pytest marker filter: -m `"$($plan.TestMarkers)`""
    }
    # Coverage target always; opt-in hard threshold (--cov-fail-under) only when
    # ci.covFailUnder is set — otherwise coverage is reported but never gates.
    $covArgs = @("--cov=$($plan.CovTarget)", "--cov-report=xml")
    if ($null -ne $plan.CovFailUnder) { $covArgs += "--cov-fail-under=$($plan.CovFailUnder)" }
    python -m pytest @testArgs @covArgs --junitxml=test-unit.xml
    if ($LASTEXITCODE -ne 0) { Write-Host "##vso[task.logissue type=error]pytest failed"; exit 1 }
}

# Frontend suite, autodetected from the package.json script (see Get-CiPlan) and
# disabled with ci.skipFrontendTests. Placed after the cheap lint/license/CVE
# gates so those fail first, and before the build below so a broken suite is
# reported as a test failure rather than a build one.
#
# The runner owns its own reporting: pointing it at a JUnit report named
# test-frontend.xml is what makes the pipeline templates' publish surface
# individual test names in the build summary. That publish collects
# '**/test-unit.xml' and '**/test-frontend.xml' by name, so the filename matters -
# an arbitrary test-something.xml is no longer collected, deliberately.
# No reporter flag is injected here - that would require knowing whether the
# project runs vitest, jest or node:test.
if ($plan.FrontendTest) {
    $frontendTestScript = $plan.FrontendTestScript
    Push-Location $plan.FrontendDir
    # vitest and playwright drop into interactive watch mode when they don't
    # believe they are on CI, which off-agent (this is also the script developers
    # run locally) is indistinguishable from a hung build. CI=true is the flag
    # every JS runner honours. Restored afterwards so nothing downstream inherits
    # a faked environment.
    $priorCI = $env:CI
    try {
        Write-Host "=== Frontend tests (npm run $frontendTestScript) ==="
        $env:CI = 'true'
        npm run $frontendTestScript
        if ($LASTEXITCODE -ne 0) { Write-Host "##vso[task.logissue type=error]Frontend tests failed"; exit 1 }
    } finally {
        # Assigning $null would delete the variable rather than restore an
        # absent one, so the two cases are handled separately.
        if ($null -eq $priorCI) { Remove-Item Env:\CI -ErrorAction SilentlyContinue } else { $env:CI = $priorCI }
        Pop-Location
    }
}

# ─── Frontend build (sanity) ─────────────────────────────────────────────────
if ($plan.HasFrontend) {
    Push-Location $plan.FrontendDir
    try {
        Write-Host "=== Frontend build (sanity check) ==="
        npm run build
        if ($LASTEXITCODE -ne 0) { Write-Host "##vso[task.logissue type=error]Frontend build failed"; exit 1 }
    } finally { Pop-Location }
}

# ─── Final report sweep (most are staged incrementally above) ────────────────
# Success-path backstop: on a gate failure the script has already exited after
# staging whatever reports were produced, so this only ever adds the last few.
foreach ($f in @('bandit-report.json', 'pip-licenses.csv', 'npm-licenses.csv', 'pip-audit.json', 'npm-audit.json')) { Save-Report $f }
Get-ChildItem $ReportStaging

Stop-CcmLogging $ccmLog
Write-Host "ci-checks complete."
