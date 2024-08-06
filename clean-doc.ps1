#! /usr/bin/env pwsh

<#

.SYNOPSIS
        clean-doc
        Created By: Stefano Sinigardi
        Created Date: February 18, 2019
        Last Modified Date: February 20, 2023

.DESCRIPTION
Clean up documentation artifacts

.PARAMETER RemoveAlsoPDFFiles
Deletes also pdf artifacts, not just intermediate files

.PARAMETER RemoveAlsoBINFolder
Deletes also bin folder

.EXAMPLE
.\clean-doc -RemoveAlsoPDFFiles

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
  [switch]$RemoveAlsoBINFolder = $false,
  [switch]$RemoveAlsoPDFFiles = $false
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

Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $PSCustomScriptRoot/doc/latex
Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $PSCustomScriptRoot/doc/html
Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $PSCustomScriptRoot/build_release

Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/doc/warnings.txt

Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/doc/*.aux
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/doc/*.fls
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/doc/*.fdb_latexmk
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/doc/*.log
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/doc/*.nav
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/doc/*.out
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/doc/*.snm
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/doc/*.synctex.gz
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/doc/*.synctex`(busy`)
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/doc/*.toc
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/doc/*.idx
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/doc/*.ilg
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/doc/*.ind


Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/*.aux
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/*.fls
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/*.fdb_latexmk
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/*.log
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/*.nav
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/*.out
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/*.snm
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/*.synctex.gz
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/*.synctex`(busy`)
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/*.toc
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/*.idx
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/*.ilg
Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/*.ind


if ($RemoveAlsoPDFFiles) {
  Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/*.pdf
  Remove-Item -Force -ErrorAction SilentlyContinue $PSCustomScriptRoot/doc/*.pdf
}

if ($RemoveAlsoBINFolder) {
  Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $PSCustomScriptRoot/bin
}

$ErrorActionPreference = "SilentlyContinue"
Stop-Transcript | out-null
$ErrorActionPreference = "Continue"
