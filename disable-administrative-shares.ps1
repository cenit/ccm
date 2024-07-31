#!/usr/bin/env pwsh
#Requires -RunAsAdministrator

<#

.SYNOPSIS
        disable-administrative-shares
        Created By: Stefano Sinigardi
        Created Date: March 14, 2023
        Last Modified Date: March 14, 2023

.DESCRIPTION
Disables administrative shares on the pc (ability to browse \\ip\c$ for C drive remotely)

.PARAMETER DisableInteractive
Disable script interactivity (useful for CI runs)

.EXAMPLE
.\disable-administrative-shares

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
  [switch]$DisableInteractive = $false
)

$global:DisableInteractive = $DisableInteractive

$disable_administrative_shares_version = "0.0.1"

Import-Module -Name $PSScriptRoot/utils.psm1 -Force

$ErrorActionPreference = "SilentlyContinue"
Stop-Transcript | out-null
$ErrorActionPreference = "Continue"
$LogPath = switch ( $IsInGitSubmodule ) {
  $true { "$PSScriptRoot/../disable-administrative-shares.log" }
  $false { "$PSScriptRoot/disable-administrative-shares.log" }
}
Start-Transcript -Path $LogPath

Write-Host "Disable administrative shares script version ${disable_administrative_shares_version}, utils module version ${utils_psm1_version}"

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

$registryPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
$name = "LocalAccountTokenFilterPolicy"
$value = "0"

if (!(Test-Path $registryPath)) {
  New-Item -Path $registryPath -Force | Out-Null
  New-ItemProperty -Path $registryPath -Name $name -Value $value -PropertyType DWORD -Force | Out-Null
}
else {
  New-ItemProperty -Path $registryPath -Name $name -Value $value -PropertyType DWORD -Force | Out-Null
}

Write-Host "Administrative shares (C$) disabled" -ForegroundColor Green

$ErrorActionPreference = "SilentlyContinue"
Stop-Transcript | out-null
$ErrorActionPreference = "Continue"
