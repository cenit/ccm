#!/usr/bin/env pwsh

$utils_psm1_avail = $false
$load_utils_psm1 = $false
$Verbose = $false
$profile_ps1_version = "1.0.0"

if ($load_utils_psm1) {
  if (Test-Path $PSScriptRoot/utils.psm1) {
    Import-Module -Name $PSScriptRoot/utils.psm1 -Force
    $utils_psm1_avail = $true
  }
  elseif (Test-Path $PSScriptRoot/cmake/utils.psm1) {
    Import-Module -Name $PSScriptRoot/cmake/utils.psm1 -Force
    $utils_psm1_avail = $true
  }
  elseif (Test-Path $PSScriptRoot/ci/utils.psm1) {
    Import-Module -Name $PSScriptRoot/ci/utils.psm1 -Force
    $utils_psm1_avail = $true
  }
  elseif (Test-Path $PSScriptRoot/ccm/utils.psm1) {
    Import-Module -Name $PSScriptRoot/ccm/utils.psm1 -Force
    $utils_psm1_avail = $true
  }
  else {
    $utils_psm1_version = "unavail"
  }
  if ($Verbose) {
    Write-Host "Profile version ${profile_ps1_version}, utils module version ${utils_psm1_version}"
    if (-Not $utils_psm1_avail) {
      Write-Host "utils.psm1 is not available, so VS integration is forcefully disabled" -ForegroundColor Yellow
    }
  }
}

Set-PSReadlineKeyHandler -Key ctrl+d -Function ViExit
Set-Alias ll Get-ChildItem

$OHMYPOSH_EXE = Get-Command "oh-my-posh" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
if ($OHMYPOSH_EXE) {
  &$OHMYPOSH_EXE init pwsh --config "$env:POSH_THEMES_PATH/agnoster.minimal.omp.json" | Invoke-Expression
}
