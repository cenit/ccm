#!/usr/bin/env pwsh

<#

.SYNOPSIS
        Deploy-Templates
        Created By: Stefano Sinigardi
        Created Date: April 06, 2022
        Last Modified Date: April 26, 2022

.DESCRIPTION
Deploy custom LaTeX classes and packages to the user's local texmf folder

.PARAMETER DisableInteractive
Disable script interactivity (useful for CI runs)

.PARAMETER ArtifactName
Artifact name (e.g. latex-physycom)

.EXAMPLE
.\Deploy-Templates -DisableInteractive

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
  [string]$ArtifactName = ""
)

$global:DisableInteractive = $DisableInteractive

$deploy_templates_ps1_version = "1.0.5"

Import-Module -Name $PSScriptRoot/utils.psm1 -Force

$ErrorActionPreference = "SilentlyContinue"
Stop-Transcript | out-null
$ErrorActionPreference = "Continue"
Start-Transcript -Path "$PSScriptRoot/../deploy-templates.log"

Write-Host "Deploy-Templates script version ${deploy_templates_ps1_version}, utils module version ${utils_psm1_version}"

Write-Host -NoNewLine "PowerShell version:"
$PSVersionTable.PSVersion

if ($IsWindowsPowerShell) {
  Write-Host "Running on Windows Powershell, please consider update and running on newer Powershell versions"
}

if ($PSVersionTable.PSVersion.Major -lt 5) {
  MyThrow("Your PowerShell version is too old, please update it.")
}

if ($IsMacOS) {
  $latex_path = "texmf/tex/latex/local/"
}
else {
  $latex_path = "texmf/tex/generic/"
}

$ParentFolder = Split-Path -Path $PSScriptRoot -Parent | Split-Path -Leaf

if ($ParentFolder -match "templates_") {
  Write-Host "Parent folder ($ParentFolder) matches a template folder, deploying files to system"
  New-Item -ItemType Directory -Force -Path "~/${latex_path}" | Out-Null
  Push-Location "$PSScriptRoot/../texmf/tex/generic"
  Get-ChildItem -Path . | ForEach-Object {
    $MyFileName = Split-Path $_ -Leaf
    if (-Not (Test-Path "~/${latex_path}/$MyFileName" )) {
      Write-Host "Linking $_ to ~/${latex_path}/$MyFileName"
      New-Item -ItemType SymbolicLink -Path "~/${latex_path}/$MyFileName" -Target $_ | Out-Null
    }
    else{
      Write-Host "~/${latex_path}/$MyFileName already present"
    }
  }
  Pop-Location
  Write-Host "Deploy complete!" -ForegroundColor Green
}
else {
  if (-Not $ArtifactName) {
    MyThrow("Missing necessary parameters")
  }

  Get-ChildItem -Path $PSScriptRoot/../$ArtifactName/texmf/tex/generic | ForEach-Object {
    CopyTexFile($_)
  }
}

$ErrorActionPreference = "SilentlyContinue"
Stop-Transcript | out-null
$ErrorActionPreference = "Continue"
