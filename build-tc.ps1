#!/usr/bin/env pwsh

<#

.SYNOPSIS
        build-tc
        Created By: Stefano Sinigardi
        Created Date: October 17, 2024
        Last Modified Date: October 31, 2024

.DESCRIPTION
Build TwinCAT Project using the Beckhoff infrastructure through COM objects interface in PowerShell

.PARAMETER DisableInteractive
Disable script interactivity (useful for CI runs)

.PARAMETER DoNotUpdateTOOL
Do not update the tool before running the build (valid only if tool is git-enabled)

.EXAMPLE
./build-tc -DisableInteractive

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
  [string]$prjDir = ".",
  [string]$prjName = "Template_project.sln",
  [string]$platformToBuild = "TwinCAT RT (x64)",
  [switch]$DisableInteractive = $false,
  [switch]$DoNotUpdateTOOL = $false
)

$global:DisableInteractive = $DisableInteractive

$build_tc_ps1_version = "1.1.0"
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
$BuildTCLogPath = "$PSCustomScriptRoot/build-tc.log"
Start-Transcript -Path $BuildTCLogPath

Write-Host "Build TwinCAT script version ${build_tc_ps1_version}, utils module version ${utils_psm1_version}"
if (-Not $utils_psm1_avail) {
  Write-Host "utils.psm1 is not available, so VS integration is forcefully disabled" -ForegroundColor Yellow
}
Write-Host "Working directory: $PSCustomScriptRoot, log file: $BuildTCLogPath, $script_name is in submodule: $IsInGitSubmodule"

Write-Host -NoNewLine "PowerShell version:"
$PSVersionTable.PSVersion

if ($IsWindowsPowerShell) {
  Write-Host "Running on Windows Powershell, please consider update and running on newer Powershell versions"
  $BaseSleepTime = 1
}
else {
  $BaseSleepTime = 5
}

if ($PSVersionTable.PSVersion.Major -lt 5) {
  MyThrow("Your PowerShell version is too old, please update it.")
}

try {
    # Try TcXaeShell.DTE.17.0 first
    $dte = New-Object -ComObject TcXaeShell.DTE.17.0
    Write-Output "Successfully created TcXaeShell.DTE.17.0"
} catch {
    Write-Warning "TcXaeShell.DTE.17.0 not found, trying VisualStudio.DTE.17.0"
    try {
        # Fall back to VisualStudio.DTE.17.0 if TcXaeShell.DTE.17.0 fails
        $dte = New-Object -ComObject VisualStudio.DTE.17.0
        Write-Output "Successfully created VisualStudio.DTE.17.0"
    } catch {
        Write-Warning "VisualStudio.DTE.17.0 not found, trying TcXaeShell.DTE.15.0"
        try {
            # Fall back to TcXaeShell.DTE.15.0 if VisualStudio.DTE.17.0 fails
            $dte = New-Object -ComObject TcXaeShell.DTE.15.0
            Write-Output "Successfully created TcXaeShell.DTE.15.0"
        } catch {
            Write-Warning "TcXaeShell.DTE.15.0 not found, trying VisualStudio.DTE.15.0"
            try {
                # Fall back to VisualStudio.DTE.15.0 if TcXaeShell.DTE.15.0 fails
                $dte = New-Object -ComObject VisualStudio.DTE.15.0
                Write-Output "Successfully created VisualStudio.DTE.15.0"
            } catch {
                # Handle the case where none of the versions are available
                Write-Error "Neither TcXaeShell nor VisualStudio versions of DTE (17.0 or 15.0) could be created."
                exit 1
            }
        }
    }
}

$initial_sleep = 12 * $BaseSleepTime
$change_config_sleep = $BaseSleepTime
$build_sleep = 2 * $BaseSleepTime
$final_sleep = 2 * $BaseSleepTime

Push-Location $PSCustomScriptRoot

$prjPath = $prjDir + $prjName
Start-Sleep -s $initial_sleep
$dte.SuppressUI = $true

$sln = $dte.Solution
Write-Host "Opening $prjPath..."
$sln.Open("$prjPath")

Write-Host "Loading..."
Start-Sleep -s $initial_sleep
foreach ($config in $sln.SolutionBuild.SolutionConfigurations) {
  #$config | Get-Member
  if ($config.SolutionContexts | Select-Object -Property PlatformName) {
      $platformNames = $config.SolutionContexts | ForEach-Object { $_.PlatformName }
  }
  else {
      $platformNames = $config.PlatformName
  }
  Start-Sleep -s $change_config_sleep
  foreach($platformname in $platformNames) {
    if ($platformname -eq $platformToBuild) {
      Write-Host "Activating configuration: " $platformname " | " $config.Name
      $config.Activate()
      Start-Sleep -s $build_sleep
      Write-Host "Cleaning configuration:   " $platformname  " | " $config.Name
      $sln.SolutionBuild.Clean($true)
      Start-Sleep -s $build_sleep
      Write-Host "Building configuration:   " $platformname  " | " $config.Name
      $sln.SolutionBuild.Build($true)
      Start-Sleep -s $build_sleep
      $errorlog = $dte.ToolWindows.ErrorList.ErrorItems
      foreach ($erroritem in $errorlog.Item) {
        Write-Host "    Description:          " + $erroritem.Description
        Write-Host "    ErrorLevel:           " + $erroritem.ErrorLevel
        Write-Host "    Filename:             " + $erroritem.FileName
      }
      Write-Host "Error count:              " $errorlog.Count
      Write-Host "Built configuration:      " $platformname  " | " $config.Name
    } else {
      Write-Host "Discarding configuration: " $platformname  " | " $config.Name
    }
  }
}

$sln.Close()
Write-Host "Closing $prjPath..."
Start-Sleep -s $final_sleep

$dte.Quit()
Write-Host "Closing Visual Studio..."
Pop-Location

$ErrorActionPreference = "SilentlyContinue"
Stop-Transcript | out-null
$ErrorActionPreference = "Continue"
