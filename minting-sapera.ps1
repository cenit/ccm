#!/usr/bin/env pwsh
#Requires -RunAsAdministrator

<#

.SYNOPSIS
        minting-sapera
        Created By: Stefano Sinigardi
        Created Date: February 9, 2023
        Last Modified Date: February 21, 2023

.DESCRIPTION
Manage unattended SaperaLT install procedures

.PARAMETER DisableInteractive
Disable script interactivity (useful for CI runs)

.PARAMETER DryRun
Run the script without actually installing anything

.PARAMETER DisableSilent
Disable silent running of the installers, which means dialogs will be shown

.PARAMETER SaperaVersion
Version of SaperaLT to be installed; possible choices are
850-RUNTIME
871-RUNTIME
900-RUNTIME

.PARAMETER Uninstall
Uninstall target instead of installing it

.EXAMPLE
.\minting-sapera -DisableInteractive -SaperaVersion 850-RUNTIME

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
  [switch]$DryRun = $false,
  [switch]$DisableSilent = $false,
  [switch]$Uninstall = $false,
  [string]$SaperaVersion = ""
)

$global:DisableInteractive = $DisableInteractive

$minting_sapera_version = "1.1.0"

Import-Module -Name $PSScriptRoot/utils.psm1 -Force

$InstallerBasePath = switch ( $IsInGitSubmodule ) {
  $true { "$PSScriptRoot/../" }
  $false { "$PSScriptRoot/" }
}
$INIPrefix = switch ( $IsInGitSubmodule ) {
  $true { "$PSScriptRoot/../" }
  $false { "$PSScriptRoot/" }
}

$ccmLog = Initialize-CcmLogging
trap { Stop-CcmLogging $ccmLog; break }

Write-Host "Minting script version ${minting_sapera_version}, utils module version ${utils_psm1_version}"

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

$ISSPrefix = switch ( $IsInGitSubmodule ) {
  $true { "$PSScriptRoot/.." }
  $false { "$PSScriptRoot" }
}

class saperaInstaller {
  [string]$FileName
  [bool]$AvailableOnInternet
  [string]$DownloadLink
}

if ($SaperaVersion -eq "850-RUNTIME") {
  $BaseVersion = 850
  $64bitVersion = $true
  $OpenPortsOnFirewall = $false
  $installers = @(
    [saperaInstaller]@{
      FileName            = "sapera_lt_850_runtimesetup.exe";
      AvailableOnInternet = $false;
      DownloadLink        = ""
    }
  )

  $sapera_INI_Setup_FileName = "$INIPrefix/sapera_lt_850_runtimesetup.iss"
  if ($Uninstall) {
    $sapera_INI_Setup_Content = @"
[InstallShield Silent]
Version=v7.00
File=Response File
[File Transfer]
OverwrittenReadOnly=NoToAll
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-DlgOrder]
Dlg0={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdWelcomeMaint-0
Count=3
Dlg1={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SprintfBox-0
Dlg2={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdFinishReboot-0
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdWelcomeMaint-0]
Result=303
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SprintfBox-0]
Result=1
[Application]
Name=Sapera LT
Version=8.50.00.2011
Company=Teledyne DALSA
Lang=0409
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdFinishReboot-0]
Result=1
BootOption=0
"@
  }
  else {
    $sapera_INI_Setup_Content = @"
[InstallShield Silent]
Version=v7.00
File=Response File
[File Transfer]
OverwrittenReadOnly=NoToAll
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-DlgOrder]
Dlg0={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdWelcome-0
Count=8
Dlg1={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdLicense-0
Dlg2={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdLicense-1
Dlg3={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-AskOptions-0
Dlg4={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdAskDestPath-0
Dlg5={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdSelectFolder-0
Dlg6={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-MessageBox-0
Dlg7={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdFinishReboot-0
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdWelcome-0]
Result=1
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdLicense-0]
Result=1
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdLicense-1]
Result=1
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-AskOptions-0]
Result=1
Sel-0=1
Sel-1=0
Sel-2=0
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdAskDestPath-0]
szDir=C:\Program Files\Teledyne DALSA\Sapera
Result=1
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdSelectFolder-0]
szFolder=Teledyne DALSA Sapera LT
Result=1
[Application]
Name=Sapera LT
Version=8.50.00.2011
Company=Teledyne DALSA
Lang=0409
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-MessageBox-0]
Result=1
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdFinishReboot-0]
Result=1
BootOption=0
"@
  }
  Out-File -FilePath $sapera_INI_Setup_FileName -InputObject $sapera_INI_Setup_Content -Encoding ASCII
}
elseif ($SaperaVersion -eq "871-RUNTIME") {
  $BaseVersion = 871
  $64bitVersion = $true
  $OpenPortsOnFirewall = $false
  $installers = @(
    [saperaInstaller]@{
      FileName            = "sapera_lt_871_runtime.exe";
      AvailableOnInternet = $false;
      DownloadLink        = ""
    }
  )

  $sapera_INI_Setup_FileName = "$INIPrefix/sapera_lt_871_runtime.iss"
  if ($Uninstall) {
    $sapera_INI_Setup_Content = @"
[InstallShield Silent]
Version=v7.00
File=Response File
[File Transfer]
OverwrittenReadOnly=NoToAll
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-DlgOrder]
Dlg0={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdWelcomeMaint-0
Count=3
Dlg1={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SprintfBox-0
Dlg2={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdFinishReboot-0
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdWelcomeMaint-0]
Result=303
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SprintfBox-0]
Result=1
[Application]
Name=Sapera LT
Version=8.71.00.2228
Company=Teledyne DALSA
Lang=0409
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdFinishReboot-0]
Result=1
BootOption=0
"@
  }
  else {
    $sapera_INI_Setup_Content = @"
[InstallShield Silent]
Version=v7.00
File=Response File
[File Transfer]
OverwrittenReadOnly=NoToAll
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-DlgOrder]
Dlg0={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdWelcome-0
Count=8
Dlg1={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdLicense-0
Dlg2={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdLicense-1
Dlg3={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-AskOptions-0
Dlg4={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdAskDestPath-0
Dlg5={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdSelectFolder-0
Dlg6={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-MessageBox-0
Dlg7={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdFinishReboot-0
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdWelcome-0]
Result=1
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdLicense-0]
Result=1
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdLicense-1]
Result=1
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-AskOptions-0]
Result=1
Sel-0=1
Sel-1=1
Sel-2=0
Sel-3=0
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdAskDestPath-0]
szDir=C:\Program Files\Teledyne DALSA\Sapera
Result=1
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdSelectFolder-0]
szFolder=Teledyne DALSA Sapera LT
Result=1
[Application]
Name=Sapera LT
Version=8.71.00.2228
Company=Teledyne DALSA
Lang=0409
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-MessageBox-0]
Result=1
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdFinishReboot-0]
Result=1
BootOption=0
"@
  }
  Out-File -FilePath $sapera_INI_Setup_FileName -InputObject $sapera_INI_Setup_Content -Encoding ASCII
}
elseif ($SaperaVersion -eq "900-RUNTIME") {
  $BaseVersion = 871
  $64bitVersion = $true
  $OpenPortsOnFirewall = $false
  $installers = @(
    [saperaInstaller]@{
      FileName            = "sapera_lt_900_runtime.exe";
      AvailableOnInternet = $false;
      DownloadLink        = ""
    }
  )

  $sapera_INI_Setup_FileName = "$INIPrefix/sapera_lt_900_runtime.iss"
  if ($Uninstall) {
    $sapera_INI_Setup_Content = @"
[InstallShield Silent]
Version=v7.00
File=Response File
[File Transfer]
OverwrittenReadOnly=NoToAll
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-DlgOrder]
Dlg0={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdWelcomeMaint-0
Count=3
Dlg1={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SprintfBox-0
Dlg2={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdFinish-0
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdWelcomeMaint-0]
Result=303
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SprintfBox-0]
Result=1
[Application]
Name=Sapera LT
Version=9.00.00.2326
Company=Teledyne DALSA
Lang=0409
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdFinish-0]
Result=1
bOpt1=0
bOpt2=0
"@
  }
  else {
    $sapera_INI_Setup_Content = @"
[InstallShield Silent]
Version=v7.00
File=Response File
[File Transfer]
OverwrittenReadOnly=NoToAll
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-DlgOrder]
Dlg0={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdWelcome-0
Count=9
Dlg1={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdLicense-0
Dlg2={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdLicense-1
Dlg3={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-AskOptions-0
Dlg4={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdAskDestPath-0
Dlg5={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdSelectFolder-0
Dlg6={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-MessageBox-0
Dlg7={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-MessageBox-1
Dlg8={03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdFinishReboot-0
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdWelcome-0]
Result=1
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdLicense-0]
Result=1
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdLicense-1]
Result=1
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-AskOptions-0]
Result=1
Sel-0=1
Sel-1=1
Sel-2=1
Sel-3=1
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdAskDestPath-0]
szDir=C:\Program Files\Teledyne DALSA\Sapera
Result=1
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdSelectFolder-0]
szFolder=Teledyne DALSA Sapera LT
Result=1
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-MessageBox-0]
Result=1
[Application]
Name=Sapera LT
Version=9.00.00.2326
Company=Teledyne DALSA
Lang=0409
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-MessageBox-1]
Result=1
[{03A1E44A-4B8B-4FEC-8368-B30F8FFDA0B6}-SdFinishReboot-0]
Result=1
BootOption=0
"@
  }
  Out-File -FilePath $sapera_INI_Setup_FileName -InputObject $sapera_INI_Setup_Content -Encoding ASCII
}
else {
  MyThrow("Unrecognized sapera version")
}

foreach ($installer in $installers) {
  if (Test-Path -Path $InstallerBasePath/$($installer.FileName)) {
    Write-Host "Installing from $InstallerBasePath/$($installer.FileName)"
    Write-Host "BaseVersion = $BaseVersion"
    Write-Host "64bitVersion = $64bitVersion"
    Write-Host "OpenPortsOnFirewall = $OpenPortsOnFirewall"
  }
  elseif ($installer.AvailableOnInternet) {
    $aria2 = DownloadAria2
    $downloadArgs = " -x 2 --file-allocation=none $($installer.DownloadLink) -d $($InstallerBasePath) -o $($installer.FileName) "
    Write-Host "Downloading $InstallerBasePath/$($installer.FileName)"
    $proc = Start-Process -NoNewWindow -PassThru -FilePath $aria2 -ArgumentList $downloadArgs
    $handle = $proc.Handle
    $proc.WaitForExit()
    $exitCode = $proc.ExitCode
    if ($exitCode -eq 0) {
      Write-Host "Download completed" -ForegroundColor Green
    }
    else {
      MyThrow("Download failed! Exited with error code $exitCode.")
    }
  }
  else {
    MyThrow("Missing $InstallerBasePath/$($installer.FileName), unable to download automatically")
  }

  # Note: to generate the spec file, please run installer interactively with this command:
  #      installer.exe -r
  # a spec file will be generated in the C:\Windows directory
  # note that also uninstall requires a response file like an installation, but run from a computer
  # where the software has been already installed so that the response is valid

  $filePath = Get-ChildItem $InstallerBasePath/$($installer.FileName)
  $fileBasename = ${filePath}.Basename
  $iniFile = "$INIPrefix/${fileBasename}.iss"
  $setupArgs = " /f1`"$iniFile`" "
  if (-Not $DisableSilent) {
    $setupArgs += " /S /a /s "
  }

  if ($DryRun) {
    Write-Host "DryRun: $filePath $setupArgs" -ForegroundColor Yellow
  }
  else {
    Write-Host "Running: $filePath $setupArgs" -ForegroundColor Yellow
    $proc = Start-Process -NoNewWindow -PassThru -FilePath $filePath -ArgumentList $setupArgs
    $handle = $proc.Handle
    $proc.WaitForExit()
    $exitCode = $proc.ExitCode
    if ($Uninstall) {
      if ($exitCode -eq 0) {
        Write-Host "Uninstall was fine, application has been removed" -ForegroundColor Green
      }
      elseif ($exitCode -eq 3010) {
        Write-Host "Uninstall was fine, system requires reboot" -ForegroundColor Yellow
      }
      elseif ($exitCode -eq -2147213312) {
        Write-Host "Uninstall didn't find the application installed" -ForegroundColor Yellow
      }
      else {
        MyThrow("Uninstall failed! Exited with error code $exitCode.")
      }
    }
    else {
      if ($exitCode -eq 0) {
        Write-Host "Setup was fine, application is ready" -ForegroundColor Green
      }
      elseif ($exitCode -eq 3010) {
        Write-Host "Setup was fine, application requires reboot before usage" -ForegroundColor Yellow
      }
      else {
        MyThrow("Setup failed! Exited with error code $exitCode.")
      }
    }
  }
  Write-Host "Finished setup operations from $InstallerBasePath/$($installer.FileName)"
}

Write-Host "Minting complete!" -ForegroundColor Green
Write-Host "A reboot might be mandatory for many functionalities to be alive!" -ForegroundColor Red

Stop-CcmLogging $ccmLog
