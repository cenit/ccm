#!/usr/bin/env pwsh
#Requires -RunAsAdministrator

<#

.SYNOPSIS
        enable-iis
        Created By: Stefano Sinigardi
        Created Date: March 6, 2023
        Last Modified Date: March 6, 2023

.DESCRIPTION
Enables IIS feature and optionally adds directory browsing for a given path

.PARAMETER DisableInteractive
Disable script interactivity (useful for CI runs)

.PARAMETER BrowsePath
Path to enable directory browsing. If not given, directory browsing will not be enabled

.EXAMPLE
.\enable-iis -BrowsePath C:\MyApp\MyStorageArea

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
  [string]$BrowsePath = "",
  [string]$VirtualPath = ""
)

$global:DisableInteractive = $DisableInteractive

$enable_iis_version = "0.0.1"

Import-Module -Name $PSScriptRoot/utils.psm1 -Force

$ErrorActionPreference = "SilentlyContinue"
Stop-Transcript | out-null
$ErrorActionPreference = "Continue"
$LogPath = switch ( $IsInGitSubmodule ) {
  $true { "$PSScriptRoot/../enable-iis.log" }
  $false { "$PSScriptRoot/enable-iis.log" }
}
Start-Transcript -Path $LogPath

Write-Host "Enable IIS script version ${enable_iis_version}, utils module version ${utils_psm1_version}"

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

if (-not $64bitPwsh -eq $64bitOS) {
  MyThrow("You are running a 32-bit PowerShell on a 64-bit OS, please use a 64-bit PowerShell instead.")
}

Enable-WindowsOptionalFeature -NoRestart -Online -FeatureName IIS-WebServerRole, IIS-WebServer, IIS-CommonHttpFeatures, IIS-ManagementConsole, IIS-HttpErrors, IIS-HttpRedirect, IIS-WindowsAuthentication, IIS-StaticContent, IIS-DefaultDocument, IIS-HttpCompressionStatic, IIS-DirectoryBrowsing

if (-not $BrowsePath -eq "") {
  if ($VirtualPath -eq "") {
    $VirtualPath = "pub"
  }
  $BrowsePathFixed = Resolve-Path "$BrowsePath" -ErrorAction SilentlyContinue
  if (Test-Path "$BrowsePathFixed") {
    # & $env:SYSTEMROOT\system32\inetsrv\appcmd.exe set config /section:directoryBrowse /enabled:true
    Import-Module WebAdministration
    New-WebVirtualDirectory -Site "Default Web Site" -Name $VirtualPath -PhysicalPath "$BrowsePathFixed"
    Set-WebConfigurationProperty -filter /system.webServer/directoryBrowse -name enabled -value true -PSPath "IIS:\Sites\Default Web Site\$VirtualPath"
    $accessRuleIIS_IUSRS = New-Object System.Security.AccessControl.FileSystemAccessRule("IIS_IUSRS", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    $accessRuleIUSR = New-Object System.Security.AccessControl.FileSystemAccessRule("IUSR", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl = Get-ACL "$BrowsePathFixed"
    $acl.AddAccessRule($accessRuleIIS_IUSRS)
    $acl.AddAccessRule($accessRuleIUSR)
    Set-ACL -Path "$BrowsePathFixed" -ACLObject $acl
  }
  else {
    MyThrow("Browse path ${BrowsePath} not found")
  }
}
else {
  Write-Host "Browse path not given, skipping" -ForegroundColor Blue
}

Write-Host "IIS Enabled" -ForegroundColor Green

$ErrorActionPreference = "SilentlyContinue"
Stop-Transcript | out-null
$ErrorActionPreference = "Continue"
