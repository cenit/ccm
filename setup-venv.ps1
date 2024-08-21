#!/usr/bin/env pwsh

<#

.SYNOPSIS
        setup-venv
        Created By: Stefano Sinigardi
        Created Date: July 15, 2024
        Last Modified Date: August 6, 2024

.DESCRIPTION
Setup a python virtual environment with venv

.PARAMETER DisableInteractive
Disable script interactivity (useful for CI runs)

.PARAMETER DoNotUpdateTOOL
Do not update the tool before running the build (valid only if tool is git-enabled)

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
  [switch]$Deactivate = $false
)

$global:DisableInteractive = $DisableInteractive

$setup_venv_ps1_version = "1.2.0"
$script_name = $MyInvocation.MyCommand.Name
if (Test-Path $PSScriptRoot/utils.psm1) {
  Import-Module -Name $PSScriptRoot/utils.psm1 -Force
  $utils_psm1_avail = $true
  $IsInGitSubmodule = $true
}
elseif (Test-Path $PSScriptRoot/cmake/utils.psm1) {
  Import-Module -Name $PSScriptRoot/cmake/utils.psm1 -Force
  $utils_psm1_avail = $true
  $IsInGitSubmodule = $false
}
elseif (Test-Path $PSScriptRoot/ci/utils.psm1) {
  Import-Module -Name $PSScriptRoot/ci/utils.psm1 -Force
  $utils_psm1_avail = $true
  $IsInGitSubmodule = $false
}
elseif (Test-Path $PSScriptRoot/ccm/utils.psm1) {
  Import-Module -Name $PSScriptRoot/ccm/utils.psm1 -Force
  $utils_psm1_avail = $true
  $IsInGitSubmodule = $false
}
elseif (Test-Path $PSScriptRoot/scripts/utils.psm1) {
  Import-Module -Name $PSScriptRoot/scripts/utils.psm1 -Force
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
  $proc = Start-Process -NoNewWindow -PassThru -FilePath $PYTHON_EXE -ArgumentList " -m venv $venv_dir"
  $handle = $proc.Handle
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

if (-Not $IsMacOS) {
  Write-Host "Ensuring pip is available"
  $proc = Start-Process -NoNewWindow -PassThru -FilePath $PYTHON_VENV_EXE -ArgumentList " -m ensurepip --upgrade"
  $handle = $proc.Handle
  $proc.WaitForExit()
  $exitCode = $proc.ExitCode
  if (-Not ($exitCode -eq 0)) {
    MyThrow("Unable to ensure pip is available! Exited with error code $exitCode.")
  }
}

$base_packages = " pip setuptools wheel pyinstaller pytest pytest-cov test-utils"
if ($azure_ci) {
  $base_packages += " pytest-azurepipelines"
}

Write-Host "Updating base packages"
$proc = Start-Process -NoNewWindow -PassThru -FilePath $PYTHON_VENV_EXE -ArgumentList " -m pip install --upgrade $base_packages"
$handle = $proc.Handle
$proc.WaitForExit()
$exitCode = $proc.ExitCode
if (-Not ($exitCode -eq 0)) {
  MyThrow("Unable to install pip! Exited with error code $exitCode.")
}

$requirements_path = "$PSCustomScriptRoot/requirements.txt"
if (Test-Path $requirements_path) {
  Write-Host "Installing requirements"
  $proc = Start-Process -NoNewWindow -PassThru -FilePath $PYTHON_VENV_EXE -ArgumentList " -m pip install --upgrade -r requirements.txt"
  $handle = $proc.Handle
  $proc.WaitForExit()
  $exitCode = $proc.ExitCode
  if (-Not ($exitCode -eq 0)) {
    MyThrow("Unable to compile requirements! Exited with error code $exitCode.")
  }
}

$ErrorActionPreference = "SilentlyContinue"
Stop-Transcript | out-null
$ErrorActionPreference = "Continue"
