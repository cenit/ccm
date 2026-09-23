# Centralized declaration of back-compat aliases for legacy function names.
# Suppress PSUseApprovedVerbs for the alias declarations themselves — the
# whole point of this file is to expose names that intentionally don't
# follow the convention.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
param()

New-Alias -Name 'activateVenv'                                    -Value 'Enable-PythonVenv'                    -Force
New-Alias -Name 'getProgramFiles32bit'                            -Value 'Get-ProgramFiles32Bit'                -Force
New-Alias -Name 'getProgramFiles64bit'                            -Value 'Get-ProgramFiles64Bit'                -Force
New-Alias -Name 'getLatestVisualStudioWithDesktopWorkloadPath'    -Value 'Get-VisualStudioPath'                 -Force
New-Alias -Name 'getLatestVisualStudioWithDesktopWorkloadVersion' -Value 'Get-VisualStudioVersion'              -Force
New-Alias -Name 'setupVisualStudio'                               -Value 'Initialize-VisualStudioEnvironment'   -Force
New-Alias -Name 'setupPostgres'                                   -Value 'Initialize-PostgresEnvironment'       -Force
New-Alias -Name 'DownloadNinja'                                   -Value 'Save-Ninja'                           -Force
New-Alias -Name 'DownloadAria2'                                   -Value 'Save-Aria2'                           -Force
New-Alias -Name 'Download7Zip'                                    -Value 'Save-7Zip'                            -Force
New-Alias -Name 'DownloadLicencpp'                                -Value 'Save-Licencpp'                        -Force
New-Alias -Name 'MyThrow'                                         -Value 'Write-CcmFatalError'                  -Force
New-Alias -Name 'CopyTexFile'                                     -Value 'Copy-TexFile'                         -Force
New-Alias -Name 'dos2unix'                                        -Value 'ConvertTo-UnixLineEnding'             -Force
New-Alias -Name 'unix2dos'                                        -Value 'ConvertTo-WindowsLineEnding'          -Force
New-Alias -Name 'UpdateRepo'                                      -Value 'Update-GitRepo'                       -Force
