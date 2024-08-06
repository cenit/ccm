#!/usr/bin/env pwsh

<#

.SYNOPSIS
        build-ort
        Created By: Stefano Sinigardi
        Created Date: February 21, 2024
        Last Modified Date: July 15, 2024

.DESCRIPTION
Build ORT report for license assessing

.PARAMETER DisableInteractive
Disable script interactivity (useful for CI runs)

.PARAMETER DoNotUpdateTOOL
Do not update the tool before running the build (valid only if tool is git-enabled)

.PARAMETER ForceLocalVCPKG
Use a copy of vcpkg in a subfolder of the tool folder, even if there might be another copy already provided by the system

.PARAMETER ProjectFeatures
Specify the project features to be enabled for licencpp analysis

.PARAMETER DoNotUpdateVCPKG
Do not update vcpkg before running the build (valid only if vcpkg is cloned by this script or the version found on the system is git-enabled)

.PARAMETER VCPKGSuffix
Specify a suffix to the vcpkg local folder for searching, useful to point to a custom version

.PARAMETER EnableCustomVCPKGRegistry
Enable usage of custom vcpkg-registry that has to be placed in WORKSPACE folder

.PARAMETER VerboseLicencpp
Enable verbose mode of licencpp tool

.PARAMETER MermaidGraphLicencpp
Enable creation of mermaid graph by licencpp tool

.PARAMETER SkipLicencpp
Skip Licencpp pass

.PARAMETER SkipORT
Skip ORT pass

.EXAMPLE
.\build-ort -DisableInteractive

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
  [string]$VCPKGSuffix = "",
  [switch]$EnableCustomVCPKGRegistry = $false,
  [switch]$DoNotUpdateVCPKG = $false,
  [switch]$ForceLocalVCPKG = $false,
  [string]$ProjectFeatures = "",
  [switch]$SkipLicencpp = $false,
  [switch]$VerboseLicencpp = $false,
  [switch]$MermaidGraphLicencpp = $false,
  [string]$LicencppAdditionalFlags = " ",
  [switch]$SkipORT = $false
)

$global:DisableInteractive = $DisableInteractive

$build_ort_ps1_version = "1.2.1"
$script_name = $MyInvocation.MyCommand.Name
$utils_psm1_avail = $false

if (Test-Path $PSScriptRoot/utils.psm1) {
  Import-Module -Name $PSScriptRoot/utils.psm1 -Force
  $utils_psm1_avail = $true
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
$BuildOrtLogPath = "$PSCustomScriptRoot/build-ort.log"
Start-Transcript -Path $BuildOrtLogPath

Write-Host "Build ORT script version ${build_ort_ps1_version}, utils module version ${utils_psm1_version}"
Write-Host "Working directory: $PSCustomScriptRoot, log file: $BuildOrtLogPath, $script_name is in submodule: $IsInGitSubmodule"

Write-Host -NoNewLine "PowerShell version:"
$PSVersionTable.PSVersion

if ($IsWindowsPowerShell) {
  Write-Host "Running on Windows Powershell, please consider update and running on newer Powershell versions"
}

if ($PSVersionTable.PSVersion.Major -lt 5) {
  MyThrow("Your PowerShell version is too old, please update it.")
}

if ($IsLinux -or $IsMacOS) {
  $bootstrap_ext = ".sh"
  $exe_ext = ""
}
elseif ($IsWindows -or $IsWindowsPowerShell) {
  $bootstrap_ext = ".bat"
  $exe_ext = ".exe"
}

if (-Not $SkipLicencpp) {
  $LICENCPP_EXE = Get-Command "licencpp" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
  if (-Not $LICENCPP_EXE) {
    if ($IsWindows -or $IsWindowsPowerShell) {
      $basename = "licencpp-Windows"
    }
    elseif ($IsLinux) {
      $basename = "licencpp-Linux"
    }
    $LICENCPP_EXE = Get-Command "$basename/licencpp${exe_ext}" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
    if (-Not $LICENCPP_EXE) {
      $LICENCPP_EXE = DownloadLicencpp
      if (-Not $LICENCPP_EXE) {
        MyThrow("Unable to find Licencpp and to download a portable version on the fly.")
      }
    }
    Write-Host "Using licencpp from ${LICENCPP_EXE}"
  }

  $GIT_EXE = Get-Command "git" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
  if (-Not $GIT_EXE) {
    MyThrow("Could not find git, please install it")
  }
  else {
    Write-Host "Using git from ${GIT_EXE}"
  }
}

if (-Not $SkipORT) {
  $ORT_EXE = Get-Command "ort" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
  if (-Not $ORT_EXE) {
    $ORT_EXE = Get-Command "$env:WORKSPACE/ort/cli/build/install/ort/bin/ort.bat" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
    if (-Not $ORT_EXE) {
      MyThrow("Could not find ort, please install it")
    }
  }
  Write-Host "Using ort from ${ORT_EXE}"
  $ORT_CONFIG = Get-ChildItem "$PSScriptRoot/ort-config.yml" -ErrorAction SilentlyContinue
  Write-Host "Using ort-config.yml from ${ORT_CONFIG}"
}

Push-Location $PSCustomScriptRoot

$GitRepoPath = Resolve-Path "$PSCustomScriptRoot/.git" -ErrorAction SilentlyContinue
$GitModulesPath = Resolve-Path "$PSCustomScriptRoot/.gitmodules" -ErrorAction SilentlyContinue
if (Test-Path "$GitRepoPath") {
  Write-Host "This tool has been cloned with git and supports self-updating mechanism"
  if ($DoNotUpdateTOOL) {
    Write-Host "This tool will not self-update sources" -ForegroundColor Yellow
  }
  else {
    Write-Host "This tool will self-update sources, please pass -DoNotUpdateTOOL to the script to disable"
    $proc = Start-Process -NoNewWindow -PassThru -FilePath $GIT_EXE -ArgumentList "pull"
    $handle = $proc.Handle
    $proc.WaitForExit()
    $exitCode = $proc.ExitCode
    if (-Not ($exitCode -eq 0)) {
      MyThrow("Updating this tool sources failed! Exited with error code $exitCode.")
    }
    if (Test-Path "$GitModulesPath") {
      $proc = Start-Process -NoNewWindow -PassThru -FilePath $GIT_EXE -ArgumentList "submodule update --init --recursive"
      $handle = $proc.Handle
      $proc.WaitForExit()
      $exitCode = $proc.ExitCode
      if (-Not ($exitCode -eq 0)) {
        MyThrow("Updating this tool submodule sources failed! Exited with error code $exitCode.")
      }
    }
  }
}

if (-Not $SkipLicencpp) {
  $vcpkg_root_set_by_this_script = $false

  if (-Not $ForceLocalVCPKG) {
    if ((Test-Path env:VCPKG_ROOT) -and $VCPKGSuffix -eq "") {
      $vcpkg_path = "$env:VCPKG_ROOT"
      $vcpkg_path = Resolve-Path $vcpkg_path
      Write-Host "Found vcpkg in VCPKG_ROOT: $vcpkg_path"
    }
    elseif (-not($null -eq ${env:WORKSPACE}) -and (Test-Path "${env:WORKSPACE}/vcpkg${VCPKGSuffix}")) {
      $vcpkg_path = "${env:WORKSPACE}/vcpkg${VCPKGSuffix}"
      $vcpkg_path = Resolve-Path $vcpkg_path
      $env:VCPKG_ROOT = "$vcpkg_path"
      $vcpkg_root_set_by_this_script = $true
      Write-Host "Found vcpkg in WORKSPACE/vcpkg${VCPKGSuffix}: $vcpkg_path"
    }
    elseif (-not($null -eq ${RUNVCPKG_VCPKG_ROOT_OUT})) {
      if (Test-Path "${RUNVCPKG_VCPKG_ROOT_OUT}") {
        $vcpkg_path = "${RUNVCPKG_VCPKG_ROOT_OUT}"
        $vcpkg_path = Resolve-Path $vcpkg_path
        $env:VCPKG_ROOT = "$vcpkg_path"
        $vcpkg_root_set_by_this_script = $true
        Write-Host "Found vcpkg in RUNVCPKG_VCPKG_ROOT_OUT: $vcpkg_path"
      }
    }
  }
  if ($null -eq $vcpkg_path) {
    if (-Not (Test-Path "$PWD/vcpkg${VCPKGSuffix}")) {
      $shallow_copy = ""
      if($CloneVCPKGShallow) {
        $shallow_copy = " --depth 1 "
      }
      $proc = Start-Process -NoNewWindow -PassThru -FilePath $GIT_EXE -ArgumentList "clone $shallow_copy https://github.com/microsoft/vcpkg vcpkg${VCPKGSuffix}"
      $handle = $proc.Handle
      $proc.WaitForExit()
      $exitCode = $proc.ExitCode
      if (-not ($exitCode -eq 0)) {
        MyThrow("Cloning vcpkg sources failed! Exited with error code $exitCode.")
      }
    }
    $vcpkg_path = "$PWD/vcpkg${VCPKGSuffix}"
    $vcpkg_path = Resolve-Path $vcpkg_path
    $env:VCPKG_ROOT = "$vcpkg_path"
    $vcpkg_root_set_by_this_script = $true
    Write-Host "Found vcpkg in $PWD/vcpkg${VCPKGSuffix}: $vcpkg_path"
  }

  Push-Location $vcpkg_path
    if ((Test-Path "$vcpkg_path/.git") -and (-Not $DoNotUpdateVCPKG)) {
      $proc = Start-Process -NoNewWindow -PassThru -FilePath $GIT_EXE -ArgumentList "pull"
      $handle = $proc.Handle
      $proc.WaitForExit()
      $exitCode = $proc.ExitCode
      if (-Not ($exitCode -eq 0)) {
        MyThrow("Updating vcpkg sources failed! Exited with error code $exitCode.")
      }
      $VcpkgBootstrapScript = Join-Path $PWD "bootstrap-vcpkg${bootstrap_ext}"
      $proc = Start-Process -NoNewWindow -PassThru -FilePath $VcpkgBootstrapScript -ArgumentList "-disableMetrics"
      $handle = $proc.Handle
      $proc.WaitForExit()
      $exitCode = $proc.ExitCode
      if (-Not ($exitCode -eq 0)) {
        MyThrow("Bootstrapping vcpkg failed! Exited with error code $exitCode.")
      }
    }
  Pop-Location

  $AdditionalVCPKGRegistry = ""
  if ($EnableCustomVCPKGRegistry) {
    $AdditionalVCPKGRegistry = "${env:WORKSPACE}/vcpkg-registry"
    $AdditionalVCPKGRegistryPorts = "${AdditionalVCPKGRegistry}/ports"
    if (Test-Path $AdditionalVCPKGRegistryPorts) {
      Push-Location $AdditionalVCPKGRegistry
      Write-Host "Using custom vcpkg-registry: $AdditionalVCPKGRegistry"
      if ((Test-Path "$AdditionalVCPKGRegistry/.git") -and (-Not $DoNotUpdateVCPKG)) {
        $proc = Start-Process -NoNewWindow -PassThru -FilePath $GIT_EXE -ArgumentList "pull"
        $handle = $proc.Handle
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
        if (-Not ($exitCode -eq 0)) {
          MyThrow("Updating vcpkg-registry sources failed! Exited with error code $exitCode.")
        }
      }
      Pop-Location
    }
    else {
      MyThrow("Custom vcpkg-registry not found in WORKSPACE folder")
    }
  }

  if ($VerboseLicencpp) {
    $LicencppAdditionalFlags += " --verbose"
  }
  if ($MermaidGraphLicencpp) {
    $LicencppAdditionalFlags += " --mermaid"
  }

  $licencpp_args = " --vcpkg_ports_dir=`"$vcpkg_path/ports`" --vcpkg_executable=`"$vcpkg_path/vcpkg${exe_ext}`" --project_features=`"$ProjectFeatures`" --vcpkg_additional_registry=`"$AdditionalVCPKGRegistryPorts`" $LicencppAdditionalFlags"
  Write-Host "Running: $LICENCPP_EXE $licencpp_args"
  $proc = Start-Process -NoNewWindow -PassThru -FilePath $LICENCPP_EXE -ArgumentList $licencpp_args
  $handle = $proc.Handle
  $proc.WaitForExit()
  $exitCode = $proc.ExitCode
  if (-Not ($exitCode -eq 0)) {
    MyThrow("Licencpp run failed! Exited with error code $exitCode.")
  }

  if ($vcpkg_root_set_by_this_script) {
    $env:VCPKG_ROOT = $null
  }

  if ($ForceLocalVCPKG) {
    Remove-Item -Force -Recurse -ErrorAction SilentlyContinue "$PWD/vcpkg${VCPKGSuffix}"
  }
  Write-Host "Licencpp analysis completed!" -ForegroundColor Green
}

if (-Not $SkipORT) {
  $ort_args = " -c $ORT_CONFIG analyze -i . -o . -f JSON"
  $proc = Start-Process -NoNewWindow -PassThru -FilePath $ORT_EXE -ArgumentList $ort_args
  $handle = $proc.Handle
  $proc.WaitForExit()
  $exitCode = $proc.ExitCode
  if (-Not ($exitCode -eq 0)) {
    MyThrow("ORT run failed! Exited with error code $exitCode.")
  }
  $ort_args = " -c $ORT_CONFIG report -i ./analyzer-result.json -o . -f PdfTemplate"
  $proc = Start-Process -NoNewWindow -PassThru -FilePath $ORT_EXE -ArgumentList $ort_args
  $handle = $proc.Handle
  $proc.WaitForExit()
  $exitCode = $proc.ExitCode
  if (-Not ($exitCode -eq 0)) {
    MyThrow("ORT run failed! Exited with error code $exitCode.")
  }
  $ort_args = " -c $ORT_CONFIG report -i ./analyzer-result.json -o . -f WebApp"
  $proc = Start-Process -NoNewWindow -PassThru -FilePath $ORT_EXE -ArgumentList $ort_args
  $handle = $proc.Handle
  $proc.WaitForExit()
  $exitCode = $proc.ExitCode
  if (-Not ($exitCode -eq 0)) {
    MyThrow("ORT run failed! Exited with error code $exitCode.")
  }
  Write-Host "Ort analysis completed!" -ForegroundColor Green
}

Pop-Location

$ErrorActionPreference = "SilentlyContinue"
Stop-Transcript | out-null
$ErrorActionPreference = "Continue"
