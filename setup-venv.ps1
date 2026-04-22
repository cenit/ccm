#!/usr/bin/env pwsh

<#

.SYNOPSIS
        setup-venv
        Created By: Stefano Sinigardi
        Created Date: July 15, 2024
        Last Modified Date: March 10, 2026

.DESCRIPTION
Setup a python virtual environment using uv (https://docs.astral.sh/uv/).
Supports both requirements.txt and pyproject.toml based projects.

.PARAMETER DisableInteractive
Disable script interactivity (useful for CI runs)

.PARAMETER DoNotUpdateTOOL
Do not update the tool before running the build (valid only if tool is git-enabled)

.PARAMETER ActivateOnly
Activate the virtual environment only

.PARAMETER CPUOnlyRequirements
Use requirements-cpu.txt instead of requirements.txt

.PARAMETER DevRequirements
Use requirements-dev.txt instead of requirements.txt

.PARAMETER Deactivate
Deactivate the virtual environment

.PARAMETER AllExtras
Install all optional dependencies (.[all]) for pyproject.toml projects

.PARAMETER DevExtras
Install development dependencies (.[dev]) for pyproject.toml projects

.EXAMPLE
.\setup-venv -DisableInteractive

#>

<#
Copyright (c) Stefano Sinigardi

MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED *AS IS*, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
#>

param (
  [switch]$DisableInteractive = $false,
  [switch]$DoNotUpdateTOOL = $false,
  [switch]$ActivateOnly = $false,
  [switch]$CPUOnlyRequirements = $false,
  [switch]$DevRequirements = $false,
  [switch]$Deactivate = $false,
  [switch]$AllExtras = $false,
  [switch]$DevExtras = $false
)

$global:DisableInteractive = $DisableInteractive

$setup_venv_ps1_version = "3.1.0"
$script_name = $MyInvocation.MyCommand.Name
if (Test-Path $PSScriptRoot/utils.psm1) {
  Import-Module -Name $PSScriptRoot/utils.psm1 -Force -DisableNameChecking
  $utils_psm1_avail = $true
  $IsInGitSubmodule = $true
}
elseif (Test-Path $PSScriptRoot/cmake/utils.psm1) {
  Import-Module -Name $PSScriptRoot/cmake/utils.psm1 -Force -DisableNameChecking
  $utils_psm1_avail = $true
  $IsInGitSubmodule = $false
}
elseif (Test-Path $PSScriptRoot/ci/utils.psm1) {
  Import-Module -Name $PSScriptRoot/ci/utils.psm1 -Force -DisableNameChecking
  $utils_psm1_avail = $true
  $IsInGitSubmodule = $false
}
elseif (Test-Path $PSScriptRoot/ccm/utils.psm1) {
  Import-Module -Name $PSScriptRoot/ccm/utils.psm1 -Force -DisableNameChecking
  $utils_psm1_avail = $true
  $IsInGitSubmodule = $false
}
elseif (Test-Path $PSScriptRoot/scripts/utils.psm1) {
  Import-Module -Name $PSScriptRoot/scripts/utils.psm1 -Force -DisableNameChecking
  $utils_psm1_avail = $true
  $IsInGitSubmodule = $false
}
else {
  $utils_psm1_version = "unavail"
  $IsWindowsPowerShell = $false
  $IsInGitSubmodule = $false
}

$ErrorActionPreference = "SilentlyContinue"
Stop-Transcript | out-null
$ErrorActionPreference = "Continue"
if($IsInGitSubmodule) {
  $PSCustomScriptRoot = Split-Path $PSScriptRoot -Parent
}
else {
  $PSCustomScriptRoot = $PSScriptRoot
}
$SetupVenvLogPath = "$PSCustomScriptRoot/setup-venv.log"
Start-Transcript -Path $SetupVenvLogPath

Write-Host "Setup venv script version ${setup_venv_ps1_version}, utils module version ${utils_psm1_version}"
Write-Host "Working directory: $PSCustomScriptRoot, log file: $SetupVenvLogPath, $script_name is in submodule: $IsInGitSubmodule"

Write-Host -NoNewLine "PowerShell version:"
$PSVersionTable.PSVersion

if ($IsWindowsPowerShell) {
  Write-Host "Running on Windows Powershell, please consider update and running on newer Powershell versions"
}

if ($PSVersionTable.PSVersion.Major -lt 5) {
  MyThrow("Your PowerShell version is too old, please update it.")
}

Push-Location $PSCustomScriptRoot

$GIT_EXE = Get-Command "git" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
if (-Not $GIT_EXE) {
  MyThrow("Could not find git, please install it")
}
else {
  Write-Host "Using git from ${GIT_EXE}"
}

$UV_EXE = Get-Command "uv" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
if (-Not $UV_EXE) {
  MyThrow("Could not find uv, please install it (https://docs.astral.sh/uv/getting-started/installation/)")
}
else {
  Write-Host "Using uv from ${UV_EXE}"
}

$PYTHON_EXE = Get-Command "python" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
if (-Not $PYTHON_EXE) {
  $PYTHON_EXE = Get-Command "python3" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
  if (-Not $PYTHON_EXE) {
    MyThrow("Could not find python, please install it")
  }
}
else {
  Write-Host "Using python from ${PYTHON_EXE}"
}

if ($Deactivate) {
  & deactivate
  $ErrorActionPreference = "SilentlyContinue"
  Stop-Transcript | out-null
  $ErrorActionPreference = "Continue"
  exit 0
}

$venv_dir = "$PSCustomScriptRoot/.venv"
if ($ActivateOnly) {
  activateVenv($venv_dir)
  exit 0
}

if (-Not (Test-Path $venv_dir)) {
  Write-Host "Creating virtual environment with uv"
  $proc = Start-Process -NoNewWindow -PassThru -FilePath "$UV_EXE" -ArgumentList " venv `"$venv_dir`""
  $proc.WaitForExit()
  $exitCode = $proc.ExitCode
  if (-Not ($exitCode -eq 0)) {
    MyThrow("Unable to create venv environment! Exited with error code $exitCode.")
  }
}

$gitignore_path = "$PSCustomScriptRoot/.gitignore"
if (-Not (Test-Path $gitignore_path)) {
  New-Item -Path $gitignore_path -ItemType File
}
$gitignore_content = Get-Content -Path $gitignore_path
if (-Not ($gitignore_content -contains ".venv")) {
  Add-Content -Path $gitignore_path -Value ".venv"
}

activateVenv($venv_dir)

$PYTHON_VENV_EXE = Get-Command "python" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
if (-Not $PYTHON_VENV_EXE) {
  $PYTHON_VENV_EXE = Get-Command "python3" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
  if (-Not $PYTHON_VENV_EXE) {
    MyThrow("Could not find python in venv, something is broken")
  }
}
else {
  Write-Host "Using python from ${PYTHON_VENV_EXE}"
}

if ($env:AGENT_ID) {
  $azure_ci = $true
  Write-Host "Running on Azure CI"
}
else {
  $azure_ci = $false
}

if (-not $env:UV_NATIVE_TLS -and -not $env:SSL_CERT_FILE -and -not $env:SSL_CERT_DIR -and ($azure_ci -or $env:HTTPS_PROXY -or $env:HTTP_PROXY -or $env:ALL_PROXY)) {
  $env:UV_NATIVE_TLS = "true"
  Write-Host "Enabled UV_NATIVE_TLS to use the OS trust store for corporate proxy certificates"
}

$pyproject_path = "$PSCustomScriptRoot/pyproject.toml"
if($CPUOnlyRequirements) {
  $requirements_path = "$PSCustomScriptRoot/requirements-cpu.txt"
}
elseif($DevRequirements) {
  $requirements_path = "$PSCustomScriptRoot/requirements-dev.txt"
}
else {
  $requirements_path = "$PSCustomScriptRoot/requirements.txt"
}

# When using pyproject.toml with extras (-DevExtras / -AllExtras), the project
# already declares its own test dependencies — skip base packages to avoid
# version conflicts.  For requirements.txt workflows (or bare pyproject.toml)
# install a minimal test harness so pytest is always available.
$skip_base_packages = (
  (-Not (Test-Path $requirements_path)) -and
  (Test-Path $pyproject_path) -and
  ($DevExtras -or $AllExtras)
)

if (-Not $skip_base_packages) {
  $base_packages = " pytest pytest-cov "
  if ($azure_ci) {
    $base_packages += " pytest-azurepipelines"
  }

  Write-Host "Installing base packages with uv"
  $proc = Start-Process -NoNewWindow -PassThru -FilePath "$UV_EXE" -ArgumentList " pip install $base_packages"
  $proc.WaitForExit()
  $exitCode = $proc.ExitCode
  if (-Not ($exitCode -eq 0)) {
    MyThrow("Unable to install base packages! Exited with error code $exitCode.")
  }
}
else {
  Write-Host "Skipping base packages (project extras will provide test dependencies)"
}

if (Test-Path $requirements_path) {
  Write-Host "Installing requirements from $requirements_path"
  $proc = Start-Process -NoNewWindow -PassThru -FilePath "$UV_EXE" -ArgumentList " pip install -r `"$requirements_path`""
  $proc.WaitForExit()
  $exitCode = $proc.ExitCode
  if (-Not ($exitCode -eq 0)) {
    MyThrow("Unable to install requirements! Exited with error code $exitCode.")
  }
}
elseif (Test-Path $pyproject_path) {
  if ($AllExtras) {
    Write-Host "Installing project from pyproject.toml with all extras"
    $proc = Start-Process -NoNewWindow -PassThru -FilePath "$UV_EXE" -ArgumentList " pip install -e `"$PSCustomScriptRoot[all]`""
  }
  elseif ($DevExtras) {
    Write-Host "Installing project from pyproject.toml with dev extras"
    $proc = Start-Process -NoNewWindow -PassThru -FilePath "$UV_EXE" -ArgumentList " pip install -e `"$PSCustomScriptRoot[dev]`""
  }
  else {
    Write-Host "Installing project from pyproject.toml"
    $proc = Start-Process -NoNewWindow -PassThru -FilePath "$UV_EXE" -ArgumentList " pip install -e `"$PSCustomScriptRoot`""
  }
  $proc.WaitForExit()
  $exitCode = $proc.ExitCode
  if (-Not ($exitCode -eq 0)) {
    MyThrow("Unable to install project from pyproject.toml! Exited with error code $exitCode.")
  }
}

# Detect if parent shell is bash/zsh (script was called from a non-PowerShell shell)
$parentProcess = Get-Process -Id $PID | Select-Object -ExpandProperty Parent -ErrorAction SilentlyContinue
if ($parentProcess) {
  $parentName = $parentProcess.ProcessName.ToLower()
  if ($parentName -match "bash|zsh|sh|fish") {
    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Yellow
    Write-Host "NOTE: You ran this script from $parentName." -ForegroundColor Yellow
    Write-Host "The virtualenv was created but NOT activated in your shell." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To activate it, run:" -ForegroundColor Green
    Write-Host "  source ./.venv/bin/activate" -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Yellow
  }
}

$ErrorActionPreference = "SilentlyContinue"
Stop-Transcript | out-null
$ErrorActionPreference = "Continue"
