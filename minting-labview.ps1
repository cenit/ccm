#!/usr/bin/env pwsh
#Requires -RunAsAdministrator

<#

.SYNOPSIS
        minting-labview
        Created By: Stefano Sinigardi
        Created Date: August 9, 2022
        Last Modified Date: April 11, 2025

.DESCRIPTION
Manage unattended LabVIEW install/uninstall procedures for different specified LabVIEW versions (IDE or RunTime)

.PARAMETER DisableInteractive
Disable script interactivity (useful for CI runs)

.PARAMETER DisableSourceOnlyVIs
Disable the automatic activation of option for creating source-only VIs (which is very important when source-controlling VIs - so disable at your own risk!)

.PARAMETER DryRun
Do not really run installer executables or execute commands on the target pc

.PARAMETER UninstallAll
Uninstall all NI software from computer. Requires NI Package Manager installed (not present for very old installation); in case NI Package Manager is missing, the script will ask to be relaunched to install it (.\minting-labview -DisableInteractive -LabVIEWVersion NIPKG); afterwards you can re-run it again to uninstall all NI software

.PARAMETER InstallerBasePath
Path where NI installation media are already stored or will be stored after the run if they have to be downloaded

.PARAMETER LabVIEWVersion
Version of LabVIEW to be installed; possible choices are
NIPKG
2018SP1-64-IDE
2018SP1-64-RUNTIME
2020SP1-64-IDE
2021-64-IDE
2021-64-RUNTIME
2021SP1-32-IDE
2021SP1-32-RUNTIME
2021SP1-64-IDE
2021SP1-64-RUNTIME
2022Q3-32-IDE
2022Q3-32-RUNTIME
2022Q3-64-IDE
2022Q3-64-RUNTIME
2023Q1-64-IDE
2023Q1-64-RUNTIME
2024Q1-64-IDE
2024Q1-64-RUNTIME

.EXAMPLE
.\minting-labview -DisableInteractive -LabVIEWVersion 2021SP1-64-IDE -InstallerBasePath G:\labview\2021SP1

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
  [switch]$UninstallAll = $false,
  [switch]$DryRun = $false,
  [string]$InstallerBasePath = ".",
  [string]$LabVIEWVersion = ""
)

$global:DisableInteractive = $DisableInteractive

$minting_labview_version = "4.5.5"
$script_name = $MyInvocation.MyCommand.Name
$utils_psm1_avail = $false

if (Test-Path $PSScriptRoot/utils.psm1) {
  Import-Module -Name $PSScriptRoot/utils.psm1 -Force
  $utils_psm1_avail = $true
  $IsInGitSubmodule = $false
}
elseif (Test-Path $PSScriptRoot/cmake/utils.psm1) {
  Import-Module -Name $PSScriptRoot/cmake/utils.psm1 -Force
  $utils_psm1_avail = $true
  $IsInGitSubmodule = $false
}
elseif (Test-Path $PSScriptRoot/ci/utils.psm1) {
  Import-Module -Name $PSScriptRoot/ci/utils.psm1 -Force
  $utils_psm1_avail = $true
  $IsInGitSubmodule = $false
}
elseif (Test-Path $PSScriptRoot/ccm/utils.psm1) {
  Import-Module -Name $PSScriptRoot/ccm/utils.psm1 -Force
  $utils_psm1_avail = $true
  $IsInGitSubmodule = $false
}
elseif (Test-Path $PSScriptRoot/scripts/utils.psm1) {
  Import-Module -Name $PSScriptRoot/scripts/utils.psm1 -Force
  $utils_psm1_avail = $true
  $IsInGitSubmodule = $false
}
else {
  $utils_psm1_version = "unavail"
  $IsWindowsPowerShell = $false
  $IsInGitSubmodule = $false
}

$ErrorActionPreference = "SilentlyContinue"
Stop-Transcript | out-null
$ErrorActionPreference = "Continue"
if($IsInGitSubmodule) {
  $PSCustomScriptRoot = Split-Path $PSScriptRoot -Parent
}
else {
  $PSCustomScriptRoot = $PSScriptRoot
}
$LogPath = "$PSCustomScriptRoot/minting-labview.log"
Start-Transcript -Path $LogPath

Write-Host "Minting script version ${minting_labview_version}, utils module version ${utils_psm1_version}"
if (-Not $utils_psm1_avail) {
  Write-Host "utils.psm1 is not available" -ForegroundColor Yellow
}
Write-Host "Working directory: $PSCustomScriptRoot, log file: $LogPath, $script_name is in submodule: $IsInGitSubmodule"

Write-Host -NoNewLine "PowerShell version:"
$PSVersionTable.PSVersion

if ($IsWindowsPowerShell) {
  Write-Host "Running on Windows Powershell, please consider update and running on newer Powershell versions"
}

if ($PSVersionTable.PSVersion.Major -lt 5) {
  MyThrow("Your PowerShell version is too old, please update it.")
}

$INIPrefix = switch ( $IsInGitSubmodule ) {
  $true { "$PSScriptRoot/.." }
  $false { "$PSScriptRoot" }
}

class LabVIEWInstaller {
  [string]$FileName
  [bool]$Legacy
  [bool]$Requires7Zip
  [bool]$AvailableOnInternet
  [string]$DownloadLink;
}

if (($LabVIEWVersion -eq "NIPKG") -or $UninstallAll) {
  $BaseVersion = 2025
  $64bitVersion = $true
  $OpenPortsOnFirewall = $false
  $DisableSourceOnlyVIs = $true
  $installers = @(
    [LabVIEWInstaller]@{
      FileName            = "NIPackageManager25.3.0.exe";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-package-manager/installers/NIPackageManager25.3.0_online.exe"
    }
  )
}
elseif ($LabVIEWVersion -eq "2018SP1-64-IDE") {
  $BaseVersion = 2018
  $64bitVersion = $true
  $OpenPortsOnFirewall = $true

  $installers = @(
    [LabVIEWInstaller]@{
      FileName            = "2018SP1LV64-WinEng.zip";
      Legacy              = $true;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/softlib/labview/labview_development_system/2018%20SP1/f0/2018SP1LV64-WinEng.zip"
    }
    [LabVIEWInstaller]@{
      FileName            = "2018FPGA64-Eng.zip";
      Legacy              = $true;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/softlib/labview/labview_fpga/fpga_module/2018/2018FPGA64-Eng.zip"
    }
    [LabVIEWInstaller]@{
      FileName            = "2018XILINX2017_2.zip";
      Legacy              = $true;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/softlib/labview/labview_fpga/fpga_module/2018/Windows%20Tools/2018XILINX2017_2.zip"
    }
    [LabVIEWInstaller]@{
      FileName            = "NIUSRP1800.exe";
      Legacy              = $true;
      Requires7Zip        = $true;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/softlib/RF/NI-USRP/18.0/NIUSRP1800.exe"
    }
  )

  $LabVIEW_INI_Setup_FileName = "$INIPrefix/2018SP1LV64-WinEng.ini"
  $LabVIEW_INI_Setup_Content = @"
; --------------------------  How to use this file  ---------------------------------
;
; To run this installer in quiet mode:
; 1. Edit the information below to match your company information and install location.
; 2. Run : setup.exe <path to this file> /q /AcceptLicenses yes. Passing the value "yes"
; to the /AcceptLicenses parameter indicates that you agree with the license agreements.
; Alternatively, instead of /q, /qb can be used to run the installer in basic UI mode.
; 3. The installer will automatically restart your system after the installation is done.
; To prevent the restart use the command line : setup.exe <path to this file> /r:n /q /AcceptLicenses yes
;
; Please contact National Instruments support at www.ni.com/support for further assistance.



; --------------------------  Set user information  ---------------------------------

; If the SerialNo key exists but its value is empty, and the installer support an evaluation mode, then an evaluation mode will be selected by default.

[UserInfo]
Name=Student
Company=UniBO


; --------------------------  Set feature states  ---------------------------------

; The valid feature states are: Local, Absent, NoChange, Default

; Local  - Install it (on the local hard drive). If already installed leave it installed.
; Absent - Do not install it. If already installed uninstall it.
; NoChange - Do not install it. If already installed, leave it installed.

; Default is equivalent to not listing the feature in this file. The feature follows its default behavior.

[Features]
NILV.LV64.2018.001=Local
lvcli.LVCLI=Local
LVREPGEN.LV.REPGEN.201864=
Pkg2018.SYSMGMTPKGBLDLV201864=
NI_VIPM_Core.MIFVIPMCORE=
Extras=
LVFFRTE.LV64.FFRTE2018=
ExcelAddin.USI.EXCEL.CORE1801=
MAXROOT.MAX00=
DCD=


; --------------------------  Set install directories  ---------------------------------

; *** To use the default paths, remove the following section***

[Directories]
<RootDirectory1>=
<RootDirectory2>=
NILV.LV64.2018.001=
; <RootDirectory>=


; --------------------------  Set general installation settings  ---------------------------------
[Settings]
; WelcomeAutoAdvance=1


; --------------------------  Set the dialogs that should be hidden from the user  ---------------------------------
[DisableDialogs]
; UserInfo
; FeatureInfo1
; SingleDirectory
; InstallationType
; FeatureTree
; License
; License2
; NICertificate
; WinFastStartup
; ConfirmStart
; End

[SerialNumberDialog]
SerialNumber1=
SerialNumber2=
SerialNumber3=
[SerialNumber1]
SerialNo=
[SerialNumber2]
SerialNo=
[SerialNumber3]
SerialNo=
[PhoneHome]
DefaultState=0
Visible=0
"@
  Out-File -FilePath $LabVIEW_INI_Setup_FileName -InputObject $LabVIEW_INI_Setup_Content -Encoding unicode

  $RTModule_INI_Setup_FileName = "$INIPrefix/2018SP1RealTime-Eng.ini"
  $RTModule_INI_Setup_Content = @"
; --------------------------  How to use this file  ---------------------------------
;
; To run this installer in quiet mode:
; 1. Edit the information below to match your company information and install location.
; 2. Run : setup.exe <path to this file> /q /AcceptLicenses yes. Passing the value "yes"
;    to the /AcceptLicenses parameter indicates that you agree with the license agreements.
;    Alternatively, instead of /q, /qb can be used to run the installer in basic UI mode.
; 3. The installer will automatically restart your system after the installation is done.
;    To prevent the restart use the command line : setup.exe <path to this file> /r:n /q /AcceptLicenses yes
;
; Please contact National Instruments support at www.ni.com/support for further assistance.



; --------------------------  Set user information  ---------------------------------

;    If the SerialNo key exists but its value is empty, and the installer support an evaluation mode, then an evaluation mode will be selected by default.

[UserInfo]
Name=Student
Company=UniBO
DefaultIsEval=1


; --------------------------  Set feature states  ---------------------------------

;    The valid feature states are: Local, Absent, NoChange, Default

;    Local  - Install it (on the local hard drive). If already installed leave it installed.
;    Absent - Do not install it. If already installed uninstall it.
;    NoChange - Do not install it. If already installed, leave it installed.

;    Default is equivalent to not listing the feature in this file. The feature follows its default behavior.

[Features]
LV_RT_Core.LVRT.CORE.2018=Local
MAXROOT.MAX00=Local
RT_ETT_LV.RT_ETT.LV=
DCD=


; --------------------------  Set install directories  ---------------------------------

; *** To use the default paths, remove the following section***

[Directories]
;<RootDirectory>=


; --------------------------  Set general installation settings  ---------------------------------
[Settings]
EndDialogCheckboxDefaultState=0
;WelcomeAutoAdvance=1


; --------------------------  Set the dialogs that should be hidden from the user  ---------------------------------
[DisableDialogs]
;UserInfo
;FeatureInfo1
;SingleDirectory
;InstallationType
;FeatureTree
;License
;License2
;NICertificate
;WinFastStartup
;ConfirmStart
;End

[PhoneHome]
DefaultState=0
Visible=0
"@
  Out-File -FilePath $RTModule_INI_Setup_FileName -InputObject $RTModule_INI_Setup_Content -Encoding unicode

  $FPGAModule_INI_Setup_FileName = "$INIPrefix/2018FPGA64-Eng.ini"
  $FPGAModule_INI_Setup_Content = @"
; --------------------------  How to use this file  ---------------------------------
;
; To run this installer in quiet mode:
; 1. Edit the information below to match your company information and install location.
; 2. Run : setup.exe <path to this file> /q /AcceptLicenses yes. Passing the value "yes"
;    to the /AcceptLicenses parameter indicates that you agree with the license agreements.
;    Alternatively, instead of /q, /qb can be used to run the installer in basic UI mode.
; 3. The installer will automatically restart your system after the installation is done.
;    To prevent the restart use the command line : setup.exe <path to this file> /r:n /q /AcceptLicenses yes
;
; Please contact National Instruments support at www.ni.com/support for further assistance.



; --------------------------  Set user information  ---------------------------------

;    If the SerialNo key exists but its value is empty, and the installer support an evaluation mode, then an evaluation mode will be selected by default.

[UserInfo]
Name=Student
Company=UniBO
DefaultIsEval=1


; --------------------------  Set feature states  ---------------------------------

;    The valid feature states are: Local, Absent, NoChange, Default

;    Local  - Install it (on the local hard drive). If already installed leave it installed.
;    Absent - Do not install it. If already installed uninstall it.
;    NoChange - Do not install it. If already installed, leave it installed.

;    Default is equivalent to not listing the feature in this file. The feature follows its default behavior.

[Features]
FPGA_Core64.FPGA64.2018=Local
NIDCD=


; --------------------------  Set install directories  ---------------------------------

; *** To use the default paths, remove the following section***

[Directories]
;<RootDirectory>=


; --------------------------  Set general installation settings  ---------------------------------
[Settings]
EndDialogCheckboxDefaultState=0
;WelcomeAutoAdvance=1


; --------------------------  Set the dialogs that should be hidden from the user  ---------------------------------
[DisableDialogs]
;UserInfo
;FeatureInfo1
;SingleDirectory
;InstallationType
;FeatureTree
;License
;License2
;NICertificate
;WinFastStartup
;ConfirmStart
;End

[PhoneHome]
DefaultState=0
Visible=0
"@
  Out-File -FilePath $FPGAModule_INI_Setup_FileName -InputObject $FPGAModule_INI_Setup_Content -Encoding unicode

  $USRPModule_INI_Setup_FileName = "$INIPrefix/NIUSRP1800.ini"
  $USRPModule_INI_Setup_Content = @"
; --------------------------  How to use this file  ---------------------------------
;
; To run this installer in quiet mode:
; 1. Edit the information below to match your company information and install location.
; 2. Run : setup.exe <path to this file> /q /AcceptLicenses yes. Passing the value "yes"
;    to the /AcceptLicenses parameter indicates that you agree with the license agreements.
;    Alternatively, instead of /q, /qb can be used to run the installer in basic UI mode.
; 3. The installer will automatically restart your system after the installation is done.
;    To prevent the restart use the command line : setup.exe <path to this file> /r:n /q /AcceptLicenses yes
;
; Please contact National Instruments support at www.ni.com/support for further assistance.



; --------------------------  Set user information  ---------------------------------

;    If the SerialNo key exists but its value is empty, and the installer support an evaluation mode, then an evaluation mode will be selected by default.

[UserInfo]
Name=Student
Company=UniBO


; --------------------------  Set feature states  ---------------------------------

;    The valid feature states are: Local, Absent, NoChange, Default

;    Local  - Install it (on the local hard drive). If already installed leave it installed.
;    Absent - Do not install it. If already installed uninstall it.
;    NoChange - Do not install it. If already installed, leave it installed.

;    Default is equivalent to not listing the feature in this file. The feature follows its default behavior.

[Features]
_NIUSRP_TopLevel_Fake=Local
_NIUSRP_DeviceSupport_Fake=Local
parent.NIUSRP32I.MAIN=Local
UsrpRioDriver.USRPRIO.DRV32=Local
_NIUSRP_DevelopmentSupport_Fake=Local
LV.NIUSRPLV1864=Local
LV.NIUSRPRIOLV1864=Local
USRPDriver_RT.USRPRIO.RT641800=Local
parent.USRP64I.COMMS64=
LV.NIUSRPLV1832=
LV.NIUSRPLV1732=
LV.NIUSRPLV1764=
LV.NIUSRPLV1632=
LV.NIUSRPLV1664=
LV.NIUSRPLV1532=
LV.NIUSRPLV1564=
LV.NIUSRPRIOLV1832=
LV.NIUSRPRIOLV1732=
LV.NIUSRPRIOLV1764=
LV.NIUSRPRIOLV1632=
LV.NIUSRPRIOLV1664=
LV.NIUSRPRIOLV1532=
LV.NIUSRPRIOLV1564=
MAXROOT.MAX00=


; --------------------------  Set install directories  ---------------------------------

; *** To use the default paths, remove the following section***

[Directories]
;<RootDirectory>=


; --------------------------  Set general installation settings  ---------------------------------
[Settings]
;WelcomeAutoAdvance=1


; --------------------------  Set the dialogs that should be hidden from the user  ---------------------------------
[DisableDialogs]
;UserInfo
;FeatureInfo1
;SingleDirectory
;InstallationType
;FeatureTree
;License
;License2
;NICertificate
;WinFastStartup
;ConfirmStart
;End

[PhoneHome]
DefaultState=0
Visible=0
"@
  Out-File -FilePath $USRPModule_INI_Setup_FileName -InputObject $USRPModule_INI_Setup_Content -Encoding unicode

  $Xilinx_INI_Setup_FileName = "$INIPrefix/2018XILINX2017_2.ini"
  $Xilinx_INI_Setup_Content = @"
; --------------------------  How to use this file  ---------------------------------
;
; To run this installer in quiet mode:
; 1. Edit the information below to match your company information and install location.
; 2. Run : setup.exe <path to this file> /q /AcceptLicenses yes. Passing the value "yes"
;    to the /AcceptLicenses parameter indicates that you agree with the license agreements.
;    Alternatively, instead of /q, /qb can be used to run the installer in basic UI mode.
; 3. The installer will automatically restart your system after the installation is done.
;    To prevent the restart use the command line : setup.exe <path to this file> /r:n /q /AcceptLicenses yes
;
; Please contact National Instruments support at www.ni.com/support for further assistance.



; --------------------------  Set user information  ---------------------------------

;    If the SerialNo key exists but its value is empty, and the installer support an evaluation mode, then an evaluation mode will be selected by default.

[UserInfo]
Name=Student
Company=UniBO
DefaultIsEval=1


; --------------------------  Set feature states  ---------------------------------

;    The valid feature states are: Local, Absent, NoChange, Default

;    Local  - Install it (on the local hard drive). If already installed leave it installed.
;    Absent - Do not install it. If already installed uninstall it.
;    NoChange - Do not install it. If already installed, leave it installed.

;    Default is equivalent to not listing the feature in this file. The feature follows its default behavior.

[Features]


; --------------------------  Set install directories  ---------------------------------

; *** To use the default paths, remove the following section***

[Directories]
;<RootDirectory>=


; --------------------------  Set general installation settings  ---------------------------------
[Settings]
;WelcomeAutoAdvance=1


; --------------------------  Set the dialogs that should be hidden from the user  ---------------------------------
[DisableDialogs]
;UserInfo
;FeatureInfo1
;SingleDirectory
;InstallationType
;FeatureTree
;License
;License2
;NICertificate
;WinFastStartup
;ConfirmStart
;End

[PhoneHome]
DefaultState=0
Visible=0
"@
  Out-File -FilePath $Xilinx_INI_Setup_FileName -InputObject $Xilinx_INI_Setup_Content -Encoding unicode
}
elseif ($LabVIEWVersion -eq "2018SP1-64-RUNTIME") {
  $BaseVersion = 2018
  $64bitVersion = $true
  $OpenPortsOnFirewall = $false
  $DisableSourceOnlyVIs = $true
  $installers = @(
    [LabVIEWInstaller]@{
      FileName            = "LVRTE2018SP1_f4-64std.zip";
      Legacy              = $true;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/softlib/labview/labview_runtime/2018%20SP1/Windows/f4/LVRTE2018SP1_f4Patch-64std.zip"
    }
    [LabVIEWInstaller]@{
      FileName            = "NIUSRP1800.exe";
      Legacy              = $true;
      Requires7Zip        = $true;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/softlib/RF/NI-USRP/18.0/NIUSRP1800.exe"
    }
  )

  $LabVIEW_INI_Setup_FileName = "$INIPrefix/LVRTE2018SP1_f4-64std.ini"
  $LabVIEW_INI_Setup_Content = @"
; --------------------------  How to use this file  ---------------------------------
;
; To run this installer in quiet mode:
; 1. Edit the information below to match your company information and install location.
; 2. Run : setup.exe <path to this file> /q /AcceptLicenses yes. Passing the value "yes"
;    to the /AcceptLicenses parameter indicates that you agree with the license agreements.
;    Alternatively, instead of /q, /qb can be used to run the installer in basic UI mode.
; 3. The installer will automatically restart your system after the installation is done.
;    To prevent the restart use the command line : setup.exe <path to this file> /r:n /q /AcceptLicenses yes
;
; Please contact National Instruments support at www.ni.com/support for further assistance.



; --------------------------  Set user information  ---------------------------------

;    If the SerialNo key exists but its value is empty, and the installer support an evaluation mode, then an evaluation mode will be selected by default.

[UserInfo]
Name=
Company=


; --------------------------  Set feature states  ---------------------------------

;    The valid feature states are: Local, Absent, NoChange, Default

;    Local  - Install it (on the local hard drive). If already installed leave it installed.
;    Absent - Do not install it. If already installed uninstall it.
;    NoChange - Do not install it. If already installed, leave it installed.

;    Default is equivalent to not listing the feature in this file. The feature follows its default behavior.

[Features]
LVRTE.LV.64RTE2018=
Variable_Engine.LV.VE.2018=
Core.DSC.DS.1800=
USI.USI32.1750=
sys_websrvr.NI.SYS.WEBSRV.2018=


; --------------------------  Set install directories  ---------------------------------

; *** To use the default paths, remove the following section***

[Directories]
<RootDirectory1>=
;<RootDirectory>=


; --------------------------  Set general installation settings  ---------------------------------
[Settings]
;WelcomeAutoAdvance=1


; --------------------------  Set the dialogs that should be hidden from the user  ---------------------------------
[DisableDialogs]
;UserInfo
;FeatureInfo1
;SingleDirectory
;InstallationType
;FeatureTree
;License
;License2
;NICertificate
;WinFastStartup
;ConfirmStart
;End

[PhoneHome]
DefaultState=0
Visible=0
"@
  Out-File -FilePath $LabVIEW_INI_Setup_FileName -InputObject $LabVIEW_INI_Setup_Content -Encoding unicode

  $USRPModule_INI_Setup_FileName = "$INIPrefix/NIUSRP1800.ini"
  $USRPModule_INI_Setup_Content = @"
; --------------------------  How to use this file  ---------------------------------
;
; To run this installer in quiet mode:
; 1. Edit the information below to match your company information and install location.
; 2. Run : setup.exe <path to this file> /q /AcceptLicenses yes. Passing the value "yes"
;    to the /AcceptLicenses parameter indicates that you agree with the license agreements.
;    Alternatively, instead of /q, /qb can be used to run the installer in basic UI mode.
; 3. The installer will automatically restart your system after the installation is done.
;    To prevent the restart use the command line : setup.exe <path to this file> /r:n /q /AcceptLicenses yes
;
; Please contact National Instruments support at www.ni.com/support for further assistance.



; --------------------------  Set user information  ---------------------------------

;    If the SerialNo key exists but its value is empty, and the installer support an evaluation mode, then an evaluation mode will be selected by default.

[UserInfo]
Name=Student
Company=UniBO


; --------------------------  Set feature states  ---------------------------------

;    The valid feature states are: Local, Absent, NoChange, Default

;    Local  - Install it (on the local hard drive). If already installed leave it installed.
;    Absent - Do not install it. If already installed uninstall it.
;    NoChange - Do not install it. If already installed, leave it installed.

;    Default is equivalent to not listing the feature in this file. The feature follows its default behavior.

[Features]
_NIUSRP_TopLevel_Fake=Local
_NIUSRP_DeviceSupport_Fake=Local
parent.NIUSRP32I.MAIN=Local
UsrpRioDriver.USRPRIO.DRV32=Local
_NIUSRP_DevelopmentSupport_Fake=Local
LV.NIUSRPLV1864=Local
LV.NIUSRPRIOLV1864=Local
USRPDriver_RT.USRPRIO.RT641800=Local
parent.USRP64I.COMMS64=
LV.NIUSRPLV1832=
LV.NIUSRPLV1732=
LV.NIUSRPLV1764=
LV.NIUSRPLV1632=
LV.NIUSRPLV1664=
LV.NIUSRPLV1532=
LV.NIUSRPLV1564=
LV.NIUSRPRIOLV1832=
LV.NIUSRPRIOLV1732=
LV.NIUSRPRIOLV1764=
LV.NIUSRPRIOLV1632=
LV.NIUSRPRIOLV1664=
LV.NIUSRPRIOLV1532=
LV.NIUSRPRIOLV1564=
MAXROOT.MAX00=


; --------------------------  Set install directories  ---------------------------------

; *** To use the default paths, remove the following section***

[Directories]
;<RootDirectory>=


; --------------------------  Set general installation settings  ---------------------------------
[Settings]
;WelcomeAutoAdvance=1


; --------------------------  Set the dialogs that should be hidden from the user  ---------------------------------
[DisableDialogs]
;UserInfo
;FeatureInfo1
;SingleDirectory
;InstallationType
;FeatureTree
;License
;License2
;NICertificate
;WinFastStartup
;ConfirmStart
;End

[PhoneHome]
DefaultState=0
Visible=0
"@
  Out-File -FilePath $USRPModule_INI_Setup_FileName -InputObject $USRPModule_INI_Setup_Content -Encoding unicode
}
elseif ($LabVIEWVersion -eq "2020SP1-64-IDE") {
  $BaseVersion = 2020
  $64bitVersion = $true
  $OpenPortsOnFirewall = $true
  $installers = @(
    [LabVIEWInstaller]@{
      FileName            = "ni-labview-2020_20.6.0.49153-0+f1_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2020/20.6/offline/ni-labview-2020_20.6.0.49153-0+f1_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-labview-2020-fpga-module_20.0.1_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2020-fpga-module/20.0/offline/ni-labview-2020-fpga-module_20.0.1_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-usrp_21.0.2_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-u/ni-usrp/21.0/offline/ni-usrp_21.0.2_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-vivado-2019.1-cg_20.0.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-v/ni-vivado-2019.1-cg/20.0/offline/ni-vivado-2019.1-cg_20.0.0_offline.iso"
    }
  )
}
elseif ($LabVIEWVersion -eq "2020SP1-64-RUNTIME") {
  $BaseVersion = 2020
  $64bitVersion = $true
  $OpenPortsOnFirewall = $false
  $DisableSourceOnlyVIs = $true
  $installers = @(
    [LabVIEWInstaller]@{
      FileName            = "ni-labview-2020-runtime-engine_20.1.1_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2020-runtime-engine/20.1/offline/ni-labview-2020-runtime-engine_20.1.1_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-usrp_21.0.2_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-u/ni-usrp/21.0/offline/ni-usrp_21.0.2_offline.iso"
    }
  )
}
elseif ($LabVIEWVersion -eq "2021-64-IDE") {
  $BaseVersion = 2021
  $64bitVersion = $true
  $OpenPortsOnFirewall = $true
  $installers = @(
    [LabVIEWInstaller]@{
      FileName            = "ni-embedded-control-and-monitoring-suite_21.0.0.49152-0+f0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-e/ni-embedded-control-and-monitoring-suite/21.0/offline/ni-embedded-control-and-monitoring-suite_21.0.0.49152-0+f0_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-labview-2021-fpga-module_21.0.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2021-fpga-module/21.0/offline/ni-labview-2021-fpga-module_21.0.0_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-usrp_21.0.2_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-u/ni-usrp/21.0/offline/ni-usrp_21.0.2_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-vivado-2019.1-cg_20.0.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-v/ni-vivado-2019.1-cg/20.0/offline/ni-vivado-2019.1-cg_20.0.0_offline.iso"
    }
  )
}
elseif ($LabVIEWVersion -eq "2021-64-RUNTIME") {
  $BaseVersion = 2021
  $64bitVersion = $true
  $OpenPortsOnFirewall = $false
  $DisableSourceOnlyVIs = $true
  $installers = @(
    [LabVIEWInstaller]@{
      FileName            = "ni-labview-2021-runtime-engine_21.0.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2021-runtime-engine/21.0/offline/ni-labview-2021-runtime-engine_21.0.0_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-usrp_21.0.2_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-u/ni-usrp/21.0/offline/ni-usrp_21.0.2_offline.iso"
    }
  )
}
elseif ($LabVIEWVersion -eq "2021SP1-32-IDE") {
  $BaseVersion = 2021
  $64bitVersion = $false
  $OpenPortsOnFirewall = $true
  $installers = @(
    [LabVIEWInstaller]@{
      FileName            = "ni-embedded-control-and-monitoring-suite-x86_21.5.0.49279-0+f127_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-e/ni-embedded-control-and-monitoring-suite-x86/21.5/offline/ni-embedded-control-and-monitoring-suite-x86_21.5.0.49279-0+f127_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-labview-2021-rt-module-x86_21.0.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2021-rt-module-x86/21.0/offline/ni-labview-2021-rt-module-x86_21.0.0_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-labview-2021-fpga-module-x86_21.0.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2021-fpga-module-x86/21.0/offline/ni-labview-2021-fpga-module-x86_21.0.0_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-compactrio-device-drivers_22.5.0.49214-0+f62_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-c/ni-compactrio-device-drivers/22.5/offline/ni-compactrio-device-drivers_22.5.0.49214-0+f62_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-usrp_21.0.2_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-u/ni-usrp/21.0/offline/ni-usrp_21.0.2_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-vivado-2019.1-cg_20.0.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-v/ni-vivado-2019.1-cg/20.0/offline/ni-vivado-2019.1-cg_20.0.0_offline.iso"
    }
  )
}
elseif ($LabVIEWVersion -eq "2021SP1-32-RUNTIME") {
  $BaseVersion = 2021
  $64bitVersion = $false
  $OpenPortsOnFirewall = $false
  $DisableSourceOnlyVIs = $true
  $installers = @(
    [LabVIEWInstaller]@{
      FileName            = "ni-labview-2021-runtime-engine-x86_21.1.2_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2021-runtime-engine-x86/21.1/offline/ni-labview-2021-runtime-engine-x86_21.1.2_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-compactrio-device-drivers_22.5.0.49214-0+f62_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-c/ni-compactrio-device-drivers/22.5/offline/ni-compactrio-device-drivers_22.5.0.49214-0+f62_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-usrp_21.0.2_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-u/ni-usrp/21.0/offline/ni-usrp_21.0.2_offline.iso"
    }
  )
}
elseif ($LabVIEWVersion -eq "2021SP1-64-IDE") {
  $BaseVersion = 2021
  $64bitVersion = $true
  $OpenPortsOnFirewall = $true
  $installers = @(
    [LabVIEWInstaller]@{
      FileName            = "ni-embedded-control-and-monitoring-suite_21.5.0.49279-0+f127_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-e/ni-embedded-control-and-monitoring-suite/21.5/offline/ni-embedded-control-and-monitoring-suite_21.5.0.49279-0+f127_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-labview-2021-rt-module_21.0.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2021-rt-module/21.0/offline/ni-labview-2021-rt-module_21.0.0_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-labview-2021-fpga-module_21.0.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2021-fpga-module/21.0/offline/ni-labview-2021-fpga-module_21.0.0_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-compactrio-device-drivers_22.5.0.49214-0+f62_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-c/ni-compactrio-device-drivers/22.5/offline/ni-compactrio-device-drivers_22.5.0.49214-0+f62_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-usrp_21.0.2_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-u/ni-usrp/21.0/offline/ni-usrp_21.0.2_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-vivado-2019.1-cg_20.0.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-v/ni-vivado-2019.1-cg/20.0/offline/ni-vivado-2019.1-cg_20.0.0_offline.iso"
    }
  )
}
elseif ($LabVIEWVersion -eq "2021SP1-64-RUNTIME") {
  $BaseVersion = 2021
  $64bitVersion = $true
  $OpenPortsOnFirewall = $false
  $DisableSourceOnlyVIs = $true
  $installers = @(
    [LabVIEWInstaller]@{
      FileName            = "ni-labview-2021-runtime-engine_21.1.2_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2021-runtime-engine/21.1/offline/ni-labview-2021-runtime-engine_21.1.2_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-usrp_21.0.2_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-u/ni-usrp/21.0/offline/ni-usrp_21.0.2_offline.iso"
    }
  )
}
elseif ($LabVIEWVersion -eq "2022Q3-32-IDE") {
  $BaseVersion = 2022
  $64bitVersion = $false
  $OpenPortsOnFirewall = $true
  $installers = @(
    [LabVIEWInstaller]@{
      FileName            = "ni-embedded-control-and-monitoring-suite-x86_22.5.0.49197-0+f45_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-e/ni-embedded-control-and-monitoring-suite-x86/22.5/offline/ni-embedded-control-and-monitoring-suite-x86_22.5.0.49197-0+f45_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-labview-2022-rt-module-x86_22.3.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2022-rt-module-x86/22.3/offline/ni-labview-2022-rt-module-x86_22.3.0_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-labview-2022-fpga-module-x86_22.3.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2022-fpga-module-x86/22.3/offline/ni-labview-2022-fpga-module-x86_22.3.0_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-compactrio-device-drivers_22.5.0.49214-0+f62_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-c/ni-compactrio-device-drivers/22.5/offline/ni-compactrio-device-drivers_22.5.0.49214-0+f62_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-vivado-2019.1-cg_20.0.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-v/ni-vivado-2019.1-cg/20.0/offline/ni-vivado-2019.1-cg_20.0.0_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-vivado-2021.1-cg_22.3.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-v/ni-vivado-2021.1-cg/22.3/offline/ni-vivado-2021.1-cg_22.3.0_offline.iso"
    }
  )
}
elseif ($LabVIEWVersion -eq "2022Q3-32-RUNTIME") {
  $BaseVersion = 2022
  $64bitVersion = $false
  $OpenPortsOnFirewall = $false
  $DisableSourceOnlyVIs = $true
  $installers = @(
    [LabVIEWInstaller]@{
      FileName            = "ni-labview-2022-runtime-engine-x86_22.3.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2022-runtime-engine-x86/22.3/offline/ni-labview-2022-runtime-engine-x86_22.3.0_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-compactrio-device-drivers_22.5.0.49214-0+f62_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-c/ni-compactrio-device-drivers/22.5/offline/ni-compactrio-device-drivers_22.5.0.49214-0+f62_offline.iso"
    }
  )
}
elseif ($LabVIEWVersion -eq "2022Q3-64-IDE") {
  $BaseVersion = 2022
  $64bitVersion = $true
  $OpenPortsOnFirewall = $true
  $installers = @(
    [LabVIEWInstaller]@{
      FileName            = "ni-embedded-control-and-monitoring-suite_22.5.0.49197-0+f45_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-e/ni-embedded-control-and-monitoring-suite/22.5/offline/ni-embedded-control-and-monitoring-suite_22.5.0.49197-0+f45_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-labview-2022-rt-module_22.3.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2022-rt-module/22.3/offline/ni-labview-2022-rt-module_22.3.0_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-labview-2022-fpga-module_22.3.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2022-fpga-module/22.3/offline/ni-labview-2022-fpga-module_22.3.0_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-compactrio-device-drivers_22.5.0.49214-0+f62_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-c/ni-compactrio-device-drivers/22.5/offline/ni-compactrio-device-drivers_22.5.0.49214-0+f62_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-usrp_22.8.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-u/ni-usrp/22.8/offline/ni-usrp_22.8.0_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-vivado-2021.1-cg_22.3.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-v/ni-vivado-2021.1-cg/22.3/offline/ni-vivado-2021.1-cg_22.3.0_offline.iso"
    }
  )
}
elseif ($LabVIEWVersion -eq "2022Q3-64-RUNTIME") {
  $BaseVersion = 2022
  $64bitVersion = $true
  $OpenPortsOnFirewall = $false
  $DisableSourceOnlyVIs = $true
  $installers = @(
    [LabVIEWInstaller]@{
      FileName            = "ni-labview-2022-runtime-engine_22.3.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2022-runtime-engine/22.3/offline/ni-labview-2022-runtime-engine_22.3.0_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-compactrio-device-drivers_22.5.0.49214-0+f62_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-c/ni-compactrio-device-drivers/22.5/offline/ni-compactrio-device-drivers_22.5.0.49214-0+f62_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-usrp_22.8.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-u/ni-usrp/22.8/offline/ni-usrp_22.8.0_offline.iso"
    }
  )
}
elseif ($LabVIEWVersion -eq "2023Q1-64-IDE") {
  $BaseVersion = 2023
  $64bitVersion = $true
  $OpenPortsOnFirewall = $true
  $installers = @(
    [LabVIEWInstaller]@{
      FileName            = "ni-embedded-control-and-monitoring-suite_23.0.0.49266-0+f114_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-e/ni-embedded-control-and-monitoring-suite/23.0/offline/ni-embedded-control-and-monitoring-suite_23.0.0.49266-0+f114_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-usrp_23.5.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-u/ni-usrp/23.5/offline/ni-usrp_23.5.0_offline.iso"
    }
  )
}
elseif ($LabVIEWVersion -eq "2023Q1-64-RUNTIME") {
  $BaseVersion = 2023
  $64bitVersion = $true
  $OpenPortsOnFirewall = $false
  $DisableSourceOnlyVIs = $true
  $installers = @(
    [LabVIEWInstaller]@{
      FileName            = "ni-labview-2023-runtime-engine_23.1.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2023-runtime-engine/23.1/offline/ni-labview-2023-runtime-engine_23.1.0_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-usrp_23.5.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-u/ni-usrp/23.5/offline/ni-usrp_23.5.0_offline.iso"
    }
  )
}
elseif ($LabVIEWVersion -eq "2024Q1-64-IDE") {
  $BaseVersion = 2024
  $64bitVersion = $true
  $OpenPortsOnFirewall = $true
  $installers = @(
    [LabVIEWInstaller]@{
      FileName            = "ni-embedded-control-and-monitoring-suite_24.0.0.49237-0+f85_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-e/ni-embedded-control-and-monitoring-suite/24.0/offline/ni-embedded-control-and-monitoring-suite_24.0.0.49237-0+f85_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-labview-2024-rt-module_24.1.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2024-rt-module/24.1/offline/ni-labview-2024-rt-module_24.1.0_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-labview-2024-fpga-module_24.1.1_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2024-fpga-module/24.1/offline/ni-labview-2024-fpga-module_24.1.1_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-compactrio-device-drivers_24.3.0.49257-0+f105_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-c/ni-compactrio-device-drivers/24.3/offline/ni-compactrio-device-drivers_24.3.0.49257-0+f105_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-usrp_23.5.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-u/ni-usrp/23.5/offline/ni-usrp_23.5.0_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-vivado-2021.1-cg_24.1.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-v/ni-vivado-2021.1-cg/24.1/offline/ni-vivado-2021.1-cg_24.1.0_offline.iso"
    }
  )
}
elseif ($LabVIEWVersion -eq "2024Q1-64-RUNTIME") {
  $BaseVersion = 2024
  $64bitVersion = $true
  $OpenPortsOnFirewall = $false
  $DisableSourceOnlyVIs = $true
  $installers = @(
    [LabVIEWInstaller]@{
      FileName            = "ni-labview-2024-runtime-engine_24.1.1_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2024-runtime-engine/24.1/offline/ni-labview-2024-runtime-engine_24.1.1_offline.iso"
    }
    [LabVIEWInstaller]@{
      FileName            = "ni-usrp_23.5.0_offline.iso";
      Legacy              = $false;
      Requires7Zip        = $false;
      AvailableOnInternet = $true;
      DownloadLink        = "https://download.ni.com/support/nipkg/products/ni-u/ni-usrp/23.5/offline/ni-usrp_23.5.0_offline.iso"
    }
  )
}
else {
  MyThrow("Unrecognized LabVIEW version")
}

foreach ($installer in $installers) {
  if (Test-Path -Path $InstallerBasePath/$($installer.FileName)) {
    Write-Host "Installing from $InstallerBasePath/$($installer.FileName)"
  }
  elseif ($installer.AvailableOnInternet) {
    if (-Not (Test-Path -Path $InstallerBasePath)) {
      Write-Host "Creating folder $InstallerBasePath"
      New-Item -Path $InstallerBasePath -ItemType directory -Force | Out-Null
    }

    $ARIA2_EXE = Get-Command "aria2c" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
    if (-Not $ARIA2_EXE) {

      if ($IsWindows -or $IsWindowsPowerShell) {
        $basename = "aria2-1.37.0-win-32bit-build1"
      }
      elseif ($IsLinux) {
        $basename = "aria2-1.36.0-linux-gnu-64bit-build1"
      }
      elseif ($IsMacOS) {
        $basename = "aria2-1.35.0/bin"
      }
      $ARIA2_EXE = Get-Command "$basename/aria2c" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
      if (-Not $ARIA2_EXE) {
        Start-Sleep -Seconds 10
        $ARIA2_EXE = DownloadAria2
        if (-Not $ARIA2_EXE) {
          MyThrow("Unable to find Aria2 and to download a portable version on the fly.")
        }
      }
      Write-Host "Using aria2 from ${ARIA2_EXE}"
    }

    $downloadArgs = " -x 2 --file-allocation=none $($installer.DownloadLink) -d $($InstallerBasePath) -o $($installer.FileName) "
    Write-Host "Downloading $InstallerBasePath/$($installer.FileName)"
    $proc = Start-Process -NoNewWindow -PassThru -FilePath $ARIA2_EXE -ArgumentList $downloadArgs
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

  $InstallerExt = $installer.FileName.split(".")[-1]
  if ($installer.Legacy) {
    # Note: to generate the spec file, please run installer interactively with this command:
    # setup /generatespecfile lv.ini
    $filePath = Get-ChildItem $InstallerBasePath/$($installer.FileName)
    $fileBasename = ${filePath}.Basename
    if (-Not $DryRun) {
      Remove-Item -Force -Recurse -ErrorAction SilentlyContinue "$InstallerBasePath/$fileBasename"
      if ($($installer.Requires7Zip)) {
        $7zip = Download7Zip
        $7zipArgs = " x $filePath -o$InstallerBasePath -y"
        Write-Host "Deflating $filePath with 7-Zip"
        $proc = Start-Process -NoNewWindow -PassThru -FilePath $7zip -ArgumentList $7zipArgs -RedirectStandardOutput "NUL"
        $handle = $proc.Handle
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
        if ($exitCode -eq 0) {
          Write-Host "Deflation completed" -ForegroundColor Green
        }
        else {
          MyThrow("Deflation failed! Exited with error code $exitCode.")
        }
      }
      else {
        Write-Host "Deflating $filePath"
        Expand-Archive -Path $filePath -DestinationPath $InstallerBasePath
      }
      $setupPath = Get-ChildItem "$InstallerBasePath/$fileBasename/setup.exe"
    }
    else {
      $setupPath = "$InstallerBasePath/$fileBasename/setup.exe"
    }
    $iniFile = "$INIPrefix/${fileBasename}.ini"
    $setupArgs = " $iniFile /q /r:n /disableNotificationCheck /AcceptLicenses yes "
  }
  else {
    if ($InstallerExt -eq "iso") {
      $imagePath = Get-ChildItem $InstallerBasePath/$($installer.FileName)
      Mount-DiskImage -ImagePath $imagePath | Out-Null
      $DiskImage = Get-DiskImage -ImagePath $imagePath | Get-Volume
      $DriveLetter = $DiskImage.DriveLetter + ":"
      $setupPath = Get-ChildItem "$DriveLetter/Install.exe"
    }
    elseif ($InstallerExt -eq "exe") {
      $setupPath = Get-ChildItem "$InstallerBasePath/$($installer.FileName)"
    }
    if ($DisableInteractive) {
      $setupArgs = " --quiet --accept-eulas --prevent-reboot "
    }
    else {
      $setupArgs = " --accept-eulas --prevent-reboot "
    }
  }

  if ($DryRun) {
    Write-Host "InstallerExt: ${InstallerExt}" -ForegroundColor Blue
    Write-Host "DryRun: $setupPath $setupArgs" -ForegroundColor Yellow
  }
  else {
    $proc = Start-Process -NoNewWindow -PassThru -FilePath $setupPath -ArgumentList $setupArgs
    $handle = $proc.Handle
    $proc.WaitForExit()
    $exitCode = $proc.ExitCode
    if ($exitCode -eq 0) {
      Write-Host "Setup was fine, application is ready" -ForegroundColor Green
    }
    elseif ($exitCode -eq 3010) {
      Write-Host "Setup was fine, application requires reboot before usage (legacy installer)" -ForegroundColor Yellow
    }
    elseif ($exitCode -eq -125071) {
      Write-Host "Setup was fine, application requires reboot before usage (modern installer)" -ForegroundColor Yellow
    }
    else {
      MyThrow("Setup failed! Exited with error code $exitCode.")
    }
  }

  if ($installer.Legacy) {
    Remove-Item -Force -Recurse -ErrorAction SilentlyContinue "$InstallerBasePath/$fileBasename"
  }
  else {
    if ($InstallerExt -eq "iso") {
      $imagePath = Get-ChildItem $InstallerBasePath/$($installer.FileName)
      DisMount-DiskImage -ImagePath $imagePath | Out-Null
    }
  }

  Write-Host "Finished installing from $InstallerBasePath/$($installer.FileName)"

  if ($UninstallAll) {
    $setupPath = Get-ChildItem "C:/Program Files/National Instruments/NI Package Manager/nipkg.exe"
    $setupArgs = " remove --force-essential --force-locked --yes "
    if ($DryRun) {
      Write-Host "DryRun uninstall: $setupPath $setupArgs" -ForegroundColor Yellow
    }
    else {
      $proc = Start-Process -NoNewWindow -PassThru -FilePath $setupPath -ArgumentList $setupArgs
      $handle = $proc.Handle
      $proc.WaitForExit()
      $exitCode = $proc.ExitCode
      if ($exitCode -eq 0) {
        Write-Host "Uninstall performed correctly" -ForegroundColor Green
      }
      elseif ($exitCode -eq -125071) {
        Write-Host "Uninstall performed correctly but requires reboot before usage (modern installer)" -ForegroundColor Yellow
      }
      else {
        MyThrow("Uninstall failed! Exited with error code $exitCode.")
      }
    }
  }
}

if ($OpenPortsOnFirewall -and -Not $DryRun) {
  if ($64bitVersion) {
    $ProgramFilesPath = "Program Files"
  }
  else {
    $ProgramFilesPath = "Program Files (x86)"
  }
  $VI_Server_Enabled = "server.tcp.enabled=True"
  $LabVIEW_INI_Path = "C:/$ProgramFilesPath/National Instruments/LabVIEW $BaseVersion/LabVIEW.ini"
  if (Test-Path $LabVIEW_INI_Path) {
    if (Select-String -Path $LabVIEW_INI_Path -Pattern $VI_Server_Enabled -SimpleMatch) {
      Write-Host "LabVIEW.ini (${LabVIEW_INI_Path}) already contained instructions to have VI Server enabled" -ForegroundColor Green
    }
    else {
      Write-Host "LabVIEW.ini (${LabVIEW_INI_Path}) does not contain instructions to have VI Server enabled; adding $VI_Server_Enabled to the file for you" -ForegroundColor Yellow
      Add-Content ${LabVIEW_INI_Path} "`n$VI_Server_Enabled"
      Write-Host 'Done' -ForegroundColor Green
    }
  }
  else {
    $LabVIEW_INI_Content = @"
[LabVIEW]
IsFirstLaunch=False
ShowWelcomeOnLaunch=False
enableAutoWire=False
autoRouteWires=False
DefaultLabelPositionBD=11
DefaultLabelPositionIndBD=5
$VI_Server_Enabled
"@
    Out-File -FilePath $LabVIEW_INI_Path -InputObject $LabVIEW_INI_Content -Encoding UTF8
    Write-Host "LabVIEW.ini (${LabVIEW_INI_Path}) didn't exist. Creating a minimal file for you" -ForegroundColor Yellow
  }

  $LabVIEW_EXE_Path = Get-ChildItem "C:/$ProgramFilesPath/National Instruments/LabVIEW $BaseVersion/LabVIEW.exe"
  # Installing firewall rule to let labview be controlled remotely (VI server functionality)
  New-NetFirewallRule -DisplayName "LabVIEW $LabVIEWVersion" -Action Allow -EdgeTraversalPolicy Allow -LocalPort Any -Program "$LabVIEW_EXE_Path" | Out-Null
  # Installing firewall rules to let FPGA Compile Server being available
  New-NetFirewallRule -DisplayName "LabVIEW $LabVIEWVersion FPGA Compile Server 3363 TCP port" -Action Allow -EdgeTraversalPolicy Allow -Direction Inbound -LocalPort 3363 -Protocol TCP | Out-Null
  New-NetFirewallRule -DisplayName "LabVIEW $LabVIEWVersion FPGA Compile Server 3580 TCP port" -Action Allow -EdgeTraversalPolicy Allow -Direction Inbound -LocalPort 3580 -Protocol TCP | Out-Null
  New-NetFirewallRule -DisplayName "LabVIEW $LabVIEWVersion FPGA Compile Server 3580 UDP port" -Action Allow -EdgeTraversalPolicy Allow -Direction Inbound -LocalPort 3580 -Protocol UDP | Out-Null
  New-NetFirewallRule -DisplayName "LabVIEW $LabVIEWVersion FPGA Compile Server 3582 TCP port" -Action Allow -EdgeTraversalPolicy Allow -Direction Inbound -LocalPort 3582 -Protocol TCP | Out-Null
  New-NetFirewallRule -DisplayName "LabVIEW $LabVIEWVersion FPGA Compile Server 3582 UDP port" -Action Allow -EdgeTraversalPolicy Allow -Direction Inbound -LocalPort 3582 -Protocol UDP | Out-Null
  New-NetFirewallRule -DisplayName "LabVIEW $LabVIEWVersion FPGA Compile Server 8080 TCP port" -Action Allow -EdgeTraversalPolicy Allow -Direction Inbound -LocalPort 8080 -Protocol TCP | Out-Null

  Write-Host "Firewall rule installed" -ForegroundColor Green
  Write-Host "If running on an Azure VM, remember to open the ports also on Azure Portal for the VM!" -ForegroundColor Yellow
}

if (-Not $DisableSourceOnlyVIs -and -Not $DryRun) {
  if ($64bitVersion) {
    $ProgramFilesPath = "Program Files"
  }
  else {
    $ProgramFilesPath = "Program Files (x86)"
  }
  $source_only_VIs = "sourceOnlyDefaultForNewVIs=True"
  $LabVIEW_INI_Path = "C:/$ProgramFilesPath/National Instruments/LabVIEW $BaseVersion/LabVIEW.ini"
  if (Test-Path $LabVIEW_INI_Path) {
    if (Select-String -Path $LabVIEW_INI_Path -Pattern $source_only_VIs -SimpleMatch) {
      Write-Host "LabVIEW.ini (${LabVIEW_INI_Path}) already contained instructions to have source-only VIs" -ForegroundColor Green
    }
    else {
      Write-Host "LabVIEW.ini (${LabVIEW_INI_Path}) does not contain instructions to have  source-only VIs; adding $source_only_VIs to the file for you" -ForegroundColor Yellow
      Add-Content ${LabVIEW_INI_Path} "`n$source_only_VIs"
      Write-Host 'Done' -ForegroundColor Green
    }
  }
  else {
    $LabVIEW_INI_Content = @"
[LabVIEW]
IsFirstLaunch=False
ShowWelcomeOnLaunch=False
enableAutoWire=False
autoRouteWires=False
DefaultLabelPositionBD=11
DefaultLabelPositionIndBD=5
$source_only_VIs
"@
    Out-File -FilePath $LabVIEW_INI_Path -InputObject $LabVIEW_INI_Content -Encoding UTF8
    Write-Host "LabVIEW.ini (${LabVIEW_INI_Path}) didn't exist. Creating a minimal file for you" -ForegroundColor Yellow
  }
}

if ($UninstallAll) {
  Write-Host "Removal of all NI software is complete!" -ForegroundColor Green
}
else {
  Write-Host "Minting complete!" -ForegroundColor Green
  Write-Host "A reboot might be mandatory for many functionalities to be alive!" -ForegroundColor Red
}

$ErrorActionPreference = "SilentlyContinue"
Stop-Transcript | out-null
$ErrorActionPreference = "Continue"
