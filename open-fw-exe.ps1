#!/usr/bin/env pwsh
#Requires -RunAsAdministrator

<#

.SYNOPSIS
        open-fw-exe
        Created By: Stefano Sinigardi
        Created Date: February 15, 2023
        Last Modified Date: February 15, 2023

.DESCRIPTION
Open Firewall for a specific executable

.PARAMETER DisableInteractive
Disable script interactivity (useful for CI runs)

.PARAMETER ExecutablePath
Path to the executable to open the firewall for

.PARAMETER FirewallRuleName
Firewall rule name (not mandatory, if not given the executable name will be used also for the rule name)

.EXAMPLE
.\open-fw-exe -ExecutablePath C:\MyApp\MyExe.exe

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
  [string]$ExecutablePath = "",
  [string]$FirewallRuleName = ""
)

$global:DisableInteractive = $DisableInteractive

$open_fw_exe_version = "0.0.1"

Import-Module -Name $PSScriptRoot/utils.psm1 -Force

$ErrorActionPreference = "SilentlyContinue"
Stop-Transcript | out-null
$ErrorActionPreference = "Continue"
$LogPath = switch ( $IsInGitSubmodule ) {
  $true { "$PSScriptRoot/../open-fw-exe.log" }
  $false { "$PSScriptRoot/open-fw-exe.log" }
}
Start-Transcript -Path $LogPath

Write-Host "Open Firewall for executables script version ${open_fw_exe_version}, utils module version ${utils_psm1_version}"

Write-Host -NoNewLine "PowerShell version:"
$PSVersionTable.PSVersion

if ($IsInGitSubmodule) {
  Write-Host "Running scripts from a Git Submodule"
}
else {
  Write-Host "Outside of a git submodule"
}

if ($IsWindowsPowerShell) {
  Write-Host "Running on Windows Powershell, please consider update and running on newer Powershell versions"
}

if ($PSVersionTable.PSVersion.Major -lt 5) {
  MyThrow("Your PowerShell version is too old, please update it.")
}

if ($ExecutablePath -eq "") {
  MyThrow("Executable path is required")
}

$ExecutablePathFixed = Get-ChildItem ${ExecutablePath} -ErrorAction SilentlyContinue

if(-not $ExecutablePathFixed) {
  MyThrow("Executable path ${ExecutablePath} not found")
}
else {
  if ($FirewallRuleName -eq "") {
    $FirewallRuleName = Split-Path $ExecutablePathFixed -leaf
  }
  New-NetFirewallRule -DisplayName "$FirewallRuleName" -Action Allow -EdgeTraversalPolicy Allow -LocalPort Any -Program "$ExecutablePathFixed" | Out-Null
  Write-Host "Firewall rule created for $FirewallRuleName" -ForegroundColor Green
}

$ErrorActionPreference = "SilentlyContinue"
Stop-Transcript | out-null
$ErrorActionPreference = "Continue"
