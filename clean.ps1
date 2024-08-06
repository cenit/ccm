#! /usr/bin/env pwsh

<#

.SYNOPSIS
        clean
        Created By: Stefano Sinigardi
        Created Date: February 18, 2019
        Last Modified Date: February 20, 2023

.DESCRIPTION
Clean up build artifacts

.EXAMPLE
.\clean

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

$clean_ps1_version = "1.0.0"
$script_name = $MyInvocation.MyCommand.Name

Import-Module -Name $PSScriptRoot/utils.psm1 -Force

$ErrorActionPreference = "SilentlyContinue"
Stop-Transcript | out-null
$ErrorActionPreference = "Continue"
if($IsInGitSubmodule) {
  $PSCustomScriptRoot = Split-Path $PSScriptRoot -Parent
}
else {
  $PSCustomScriptRoot = $PSScriptRoot
}
$CleanLogPath = "$PSCustomScriptRoot/clean.log"

Start-Transcript -Path $CleanLogPath

Write-Host "Clean script version ${clean_ps1_version}, utils module version ${utils_psm1_version}"
Write-Host "Working directory: $PSCustomScriptRoot, log file: $CleanLogPath, $script_name is in submodule: $IsInGitSubmodule"

Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/bin/*.exe
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/bin/*.conf
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/bin/*.dll

Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/debug/bin/*.exe
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/debug/bin/*.conf
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/debug/bin/*.dll

Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $PSCustomScriptRoot/bin/plugins/
Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $PSCustomScriptRoot/debug/bin/plugins/

Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/*.exe
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/*.dll

$ErrorActionPreference = "SilentlyContinue"
Stop-Transcript | out-null
$ErrorActionPreference = "Continue"
