#!/usr/bin/env pwsh

<#

.SYNOPSIS
        verify-test-log
        Created By: Stefano Sinigardi
        Created Date: February 18, 2019
        Last Modified Date: September 20, 2022

.DESCRIPTION
Check logs produced by test tools and verify that they didn't change after last run

.PARAMETER TestLogFolder
Folder which contains test logs

.PARAMETER TestBinFolder
Folder which contains test binaries

.EXAMPLE
./verify-test-log.ps1 -TestLogFolder ../bin/test/folder -TestBinFolder ../log/test/folder

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
  [string]$TestBinFolder = "../bin",
  [string]$TestLogFolder = "../test"
)

$global:DisableInteractive = $DisableInteractive

$verify_ps1_version = "0.0.3"

Import-Module -Name $PSScriptRoot/utils.psm1 -Force

Write-Host "Verify test log script version ${verify_ps1_version}, utils module version ${utils_psm1_version}"

New-Item -ItemType Directory -Force -Path ${TestLogFolder} | Out-Null

$test_bins = Get-ChildItem ${TestBinFolder}/*

foreach ($test_bin in $test_bins) {
  $testname = $test_bin.Basename
  & $test_bin > ${TestLogFolder}/${testname}.log
}

$counter=0
$passed=0

$old_files = Get-ChildItem ${TestLogFolder}/*.log.old
$new_files = Get-ChildItem ${TestLogFolder}/*.log

if ( $old_files.Count -eq 0 ) {
  Write-Host "First test call, creating old copies of output files." -ForegroundColor Yellow
  foreach ($new_file in $new_files) {
    Copy-Item "${new_file}" "${new_file}.old"
  }
}

# Test loop compare new test log with old ones
foreach ($new_file in $new_files) {
  $counter++
  $df = compare-object (get-content "${new_file}") (get-content "${new_file}.old")
  $testname=$new_file.Basename
  Write-Host "Test for $testname : " -NoNewline
  if ( $null -eq $df ) {
    Write-Host "OK" -ForegroundColor Green
    $passed++
  }
  else {
    Write-Host "Failed" -ForegroundColor Red
  }
}
Write-Host "Test passed      : $passed/$counter ( $(($passed/$counter).tostring("P")) )"
