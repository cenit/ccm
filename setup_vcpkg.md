# vcpkg Guide

This document will guide you to install and setup vcpkg

## Installation

### vcpkg

Follow the instructions on the `setup_eng.md` file to prepare basic tools for your system, preliminary to installing VCPKG.

Open PowerShell and run these commands to install vcpkg:

```pwsh
cd $env:WORKSPACE
git clone https://github.com/microsoft/vcpkg
```

Then you move into vcpkg folder

```pwsh
cd vcpkg
```

and execute the following command

```pwsh
.\bootstrap-vcpkg.bat -disableMetrics
```

### NuGet

Now you have to configure NuGet

```pwsh
.\vcpkg fetch nuget
cd downloads\tools\nuget-[...]
.\nuget | select -first 2
```

If the NuGet version is > 6.12 proceed with option A, otherwise with option B

#### Option A

```pwsh
.\nuget.exe sources add -Name vcpkgbinarycache -Source http://93.49.111.10:5555/v3/index.json -AllowInsecureConnections
```

#### Option B

```pwsh
.\nuget.exe sources add -Name vcpkgbinarycache -Source http://93.49.111.10:5555/v3/index.json
notepad $env:AppData\NuGet\NuGet.Config
```

Dentro al file `NuGet.Config` modificare la riga

```pwsh
    <add key="vcpkgbinarycache" value="http://93.49.111.10:5555/v3/index.json" />
```

aggiungendo il tag `allowInsecureConnections="true"` in questo modo:

```pwsh
    <add key="vcpkgbinarycache" value="http://93.49.111.10:5555/v3/index.json" allowInsecureConnections="true" />
```

#### Aggiunta API key per push su repository

```pwsh
.\nuget.exe setapikey REDACTED -Source http://93.49.111.10:5555/v3/index.json
```

## System environment variables

In the shell execute this command:

```pwsh
rundll32 sysdm.cpl,EditEnvironmentVariables
```

In *User variables for \<account name\>* click on *New*.

You have to add the following variables.
Per each variable you have to click on *New*.

- Variable name: `WSLENV`  
  Value name: `VCPKG_BINARY_SOURCES:VCPKG_FORCE_DOWNLOADED_BINARIES`

- Variable name: `VCPKG_FORCE_DOWNLOADED_BINARIES`  
  Value name: `TRUE`

- Variable name: `VCPKG_BINARY_SOURCES`  
  Value name: `clear;nuget,vcpkgbinarycache,readwrite;nugettimeout,86400`

When you have added all the variables click on *Ok* in the two windows of *Edit the system environment variables*.

### Add system environment variables form PowerShell (temporary for each session!!)

Execute the following commands:

```pwsh
$Env:WSLENV = 'VCPKG_BINARY_SOURCES:VCPKG_FORCE_DOWNLOADED_BINARIES'
$Env:VCPKG_FORCE_DOWNLOADED_BINARIES = 'TRUE'
$Env:VCPKG_BINARY_SOURCES = 'clear;nuget,vcpkgbinarycache,readwrite;nugettimeout,86400'
```

## Cleaning and testing

Remove temporary files

```pwsh
rm -r .\buildtrees\ -force ; rm -r .\packages\ -force ; rm -r .\installed\ -force ; rm -r .\build\ -force
```

and test if all is working:

```pwsh
.\vcpkg install fmt
```
