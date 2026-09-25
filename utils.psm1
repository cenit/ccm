# Back-compat shim. Forwards to the proper CCM module so legacy consumers
# doing `Import-Module ./CCM/utils.psm1` or `. ./CCM/utils.psm1` keep
# working. New consumers should prefer `Import-Module CCM` (from a
# PowerShell package feed) or `Import-Module ./CCM/CCM.psd1` directly.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CCM.psd1') -Force -Global
