# cenit CI/CD Modules (CCM)

A comprehensive collection of build automation, continuous integration and development environment setup tools. This repository provides cross-platform build scripts, CMake modules and deployment automation for various development environments.

## Consumption modes

CCM is meant to be vendored as a **git submodule** at `<project>/CCM/`. Projects
use the standalone `.ps1` scripts (`build.ps1`, `deploy-ecs.ps1`, etc.) directly
from that path, and the CMake modules by adding `CCM/Modules` (and `CCM/Functions`)
to `CMAKE_MODULE_PATH`.

The PowerShell utilities are the `CCM` module: `Import-Module ./CCM/CCM.psd1`.
`Import-Module ./CCM/utils.psm1` keeps working too; it is a back-compat shim that
forwards to the module (see [Changes from `utils.psm1` 1.x](#changes-from-utilspsm1-1x)).

## Changes from `utils.psm1` 1.x

2.0.0 restructured the repository. Old names keep working unless noted:

| Before | Now |
|---|---|
| `utils.psm1` (single file) | `CCM` module (`CCM.psd1`, `CCM.psm1`, `Public/`, `Private/`); `utils.psm1` is a shim that imports it |
| `activateVenv`, `MyThrow`, `DownloadNinja`, `setupVisualStudio`, ... | Verb-noun functions (`Enable-PythonVenv`, `Write-CcmFatalError`, `Save-Ninja`, `Initialize-VisualStudioEnvironment`, ...); the old names are exported aliases. See [Function naming](#function-naming) |
| `build-tc.ps1` | `build-tc.py` (captures the TwinCAT automation-interface COM output reliably) |
| `setup_eng.md` | `setup_cpp.md` (same content) |
| per-script `Start-Transcript` to `<script>.log` | `Initialize-CcmLogging` / `Stop-CcmLogging` (see [Logging](#logging)) |

Module functions now run with `$ErrorActionPreference = 'Stop'`.

## C++ pipeline template

C++ (CMake + vcpkg) projects share one Azure DevOps pipeline template,
`azure-pipelines-cpp.yml`, instead of each carrying a near-identical copy.
Reference it from the project's own `azure-pipelines.yml` with a thin stub.
CCM is used two ways here: as a **pipeline resource** (`@ccm`) for the template,
and as the usual **submodule** (`CCM/` or legacy `cmake/`) for `build.ps1`.

```yaml
name: <project>-$(Date:yyyyMMdd)$(Rev:.r)
trigger:
  branches: { include: [master, main, dev/*, release/*] }
pr:
  branches: { include: [main, master] }
schedules:
  # Weekly buildability/compliance check, independent of commits.
  - cron: '0 6 * * 1'
    displayName: 'Weekly build (Mondays 06:00 UTC)'
    branches: { include: [main, master] }
    always: true
resources:
  repositories:
    - repository: ccm
      type: github
      name: cenit/ccm
      endpoint: my-github-connection   # a GitHub service connection
      ref: refs/heads/master
extends:
  template: azure-pipelines-cpp.yml@ccm
  parameters:
    ccmPath: CCM          # 'cmake' for projects on the legacy submodule folder
    platforms: [windows]
    installerType: cpack
```

`trigger`, `pr`, and `schedules` MUST stay in the stub — Azure DevOps ignores
them when defined inside an extended template.

### Parameters

| Param | Type | Default | Purpose |
|---|---|---|---|
| `ccmPath` | string | `CCM` | Submodule path to `build.ps1` (use `cmake` on the legacy layout) |
| `platforms` | object | `[windows]` | One job per entry; `linux` → CPack `.deb`/`.rpm` |
| `windowsPool` | string | `Default` | Agent pool for the Windows job |
| `linuxPool` | string | `Default` | Agent pool for the Linux job |
| `enableTests` | boolean | `true` | Debug build `-EnableTEST` → fail-fast ctest → publish JUnit |
| `enableDebugBuild` | boolean | `false` | Debug compile-check build for projects without a ctest suite (`enableTests` already implies it) |
| `enableOrt` | boolean | `true` | ORT license/compliance via `build-ort.ps1`, reports published as `<repo>_ort_report` |
| `ortExtraArguments` | string | `''` | Extra `build-ort.ps1` switches, e.g. `-EnableCustomVCPKGRegistry -DoNotUpdateVCPKG` on agents that pre-provision an externally-managed vcpkg registry |
| `ortProjectFeatures` | object | `[]` | vcpkg manifest features to produce per-feature ORT reports for (one `build-ort.ps1 -ProjectFeatures` run per entry, outputs renamed `<repo>_disclosure_document_<feature>.pdf`/`.html`); empty → single default-features report |
| `additionalBuildSetup` | string | `''` | Extra CMake args forwarded as `build.ps1 -AdditionalBuildSetup` on Debug/Release builds (also pass cache-sticky options explicitly to keep reused workspaces deterministic) |
| `installerType` | string | `cpack` | `cpack` → `build.ps1 -BuildInstaller`; `none` → skip installer |
| `installerGlob` | string | `''` (platform default) | Override staged artifact pattern |
| `buildDir` | string | `build_release` | Where CPack output lands |
| `vcpkgBinarySources` | string | `clear;default,readwrite` | Override (e.g. a NuGet or S3 binary cache) |
| `timeoutInMinutes` | number | `720` | Job timeout — sized for full from-source dependency rebuilds after a vcpkg registry baseline move (self-hosted agents, no platform cap) |
| `versionHeaderPath` | string | `''` (skip) | If set, generate a version header before build |
| `gitSslNoVerify` | boolean | `false` | Escape hatch to re-enable cert bypass on a lagging agent |
| `extraSteps` | stepList | `[]` | Steps injected before publish (NSIS, WIX UI ext, multi-variant) |

The template bakes in these best practices unconditionally: pre-checkout
credential cleanup, `persistCredentials: false`, `System.AccessToken` vcpkg auth,
fail-fast tests, and cleanup-on-cancel. It deliberately does **not** set
`GIT_SSL_NO_VERIFY`; install your CA certificate into the agent trust store
instead, or use `gitSslNoVerify: true` as a temporary measure.

## AWS ECS pipeline template

AWS-ECS projects (Dockerfile + `ecs-config.json` + CCM submodule) share one
pipeline, `azure-pipelines-ecs.yml`, instead of each carrying a ~600-line copy.
Build-stage quality gates live in `CCM/ci-checks.ps1` (auto-detects the stack;
overrides via the `ci` block of `ecs-config.json`); the template calls it, then
drives image build/deploy through `CCM/deploy-ecs.ps1` and the preview scripts.

PR previews are **default ON**. The stub MUST include two schedules: the weekly
buildability build and a **daily** one whose displayName is exactly
`Daily preview cleanup` (the template keys its CleanupPreviews stage on it).

```yaml
name: <project>-$(Date:yyyyMMdd)$(Rev:.r)
trigger: { branches: { include: [master, main, dev/*] } }
pr: { branches: { include: [main, master] } }
schedules:
  - cron: '0 5 * * *'
    displayName: 'Daily preview cleanup'
    branches: { include: [main, master] }
    always: true
  - cron: '0 6 * * 1'
    displayName: 'Weekly build (Mondays 06:00 UTC)'
    branches: { include: [main, master] }
    always: true
resources:
  repositories:
    - repository: ccm
      type: github
      name: cenit/ccm
      endpoint: my-github-connection   # a GitHub service connection
      ref: refs/heads/master
extends:
  template: azure-pipelines-ecs.yml@ccm
  parameters:
    variableGroup: <project>-aws-deploy
    environment: <project>-aws-ecs
    hasMigrations: false        # true if the project has alembic migrations
    # prPreview defaults true; pool defaults Default; pythonVersion 3.12; nodeVersion 20.x
```

### Parameters

| Param | Type | Default | Purpose |
|---|---|---|---|
| `variableGroup` | string | *(required)* | AWS-creds variable group (e.g. `my-app-aws-deploy`) |
| `environment` | string | *(required)* | deploy environment; preview env is `<environment>-preview` |
| `pythonVersion` | string | `3.12` | passed to ci-checks/setup-venv |
| `nodeVersion` | string | `20.x` | `UseNode@1` version (was `NodeTool@0`, deprecated by Azure DevOps) |
| `nodeOptions` | string | `--max-old-space-size=4096` | applied as `NODE_OPTIONS` on the `ci-checks.ps1` frontend build sanity check, because large Vite bundles (multi-MB bundle + sourcemap) exceed Node's default heap even on an agent with ample memory; set `''` to omit `NODE_OPTIONS` entirely |
| `pool` | string | `Default` | self-hosted agent pool |
| `vmImage` | string | `''` | when set, jobs run on a Microsoft-hosted image instead of the self-hosted `pool` |
| `externalSubmodules` | boolean | `false` | set for a submodule hosted in a *different* Azure DevOps organization: the agent's own org-scoped auth header would make that fetch fail, so submodules are initialised in a separate, headerless step instead of via `submodules: recursive` |
| `submodulePatVariable` | string | `''` | name of the pipeline variable holding a PAT for a private external submodule (read only when `externalSubmodules: true`) |
| `hasMigrations` | boolean | `false` | include the Migrate stage |
| `prPreview` | boolean | `true` | include PreviewImage/PreviewDeploy/CleanupPreviews |
| `useTarContext` | boolean | `false` | append `-UseTarContext` to image builds |
| `noCache` | boolean | `false` | append `-NoCache` to image builds (production and preview). For a one-off run, queue with the pipeline variable `noCache=true` instead of committing — the steps also honour that. See "Corrupted layer cache" below |
| `previewBasePathBuildArg` | string | `''` | for path-routed frontend previews, the build-arg name (e.g. `VITE_BASE_PATH`) set to the PR base path |
| `buildArgs` | object | `[]` | `NAME=$(VAR)` strings → `deploy-ecs.ps1 -BuildArgs`, used by the production (`BuildImage`) build only. **`APP_VERSION` is injected automatically** from the version `deploy-ecs.ps1` already resolved, on production and preview builds alike, so an image declaring `ARG APP_VERSION` reports the version its tag carries without configuring anything. Images that do not declare it are unaffected — an unconsumed build arg is a warning, never an error. Pass your own `APP_VERSION` to override it |
| `previewBuildArgs` | object | `[]` | `NAME=value` strings used **only** by the `PreviewImage` build — independent of `buildArgs`, so a preview image can bake in a different value (e.g. `VITE_AUTH_DISABLED=true` to disable SSO in previews while prod keeps it on) |
| `extraEnv` | object | `{}` | `NAME: $(VAR)` mapping added to the environment of **both** image-build steps (`BuildImage` and `PreviewImage`). For **secret** variable-group entries: a non-secret group variable is already injected into every script step automatically, but a secret one is not, and mapping it needs a step-level `env:` a consumer cannot reach. Unlike `buildArgs` these never become `--build-arg`, so they stay out of the image's build history. Typical use: handing a credential to the repo's `pre-build.ps1` |
| `fullTestScheduleName` | string | `''` | displayName of the cron schedule that runs the full test suite: `ci.testMarkers` is cleared (nothing filtered), and `BuildImage`, `Migrate` and `Deploy` are all skipped on that run — it exists to test, not to deploy |

`fullTestScheduleName` is interpolated into a single-quoted runtime expression, so a schedule displayName containing an apostrophe will produce a malformed expression.

### `pre-build.ps1`

If a repo has a `pre-build.ps1` at its root, `deploy-ecs.ps1` runs it immediately
before `docker build`. It is the place to prepare the build *context* — fetch
weights, generate assets, stage a large artifact — and it is the consumer of
`extraEnv` above.

It runs **only when an image is actually being built**. A deploy-only invocation
(`-SkipBuild`, or `-ExternalImage` — what the `Deploy` and `PreviewDeploy` stages
pass) skips it, since its output would be discarded and the build-stage
resources it depends on are not there. Do not put deploy-time work in it.

### Corrupted layer cache on a self-hosted agent

A self-hosted agent's local image store can be silently corrupted — most often by
the build disk filling up mid-write, which truncates a large file inside a cached
layer. Nothing notices at build time: every subsequent build happily reports
`--> Using cache` and produces an image referencing the damaged layer. It only
surfaces at **push** time, when the layer is read back to be uploaded:

```
Error: reading blob sha256:<digest>: file integrity checksum failed for "usr/lib/.../<file>"
```

Read this as **local**, not a registry problem — `reading blob` is the local read,
and podman is comparing the layer's on-disk content against the digest recorded
when it was built. Two tells: the build log shows `--> Using cache` on every step,
and the push fails instantly without exhausting `--retry` (it is a deterministic
read error, not upload flakiness).

`deploy-ecs.ps1` handles this automatically: on that specific signature it rebuilds
the image with `--no-cache` — producing a fresh layer — and retries the push once.
If it still fails, the store needs clearing by hand.

Manual levers, in order of preference:

1. Queue a single run with the pipeline variable `noCache=true`, or set the
   `noCache: true` template parameter — no agent session needed.
2. On the agent, `podman image prune -a -f` to delete the damaged layer for good.
   Verify with `podman system df`, which also reports a related failure mode
   (`Image <id> exists in local storage but may be corrupted`) — clear that one with
   `podman rmi -f <full-id>`.

To reproduce or confirm the diagnosis cheaply, `podman save <image> > /dev/null`
walks every layer exactly as push does and reprints the same error in seconds.
Prefer it to `podman system check`, which hashes the entire store and — with a
remote client, which includes all Windows podman — runs *inside* `podman system
service`, so killing the client neither stops it nor recovers its output while it
holds the store lock.

Prevention: prune periodically. An unattended agent accumulates dead layers
indefinitely (a store that is >90% reclaimable is what fills the disk in the first
place); a weekly `podman image prune -a -f --filter until=168h` keeps a week of
warm cache while capping growth.

Deploy/image stages run on `main` + `master` only (dev/* and PRs are CI + previews only).

The `ci` block of `ecs-config.json` (all optional) tunes the gates: `linter`,
`skipLinting`, `skipBackend`, `hasBackend`, `skipFrontend`, `skipFrontendTests`,
`pipAuditIgnores`, `pipLicenseIgnores`, `npmAuditIgnores`, `npmLegacyPeerDeps`,
`auditRequirements`, `sourcePaths`, `frontendDir`, `frontendTestScript`,
`testPaths`, `testMarkers`, `covTarget`, `covFailUnder`, `mypyPaths`,
`skipMypy`, `apiClientDrift`. See `ecs-config.schema.json`.

`covTarget` is the package passed to `pytest --cov` (default `backend`);
`covFailUnder` adds `--cov-fail-under=<n>`. Without `covFailUnder`, coverage is
measured and published but never gates — set it to hold a floor.

`apiClientDrift` is an opt-in gate for projects that generate a typed frontend
client from the backend's OpenAPI schema: it re-runs the schema dump and the
codegen, then fails on `git diff` against the committed artifacts, so a backend
API change can't land without its regenerated client.

The frontend test gate is autodetected the same way `npm run lint` is: if the
frontend `package.json` defines a `test` script, `ci-checks` runs it and a
failure fails the build. `npm init`'s placeholder (`echo "Error: no test
specified" && exit 1`) does not count as a suite, so a project that never wrote
frontend tests is unaffected. Set `ci.frontendTestScript` for suites kept under
another name (`test:ci`, `test:unit`), or `ci.skipFrontendTests: true` to turn
the gate off while leaving the lint, license, CVE and build gates on.

`ci-checks` sets `CI=true` around the run, so a watch-mode runner (`vitest`,
`playwright`) executes once and exits instead of hanging — which matters most
when running this script locally, where a watch prompt is indistinguishable from
a stuck build. No reporter flag is injected: point the runner's JUnit reporter at
`test-frontend.xml` and the pipeline templates' publish will surface individual
test names in the build summary. That publish collects `**/test-unit.xml` and
`**/test-frontend.xml` **by name** — it is not a wildcard over every
`test-*.xml`, so the filename matters.

A project whose frontend suite has quietly rotted will go red once the gate
applies to it — that is the point of the gate, but fix the suite rather than
reaching for `skipFrontendTests` as a permanent setting.

### Strict typing (mypy)

The mypy gate is autodetected too: it runs against `sourcePaths` whenever the
project declares mypy config in any of the places mypy itself reads — `mypy.ini`,
`.mypy.ini`, `[tool.mypy]` in `pyproject.toml`, or `[mypy]` in `setup.cfg`.
Strictness and per-module overrides stay in that config; `ci-checks` passes only
the target paths. Set `ci.mypyPaths` to type-check something narrower than the
whole source tree, and `ci.skipMypy: true` to turn the gate off — `skipMypy`
wins over `mypyPaths`, so it is a reliable off switch whatever else is set.

mypy must be in the project's dev dependencies. Because the gate can now switch
itself on from a config block alone, a project that only ever ran mypy locally
gets a specific error naming `requirements-dev.txt` and `ci.skipMypy`, rather
than a bare `MyPy failed (exit 1)` over a `No module named mypy` traceback.

A `[tool.mypy]` block is often kept for editors or pre-commit without a
CI-clean full-repo run, so autodetection will turn the gate on for projects that
have never had it green. Before adopting or bumping CCM, run `python -m mypy <sourcePaths>` locally;
if it isn't clean and won't be soon, set `ci.skipMypy: true` deliberately rather
than discovering it in a red build.

`npmLegacyPeerDeps` defaults to `false`: frontends install with plain `npm ci`
and npm's real peer resolution. Set it to `true` only if `npm ci` fails on an
unresolvable peer conflict, and treat that as debt to fix in the manifest rather
than a permanent setting.

`--legacy-peer-deps` skips peer resolution entirely — so a devDependency
shipping a required package only as a peer never lands in `node_modules`, and
the type-check fails on its re-exports with errors that read as broken test
files rather than a missing install. That is why it is opt-in.

`auditRequirements` closes a real gap for aws-ecs projects whose Dockerfile
installs a different, disjoint requirements file than the one the CI venv is
built from (e.g. a `backend/requirements.txt` that never reaches the CI venv
but does ship to production) — without it, "a CVE fails the build" is only
true for the dependency set that *doesn't* ship. Each listed manifest is
scanned with `pip-audit -r <path>`, which resolves an unpinned manifest to the
versions a fresh install would get — the same resolution a Docker build does,
so this models production rather than approximating it — using the same
`pipAuditIgnores` allowlist and the same fail-the-build behaviour as the main
CVE gate. **It covers CVEs only.** `pip-licenses` inspects the installed
environment, so it cannot scan a manifest that was never installed; license
scanning still covers only the CI venv, not `auditRequirements` entries.

**Previews require** the variable group's AWS creds to permit ephemeral preview
infra; `deploy-ecs-preview.ps1` provisions it per PR and `cleanup-ecs-previews.ps1`
sweeps closed/expired ones on the daily schedule. Two prerequisites are easy to
miss because of how they fail:

- **The Azure DevOps environment `<environment>-preview` must exist before the
  first preview build.** `PreviewDeploy` is a `deployment` job targeting it, and
  Azure DevOps does not create it implicitly for the build identity. Absent, the
  pipeline is rejected at *compile* time with `Job deployPreview: Environment
  <environment>-preview could not be found`, which produces **no jobs and an empty
  timeline** — so every build on the repo goes red, plain branch CI included, with
  nothing in the UI to click into. It reads like a broken pipeline rather than one
  missing resource. Create it under Pipelines → Environments → New environment,
  resource type *None*.
- **Run `Get-CcmEcsDeployPolicyGaps` against the project's policy after enabling
  previews.** Passed the parsed `ecs-config.json`, it already knows which extra
  actions `PreviewEnvironments` implies — the per-PR target group and listener
  rule, the preview service, and `tag:GetResources`, which
  `cleanup-ecs-previews.ps1` needs because it discovers previews through
  `aws resourcegroupstaggingapi get-resources` and throws on a non-zero exit.
  Missing that one is silent in the worst way: nothing fails at deploy time, and
  instead the CleanupPreviews stage dies on its first statement every night in a
  scheduled build nobody watches. Closed PRs then each keep a running task, a
  target group and a listener rule — and listener rules are quota-limited per
  listener, on the same ALB the production service is served from.

## Skills pipeline template

`azure-pipelines-skills.yml` is a shared pipeline template for Claude/Codex skill repositories. It auto-discovers skill folders (any directory at the repo root containing a `SKILL.md`),
reads each one's `version:` frontmatter, validates version bumps on PRs, packs each skill as a
`skill-<name>.<version>.nupkg`, and publishes to an Azure Artifacts NuGet feed (`feedOrgName` /
`feedName` parameters, defaults `my-org` / `skills`) on `main`/`master`. Set `packageAuthors` for
the nuspec `<authors>`/`<owners>`.

```yaml
steps:
  - template: azure-pipelines-skills.yml@ccm
```

### Declaring a dependency between skills (`requires:`)

A skill's frontmatter may declare that it depends on other skills, so that one skill can reuse
another's files (a shared logo/template, for example) instead of every skill carrying its own copy.
One line, comma-separated, each entry `<skill-name>>=<semver>`:

```yaml
---
name: my-app
description: …
version: 1.2.0
requires: my-other-skill>=1.0.0
---
```

Grammar: `requires := entry ("," entry)*`, `entry := skill-name ">=" semver`, `skill-name :=
[a-z0-9]+(-[a-z0-9]+)*`. The version after `>=` is always a **minimum**, never a pin and never a
range — NuGet already treats a bare `version="1.0.0"` as "1.0.0 or greater". `requires:` absent or
empty means no dependencies.

Before packing, the pipeline validates every declaration and fails the build loudly rather than
producing a package that cannot install:

1. **Grammar** — a malformed entry (wrong operator, non-semver version, illegal characters) fails
   here instead of becoming a dependency on a package that can never exist.
2. **Same-repo satisfiability** — if the required skill lives in this repo, its discovered
   `version:` must already be at or above the declared minimum.
3. **Cross-repo satisfiability** — otherwise, the pipeline queries the feed for the required
   package and requires at least one non-deleted version at or above the minimum.
4. **Cycle detection** across the repo's own skills — the install client resolves depth-first, and
   a cycle has no valid install order.

A skill declaring nothing packs a nuspec **byte-identical** to one packed before this feature
existed — no `<dependencies>` element is emitted at all, so nothing changes for the great majority
of skills that never declare `requires:`. The nuspec assembly itself (`New-CcmSkillNuspecContent`,
exported by this module) has a pinned byte-identical test in `Tests/SkillDependency.Tests.ps1` for
exactly this reason: every skill packs through the same template, so a regression there
would break every skill's package at once.

Resolving `requires:` at install time — actually pulling a dependency onto a machine — is the
install client's job, not this pipeline's. `deploy-skill.ps1` installs skills from a local checkout.

## No consumer references

**CCM must never name a specific consumer project.** Not in code, comments,
`.EXAMPLE` blocks, JSON schema examples, README tables, or test fixtures.

This module is shared across many projects and is distributed to people who
have no connection to — and no need to know about — any given project. Some
projects are confidential, and a project's mere existence can be the sensitive
part. A stale example naming a repository that a reader
has never heard of leaks that it exists, who works on it, and roughly what it
does.

It is also a correctness problem in its own right: a consumer-specific example
goes stale the moment that consumer changes, and nobody maintaining CCM will
notice.

Use neutral placeholders instead:

| Instead of | Write |
|---|---|
| a real project name | `my-app`, `my-project`, `webapp` |
| a real package path | `src/my_package` |
| a real variable group | `my-app-aws-deploy` |
| a real AWS account id | `123456789012` |
| a real agent or host name | "self-hosted agents" |

Genuinely public, non-identifying constants are fine — for example AWS's
documented per-region ELB service account IDs in `setup-aws-infrastructure.ps1`
are published by AWS and identify no one.

Before opening a PR, grep your diff for consumer names, account IDs and
hostnames.

## Function naming

`utils.psm1` previously exported functions under names like
`setupVisualStudio`, `DownloadNinja`, `MyThrow`, `dos2unix`. These names
continue to work via exported aliases, but new code should prefer the
PSScriptAnalyzer-approved equivalents:
`Initialize-VisualStudioEnvironment`, `Save-Ninja`, `Write-CcmFatalError`,
`ConvertTo-UnixLineEnding`. See `CCM.psd1`'s `FunctionsToExport` and
`AliasesToExport` for the full mapping.

## Documentation

- **[`setup_cpp.md`](setup_cpp.md)** - Cross-platform environment setup guide (Windows/WSL2/Ubuntu/macOS)
- **[`setup_vcpkg.md`](setup_vcpkg.md)** - vcpkg package manager setup and NuGet binary caching
- **[`setup_podman.md`](setup_podman.md)** - Podman container runtime setup
- **[`setup-private-dependency-for-ci.md`](setup-private-dependency-for-ci.md)** - CI/CD integration guide for private Git submodules and vcpkg dependencies

## Testing

Run the Pester suite locally with the checked-in configuration:

```powershell
Invoke-Pester -Configuration (New-PesterConfiguration -Hashtable (Import-PowerShellDataFile ./Tests/PesterConfig.psd1))
```

CI does not use this file: `.github/workflows/ci.yml` builds its own Pester configuration inline,
adding code coverage and per-OS result paths, on Windows and Ubuntu. On pull requests it also
requires a `ModuleVersion` bump (plus the matching `changelog.d/<version>.md`) whenever the module
changes. `Tests/PesterConfig.psd1` is the local-development
profile (no coverage, results in `./pester-results.xml`, which is gitignored).

## Build Automation Scripts

### Core Build Scripts

- **`build.ps1`** - Main CMake build automation script with extensive feature toggles (CUDA, CUDNN, OpenCV, OpenMP, VTK, PCL, Qt, testing). Handles vcpkg integration, compiler setup (Visual Studio/Clang), Ninja build system, and installer creation
- **`build-doc.ps1`** - Documentation generation using Pandoc and LaTeX with PDF overlay support and mermaid diagram conversion
- **`build-ort.ps1`** - OSS Review Toolkit report generation for license assessment with Licencpp analysis and vcpkg integration
- **`build-tc.py`** - TwinCAT build automation through the TwinCAT automation interface (replaces `build-tc.ps1`)

### Clean-up Scripts

- **`clean.ps1`** - General project cleanup
- **`clean-doc.ps1`** - Documentation build artifacts cleanup

## Development Environment Setup

### Cross-Platform Setup

- **`setup_ros.sh`** - ROS Foxy environment setup for Ubuntu 20.04 with Orocos KDL (requires root privileges)
- **`setup-vros.sh`** - Virtual ROS environment setup
- **`setup-venv.ps1`** - Python virtual environment automation supporting requirements.txt and pyproject.toml with retry logic for network resilience. After the project install it refreshes stale bootstrap tooling (`pip`, `setuptools`) so long-lived venvs don't fail `ci-checks.ps1`'s pip-audit CVE gate; only packages already present are upgraded, so a bare venv stays bare. The selection rule is `Get-CcmVenvBootstrapPackages`.

### Profile Scripts

- **`Microsoft.PowerShell_profile.ps1`** - PowerShell profile customization with terminal setup, aliases, and optional oh-my-posh styling
- **`Microsoft.VSCode_profile.ps1`** - VS Code PowerShell profile customization

### Logging

All build/deploy/setup scripts share the centralized `Initialize-CcmLogging`
helper from the `CCM` module. On invocation, each script:

1. Opens a transcript at `<consumer-repo-root>/<scriptname>.log` (or
   `<consumer-repo-root>/<scriptname>_<timestamp>.log` if the default path is
   locked).
2. Adds `<scriptname>*.log` to the consumer repo's `.gitignore` inside a
   managed `# >>> CCM logs (managed) >>>` block.
3. If the consumer repo is a containerized app (contains a `Dockerfile`,
   `Containerfile`, or compose file at depth 0 or 1), also patches
   `.dockerignore` with the same block, creating it if missing.

The transcript is closed automatically on uncaught throws by an
`EngineExiting` handler plus a defensive per-script `trap`.

Opt-out switches on `Initialize-CcmLogging`:
- `-NoIgnorePatching` - skip both `.gitignore` and `.dockerignore` patching.
- `-NoCreateDockerignore` - patch an existing `.dockerignore` but don't create one.
- `-LogDirectory <path>` - override the default consumer-repo-root resolution.
- `-Name <string>` - override the script-basename-derived log filename.

Helper functions also exported by the `CCM` module:
- `Test-IsContainerizedRepository -Path <dir>` - `[bool]` depth-1 scan.
- `Add-IgnorePatternBlock` - idempotent managed-block writer for any ignore-style
  file. `-Pattern` accepts one or more patterns (a single string still works
  unchanged); each call only adds whichever of them aren't already inside the
  block. `-ManagedBy` (default `'Initialize-CcmLogging'`) sets the "managed by
  ..." wording in the start sentinel - callers introducing a new `-BlockId`
  should pass their own name; do not change the default, since every `CCM
  logs` block already written into a consumer's `.gitignore`/`.dockerignore`
  has that exact wording baked in, and the sentinel match is a literal string
  compare.
- `Write-CcmInfo` / `-Success` / `-Warning` / `-Error` / `-Step` - leveled
  `Write-Host` wrappers with `[HH:mm:ss] [LEVEL]` prefix.

`ci-checks.ps1` uses the same mechanism for its own report artifacts, in a
separate `CCM ci-checks artifacts` block (so it never collides with the `CCM
logs` block above): `bandit-report.json`, `pip-licenses.csv`,
`pip-audit*.json` (covers both the CI-venv report and the per-manifest
`ci.auditRequirements` reports), `coverage.xml`, `.coverage`,
`test-unit.xml`, `npm-licenses.csv`, `npm-audit.json`, and
`security-reports-staging/`. Patched into `.gitignore` (created if missing)
and, for containerized repos, `.dockerignore`, before any gate can exit 1 -
none of these are meant to be committed, and a consumer running the gates
locally should never end up with an untracked, unignored file it can't
commit.

## Deployment & DevOps

### Deployment Scripts

- **`deploy-linux-vm.ps1`** - Azure Linux VM deployment automation (`-ResourceGroupName`, `-StorageAccountName`, `-VNetName`, `-SubnetName`)
- **`deploy-pwsh-profile.ps1`** - Installs the PowerShell profiles and the `CCM` module for the current user
- **`deploy-skill.ps1`** - Installs Claude/Codex skills from a local checkout
- **`deploy-templates.ps1`** - Project template deployment automation
- **`deploy-ecs.ps1`** - AWS ECS (Elastic Container Service) deployment automation. Container runtime is auto-selected in the order **wslc → docker → podman** (wslc is Windows-only). Override with `-UseWslc`/`-UseDocker`/`-UsePodman`, or pin it per-repo via `"ContainerTool"` in `ecs-config.json`.

### AWS & Cloud Infrastructure

- **`setup-aws-infrastructure.ps1`** - AWS infrastructure setup automation
- **`remove-aws-infrastructure.ps1`** - Tears down the core stack created by `setup-aws-infrastructure.ps1`: ECS service, ALB listeners/load balancer/target group, cluster, IAM roles and security groups, in the dependency order from `Get-CcmEcsTeardownPlan` (service before cluster, listeners before load balancer, security groups last so a lingering ENI doesn't cause a `DependencyViolation`; the service delete waits for `ecs wait services-inactive` before returning). The ECR repository and CloudWatch log groups are only deleted with `-IncludeEcr`/`-IncludeLogs`, since both hold history that cannot be recovered. It does **not** remove `setup-aws-infrastructure.ps1`'s optional capabilities - an NLB and its target group(s) (`-EnableNlb`), DynamoDB tables (`-EnableDynamoDb`), an Aurora cluster/instance/subnet group (`-EnableAurora`), or Secrets Manager secrets - but after the teardown it **scans** for them (read-only) and prints a `STILL PRESENT (out of scope)` line per leftover (or `UNVERIFIED` when a probe itself failed), and either one qualifies the closing all-clear; an NLB in particular can keep running (and billing) after this script reports success. The scan is skipped under `-WhatIf` to preserve the zero-AWS-calls dry run. The Route 53 record it removes is `ecs-config.json`'s `CustomDomainName` when present, and otherwise `<ProjectName>.<ParentDomain>` — derived exactly as `setup-aws-infrastructure.ps1` derives it and under the same condition (`Route53HostedZoneId` **and** `ParentDomain` both present), because most projects deliberately don't store `CustomDomainName` (the key hardcodes a hostname that goes stale on a rename) and reading it without deriving it left their DNS record behind, dangling at a deleted load balancer, while the run reported a clean sweep. A derived name that wouldn't be a valid hostname (a malformed `ParentDomain`) is reported as an error rather than used or quietly dropped: the record goes unchecked, the all-clear is withheld and the run exits non-zero. Zone-owned NS/SOA record sets are filtered out of the Route 53 delete by Type (they match when `CustomDomainName` is the zone apex, and Route 53 refuses to delete them there; derivation always yields a subdomain, so that path only ever arises from an explicit `CustomDomainName`), and the record name is matched lowercased, as Route 53 stores it. Supports `-WhatIf`/`-Confirm` (every deletion goes through `ShouldProcess`, so a dry run makes no AWS calls at all) - but a `-WhatIf` run alone can never confirm a teardown completed, since `ShouldProcess` returns before any resource is even looked up; the actual proof is a second **real** run afterwards (safe, since everything is already gone), which reports every resource as absent. It refuses to run if `-ProjectName` disagrees with `ecs-config.json`. It never touches the shared VPC, its subnets, or the VPC-endpoint security group — `Get-CcmEcsTeardownPlan` has no parameter that could even carry those ids, since they are shared by every project in the account, and both `ProjectName` (alphanumerics and hyphens only) and `CustomDomainName` (hostname charset only) are restricted so neither can be used to smuggle an AWS CLI filter separator (`,`), an EC2 wildcard (`*`), or a JMESPath-widening quote into a lookup. A non-zero AWS CLI exit code is only ever treated as "resource absent" when the error text matches a recognised not-found signal; anything else prints a `FAILED, still present` line for that resource (counted separately from resources confirmed absent), suppresses the closing "Nothing remained" message, and makes the script exit non-zero. Like `setup-aws-infrastructure.ps1`, it logs its run via `Initialize-CcmLogging`/`Stop-CcmLogging`.
- **`setup-route53-zone.ps1`** - One-time Route 53 hosted zone + wildcard ACM certificate setup for a new parent domain (see options below).
- **`setup-azure-devops-iam.ps1`** - Creates the Azure DevOps deploy IAM user and attaches its policy, as either an inline policy or a customer-managed one depending on its size. Before attaching, it validates the policy against the actions the deploy scripts actually call (see below). `-Remove` reverses this - and runs *before* the policy file is loaded or validated, so it still works when `deploy/azure-devops-iam-policy.json` is missing or stale, which is exactly the state a project being retired is likely to be in. It deletes every access key on the user, every inline policy on the user (not only `$ProjectName-deploy-policy` - if `-UserName` points at an existing/shared identity, **all** of its inline policies go), and the customer-managed `$ProjectName-deploy-policy` if that is instead how it was attached - checking both the inline path (`list-user-policies`/`delete-user-policy`) and the managed path (`detach-user-policy`, its non-default versions, then `delete-policy`) independently, since either or neither may be present - then deletes the `$ProjectName-azure-devops-deploy` user. It does not touch group memberships, a login profile, MFA devices, or SSH keys - this script only ever creates a programmatic user, so those are out of scope. IAM refuses to delete a user that still owns access keys or an attached policy of either kind, and refuses to delete a managed policy that still has non-default versions or is still attached to someone, so the order is fixed accordingly. Every mutating call's exit code is checked; "Removal complete." is only printed once nothing has failed, otherwise a `FAILED, still present` line names what remains and the script exits non-zero. Removal is `ConfirmImpact 'High'` like `remove-aws-infrastructure.ps1`, so it prompts per deletion by default - pass `-Confirm:$false` for an unattended removal. Supports `-WhatIf`, which instead prints "Dry run - nothing was removed." (every mutation is skipped under `-WhatIf`, so, like `remove-aws-infrastructure.ps1`, it never claims a completed removal it didn't perform).
- **`diagnose-ecr-connectivity.ps1`** - AWS ECR connectivity diagnostic tool (proxy, DNS, TLS, wslc/Docker/Podman)

#### `setup-route53-zone.ps1` options

| Param | Type | Default | Purpose |
|---|---|---|---|
| `ParentDomain` | string | *(required)* | Parent domain for all subdomains, e.g. `ai.example.com` |
| `AwsRegion` | string | `eu-central-1` | Must match the region of the ALBs the certificate will attach to |
| `SkipCertificate` | switch | off | Create the hosted zone and print the NS records without requesting a certificate |
| `IncludeApex` | switch | off | Also request the zone apex (e.g. `example.com` itself, not just `*.example.com`) as a subject alternative name. An ACM certificate cannot be amended after issuance, so adding the apex later means requesting a second certificate and re-pointing every listener that uses this one — worth deciding at zone-creation time if a portal or landing page at the apex is even plausible |
| `WaitForCertificate` | bool | `true` | Poll ACM until the certificate is issued (up to 10 minutes) |
| `ConfigFile` | string | auto-detected `ecs-config.json` | Where to write back the hosted zone ID and certificate ARN |

#### Deploy policy validation

`Get-CcmEcsDeployPolicyGaps -PolicyObject <policy> -Config <ecs-config>` compares an
IAM policy document against the actions the CCM deploy scripts issue, so a missing
grant fails at setup time instead of mid-deploy. The action list is derived from the
actual `aws ...` calls in `deploy-ecs.ps1`, `deploy-ecs-preview.ps1`,
`remove-ecs-preview.ps1` and `cleanup-ecs-previews.ps1`, and adapts to the config:

- Build-and-push actions (ECR auth, the four layer-upload actions, `PutImage`,
  `BatchGetImage`) are dropped when `ExternalImage` is set.
- Preview actions (`tag:GetResources`, ELB create/delete/describe/modify/tag,
  `ecs:TagResource`) apply when `PreviewEnvironments.Enabled` is true, plus the
  Route 53 pair when `RoutingMode` is `host`.
- Actions reached only through an optional switch (`ecs:RunTask`/`ecs:DescribeTasks`
  for `-RunMigrations`, `ecr:DescribeImages` for `-SkipBuild`) are reported as
  **recommended**: a warning, not a hard failure.

Wildcards are honoured (`*`, `ecr:*`, `ecs:Desc*`), but only within the same service —
`ecs:Desc*` does not grant `ecr:DescribeImages`. `Deny` statements never count as grants.

### Local development

- **`local-build.ps1`** - Local containerized development with Docker/Podman compose and hot-reload support (wslc not supported here yet — no `compose` command)

#### Optional capability: S3 (`EnableS3`)

`setup-aws-infrastructure.ps1` can provision an S3 bucket for persistent
document storage and grant the ECS task role read/write access, mirroring
`EnableDynamoDb`/`EnableAurora`. Drive it from `ecs-config.json`:

- `S3BucketName` overrides the bucket name (defaults to
  `<ProjectName>-documents-<AccountId>`).
- `S3BucketVersioning` (default `true`) turns bucket versioning off for a
  project whose deletes are documented as final.

#### Optional capability: DynamoDB (`EnableDynamoDb`)

`setup-aws-infrastructure.ps1` can provision DynamoDB tables and grant the ECS
task role scoped access, mirroring `EnableS3`/`EnableAurora`. Drive it from
`ecs-config.json`:

```jsonc
{
  "EnableDynamoDb": true,
  "DynamoDbTables": [
    { "Name": "my-app-scopes",      "PartitionKey": { "Name": "scopeId", "Type": "S" } },
    { "Name": "my-app-assignments", "PartitionKey": { "Name": "userKey", "Type": "S" },
                                    "SortKey": { "Name": "sk", "Type": "S" } }
  ]
}
```

- Each table entry takes `Name`, `PartitionKey { Name, Type }`, optional
  `SortKey { Name, Type }`, and optional `BillingMode` (defaults to
  `PAY_PER_REQUEST`). Key `Type` is `S` (default), `N`, or `B`.
- Use the `<ProjectName>-<purpose>` naming convention to avoid cross-project
  collisions.
- Table creation is **idempotent** (existing tables are left untouched; tables are
  never deleted by this script).
- The task role receives an inline policy named `<ProjectName>-dynamodb-access`
  granting `GetItem/BatchGetItem/Query/Scan/PutItem/UpdateItem/DeleteItem/
  BatchWriteItem` on exactly those table ARNs and their `index/*`.
- The created table names are written to `deploy/ecs/infrastructure-config.json`
  under `DynamoDbTables`. The application reads table names from its own env vars
  (e.g. `SCOPES_TABLE`, `ASSIGNMENTS_TABLE`), which the project's task definition
  wires — this script does not set those env vars.

### Security & Network

- **`open-fw-exe.ps1`** / **`close-fw-rule.ps1`** - Windows Firewall management for executables (requires Administrator)
- **`enable-administrative-shares.ps1`** / **`disable-administrative-shares.ps1`** - Windows administrative shares (C$, D$, etc.) toggle
- **`enable-iis.ps1`** / **`disable-iis.ps1`** - IIS service management with optional directory browsing configuration (requires Administrator)
- **`enable-samba.sh`** - Samba file sharing setup, plus an Apache site serving the folder passed as argument

## Specialized Industrial Software Integration

### Machine Vision & Industrial Automation

- **`minting-labview.ps1`** - LabVIEW environment setup and uninstall management for multiple versions (IDE and Runtime) with NI Package Manager integration
- **`minting-sapera.ps1`** - Teledyne DALSA Sapera SDK integration

### FPGA Development

- **`minting-xilinx-centos.sh`** - Xilinx tools on CentOS
- **`minting-xilinx-ubuntu.sh`** - Xilinx tools on Ubuntu

### Testing

- **`verify-test-log.ps1`** - Test log verification utility

## CMake Modules & Functions

### Find Modules (`Modules/`)

#### Industrial Automation & Vision

- **`FindHalcon.cmake`** - MVTec HALCON machine vision library
- **`FindDalsa-GigEVision.cmake`** / **`FindSaperaLT.cmake`** - Teledyne DALSA GigE Vision and Sapera LT SDKs
- **`FindCXSDK.cmake`** - Automation Technology CX 3D camera SDK
- **`FindGOSDK.cmake`** - LMI Gocator GO SDK
- **`FindTwinCAT.cmake`** / **`FindTcADS.cmake`** - Beckhoff TwinCAT and its ADS library (`TwinCAT::ADS`)
- **`FindBBAPI.cmake`** - Beckhoff BBAPI (industrial PC hardware API)
- **`FindAravis.cmake`** - Real-time video acquisition library for industrial cameras

#### FPGA & Embedded

- **`FindQuartus.cmake`** - Intel Quartus
- **`FindSitaraSDK.cmake`** - Texas Instruments Sitara processor SDK

#### Media & Networking

- **`FindMP4V2.cmake`** - MP4 container library
- **`FindOpenH264.cmake`** - Cisco OpenH264 codec
- **`FindPFRing.cmake`** - PF_RING high-speed packet capture
- **`FindCURLpp.cmake`** - C++ wrapper for libcurl
- **`FindLibSSH.cmake`** - SSH protocol library
- **`FindUriParser.cmake`** - URI parsing library

#### Scientific Computing & Mathematics

- **`FindFFTW.cmake`** - Fast Fourier Transform library detection
- **`FindMKL.cmake`** - Intel Math Kernel Library integration
- **`FindMEEP.cmake`** - MIT Electromagnetic Equation Propagation package
- **`FindVCG.cmake`** - VCG geometry processing library

#### Data Processing & Formats

- **`FindKML.cmake`** - Keyhole Markup Language support
- **`FindLibXmlpp.cmake`** - C++ XML processing library
- **`FindMiniZip.cmake`** - ZIP archive manipulation
- **`Findsqlite3.cmake`** - SQLite database engine
- **`FindShapelib.cmake`** - ESRI Shapefile format library

#### Geospatial & Mapping

- **`FindGRASS.cmake`** - Geographic Resources Analysis Support System

#### System Libraries & Performance

- **`FindATL.cmake`** - Active Template Library (Windows)
- **`FindTBB.cmake`** - Intel Threading Building Blocks
- **`FindNuma.cmake`** - Non-Uniform Memory Access optimization
- **`FindLibRt.cmake`** - Real-time extensions library

#### Scientific & Engineering Libraries

- **`FindLibgraflib.cmake`** - Graphics library component
- **`FindLibgrafX11.cmake`** - X11 graphics library component
- **`FindLibkernlib.cmake`** - Kernel library component
- **`FindLibmathlib.cmake`** - Mathematical library component
- **`FindLibpacklib.cmake`** - Package library component
- **`FindLibphtools.cmake`** - Physics tools library component

#### Platform-Specific Modules (`msys2/`)

- **`FindMPI.cmake`** - Message Passing Interface for MSYS2 environment

### CMake Functions (`Functions/`)

- **`DeployQTAtBuild.cmake`** - Qt framework deployment automation during build process
- **`FixDriverProj.cmake`** - Driver project configuration and fixes

### Toolchain Files

- **`SitaraToolchain.cmake`** - Texas Instruments Sitara (AM335x) cross-compilation toolchain

### Additional Modules

#### Extra Find Modules (`Extras/`)

- **`FindSDL2.cmake`** - Simple DirectMedia Layer 2.0 for multimedia applications

#### Deprecated Modules (`Deprecated/`)

- **`FindCUDNN.cmake`** - NVIDIA CUDA Deep Neural Network library (deprecated)
- **`FindFLTK.cmake`** - Fast Light Toolkit GUI library (deprecated)
- **`FindLibLZMA.cmake`** - LZMA compression library (deprecated)
- **`FindPThreads4W.cmake`** - POSIX Threads for Windows (deprecated)
- **`FindStb.cmake`** - STB single-file public domain libraries (deprecated)

## Utility Modules

### Core Utilities

- **`CCM.psd1`** (and the `utils.psm1` shim) - Core PowerShell module providing:
  - System detection (Windows PowerShell vs Core, 32/64-bit architecture)
  - Visual Studio discovery and environment setup
  - PostgreSQL installation detection and setup
  - Python virtual environment activation
  - Pip installation with retry logic (handles proxy throttling)
  - Utility functions for downloading tools (Ninja, Aria2, licencpp, 7-Zip)
  - Line ending conversion (dos2unix/unix2dos)
  - Repository management and git submodule operations
  - Logging (`Initialize-CcmLogging`), container-runtime selection, AWS ECS helpers and skill packaging helpers
  - `$cuda_version_full` / `$cuda_version_short` (and `_dashed` variants): the CUDA version the build scripts target

### Configuration Files

- **`ort-config.yml`** - OSS Review Toolkit configuration for license assessment
- **`ecs-config.schema.json`** - JSON schema for a consumer's `ecs-config.json`

