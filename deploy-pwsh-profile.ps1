#!/usr/bin/env pwsh

<#

.SYNOPSIS
        Deploy-Pwsh-Profile
        Created By: Stefano Sinigardi
        Created Date: March 05, 2026
        Last Modified Date: March 05, 2026

.DESCRIPTION
Deploy the PowerShell profile by creating symbolic links in the appropriate
OS-specific folders that PowerShell looks into for $PROFILE, pointing to
Microsoft.PowerShell_profile.ps1 stored in this repository.

  Windows (pwsh 7+) : [MyDocuments]\PowerShell\Microsoft.PowerShell_profile.ps1
                      [MyDocuments]\PowerShell\utils.psm1
  Windows (PS 5.1)  : [MyDocuments]\WindowsPowerShell\Microsoft.PowerShell_profile.ps1
                      [MyDocuments]\WindowsPowerShell\utils.psm1
  Linux             : $HOME/.config/powershell/Microsoft.PowerShell_profile.ps1
                      $HOME/.config/powershell/utils.psm1
  macOS             : $HOME/.config/powershell/Microsoft.PowerShell_profile.ps1
                      $HOME/.config/powershell/utils.psm1

[MyDocuments] is resolved via [Environment]::GetFolderPath('MyDocuments') to correctly
handle OneDrive or other folder-redirection scenarios.

.PARAMETER DisableInteractive
Disable script interactivity (useful for CI runs)

.EXAMPLE
.\Deploy-Pwsh-Profile -DisableInteractive

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

$deploy_pwsh_profile_ps1_version = "1.2.0"

Import-Module -Name $PSScriptRoot/utils.psm1 -Force

$ccmLog = Initialize-CcmLogging
trap { Stop-CcmLogging $ccmLog; break }

Write-Host "Deploy-PwshProfile script version ${deploy_pwsh_profile_ps1_version}, utils module version ${utils_psm1_version}"

Write-Host -NoNewLine "PowerShell version:"
$PSVersionTable.PSVersion

if ($IsWindowsPowerShell) {
  Write-Host "Running on Windows Powershell, please consider update and running on newer Powershell versions"
}

if ($PSVersionTable.PSVersion.Major -lt 5) {
  MyThrow("Your PowerShell version is too old, please update it.")
}

$profileSource = "$PSScriptRoot/Microsoft.PowerShell_profile.ps1"
if (-Not (Test-Path $profileSource)) {
  MyThrow("Source profile file not found: $profileSource")
}

$utilsSource = "$PSScriptRoot/utils.psm1"
if (-Not (Test-Path $utilsSource)) {
  MyThrow("Source utils file not found: $utilsSource")
}

# utils.psm1 is now a 6-line shim that Import-Module's CCM.psd1 from its own
# directory. For the shim to resolve at runtime, the profile directory must
# also contain symlinks to CCM.psd1, CCM.psm1, Public/, and Private/ —
# otherwise `Import-Module utils.psm1` fails with "CCM.psd1 not found".
$ccmManifestSource = "$PSScriptRoot/CCM.psd1"
if (-Not (Test-Path $ccmManifestSource)) {
  MyThrow("Source CCM manifest not found: $ccmManifestSource")
}

$ccmModuleSource = "$PSScriptRoot/CCM.psm1"
if (-Not (Test-Path $ccmModuleSource)) {
  MyThrow("Source CCM module not found: $ccmModuleSource")
}

$publicDirSource  = "$PSScriptRoot/Public"
$privateDirSource = "$PSScriptRoot/Private"
foreach ($dir in @($publicDirSource, $privateDirSource)) {
  if (-Not (Test-Path $dir)) { MyThrow("Source directory not found: $dir") }
}

function Deploy-FileLink {
  param([string]$linkPath, [string]$target)
  if (-Not (Test-Path $linkPath)) {
    Write-Host "Linking $target to $linkPath"
    New-Item -ItemType SymbolicLink -Path $linkPath -Target $target | Out-Null
    Write-Host "  Linked: $linkPath" -ForegroundColor Green
  }
  else {
    Write-Host "$linkPath already present"
  }
}

function Deploy-DirLink {
  param([string]$linkPath, [string]$target)
  # SymbolicLink on a directory works the same way as on a file in PS 7+.
  if (-Not (Test-Path $linkPath)) {
    Write-Host "Linking $target to $linkPath (directory)"
    New-Item -ItemType SymbolicLink -Path $linkPath -Target $target | Out-Null
    Write-Host "  Linked: $linkPath" -ForegroundColor Green
  }
  else {
    Write-Host "$linkPath already present"
  }
}

function Deploy-ProfileDir {
  param([string]$profileLink)
  $profileDir = Split-Path $profileLink -Parent
  New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
  Deploy-FileLink $profileLink $profileSource
  Deploy-FileLink (Join-Path $profileDir "utils.psm1") $utilsSource
  Deploy-FileLink (Join-Path $profileDir "CCM.psd1")  $ccmManifestSource
  Deploy-FileLink (Join-Path $profileDir "CCM.psm1")  $ccmModuleSource
  Deploy-DirLink  (Join-Path $profileDir "Public")    $publicDirSource
  Deploy-DirLink  (Join-Path $profileDir "Private")   $privateDirSource
}

# $IsWindows is available in PS 7+; $IsWindowsPowerShell (from utils.psm1) covers PS 5.1
if ($IsWindowsPowerShell -or $IsWindows) {
  # Use GetFolderPath to respect OneDrive/folder redirection instead of assuming $HOME\Documents
  $myDocuments = [Environment]::GetFolderPath('MyDocuments')
  # PS 7+ profile location
  Deploy-ProfileDir (Join-Path $myDocuments "PowerShell\Microsoft.PowerShell_profile.ps1")
  # Windows PowerShell 5.1 profile location
  Deploy-ProfileDir (Join-Path $myDocuments "WindowsPowerShell\Microsoft.PowerShell_profile.ps1")
}
else {
  # Linux / macOS: ~/.config/powershell/Microsoft.PowerShell_profile.ps1
  Deploy-ProfileDir $PROFILE
}

Write-Host "PowerShell profile deployed!" -ForegroundColor Green

Stop-CcmLogging $ccmLog
