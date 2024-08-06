#!/usr/bin/env pwsh
#Requires -RunAsAdministrator

<#

.SYNOPSIS
        close-fw-rule
        Created By: Stefano Sinigardi
        Created Date: February 16, 2023
        Last Modified Date: February 16, 2023

.DESCRIPTION
Remove a specific firewall rule

.PARAMETER DisableInteractive
Disable script interactivity (useful for CI runs)

.PARAMETER FirewallRuleName
Firewall rule name to be removed

.EXAMPLE
.\close-fw-rule -FirewallRuleName "MyRule"

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
  [string]$FirewallRuleName = ""
)

$global:DisableInteractive = $DisableInteractive

$close_fw_rule_version = "0.0.1"

Import-Module -Name $PSScriptRoot/utils.psm1 -Force

$ErrorActionPreference = "SilentlyContinue"
Stop-Transcript | out-null
$ErrorActionPreference = "Continue"
$LogPath = switch ( $IsInGitSubmodule ) {
  $true { "$PSScriptRoot/../close-fw-rule.log" }
  $false { "$PSScriptRoot/close-fw-rule.log" }
}
Start-Transcript -Path $LogPath

Write-Host "Close Firewall (remove rule) version ${close_fw_rule_version}, utils module version ${utils_psm1_version}"

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

if ($FirewallRuleName -eq "") {
  MyThrow("Firewall rule name is required")
}

Remove-NetFirewallRule -DisplayName $FirewallRuleName
Write-Host "Firewall rule $FirewallRuleName removed" -ForegroundColor Green

$ErrorActionPreference = "SilentlyContinue"
Stop-Transcript | out-null
$ErrorActionPreference = "Continue"
