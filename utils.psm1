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

$utils_psm1_version = "1.5.0"
$IsWindowsPowerShell = switch ( $PSVersionTable.PSVersion.Major ) {
  5 { $true }
  4 { $true }
  3 { $true }
  2 { $true }
  default { $false }
}

$ExecutableSuffix = ""
if ($IsWindowsPowerShell -or $IsWindows) {
  $ExecutableSuffix = ".exe"
}

$64bitPwsh = $([Environment]::Is64BitProcess)
$64bitOS = $([Environment]::Is64BitOperatingSystem)
$osArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
switch ($osArchitecture) {
  "X86" {
    $vcpkgArchitecture = "x86"
    $vsArchitecture = "Win32"
  }
  "X64" {
    $vcpkgArchitecture = "x64"
    $vsArchitecture = "x64"
  }
  "Arm" {
    $vcpkgArchitecture = "arm"
    $vsArchitecture = "arm"
  }
  "Arm64" {
    $vcpkgArchitecture = "arm64"
    $vsArchitecture = "arm64"
  }
  default {
    $vcpkgArchitecture = "x64"
    $vsArchitecture = "x64"
    Write-Output "Unknown architecture. Trying x64"
  }
}


Push-Location $PSScriptRoot
$GIT_EXE = Get-Command "git" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
if ($GIT_EXE) {
  $IsInGitSubmoduleString = $(git rev-parse --show-superproject-working-tree 2> $null)
  if ($IsInGitSubmoduleString.Length -eq 0) {
    $IsInGitSubmodule = $false
  }
  else {
    $IsInGitSubmodule = $true
  }
}
else {
  $IsInGitSubmodule = $false
}
Pop-Location


function activateVenv([string]$VenvPath) {
  if ($IsWindowsPowerShell -or $IsWindows) {
    $activate_script = "$VenvPath/Scripts/Activate.ps1"
  }
  else {
    $activate_script = "$VenvPath/bin/Activate.ps1"
  }

  $activate_script = Resolve-Path $activate_script
  $VenvPath = Resolve-Path $VenvPath

  if ($env:VIRTUAL_ENV -eq $VenvPath) {
    Write-Host "Venv already activated"
    return
  }
  else {
    Write-Host "Activating venv"
    if (-Not (Test-Path $activate_script)) {
      MyThrow("Could not find activate script at $activate_script")
    }
    & $activate_script
  }
}

function Install-RequirementsWithRetry {
  param(
      [string]$PythonPath   = 'python',
      [string]$FilePath     = 'requirements.txt',
      [int]   $MaxRetries   = 5,
      [int]   $DelaySeconds = 5
  )

  $attempt = 0
  do {
      $attempt++
      Write-Host "[$attempt/$MaxRetries] Installing from $FilePath ..."

      # Run pip and capture both its output and exit code
      $output = & $PythonPath -m pip install --upgrade -r $FilePath 2>&1
      $exit   = $LASTEXITCODE

      if ($exit -eq 0) {
          Write-Host "Success on attempt $attempt." -ForegroundColor Green
          return
      }

      # Check for a 403 in pip's output
      if ($output -match 'HTTP Error 403') {
          Write-Host "Received 403 - proxy is probably throttling.  Waiting $DelaySeconds s before retry..." -ForegroundColor Yellow
          Start-Sleep -Seconds $DelaySeconds
      }
      else {
          Write-Host "pip failed with an unexpected error (exit code $exit):" -ForegroundColor Red
          Write-Host $output -ForegroundColor Red
          return
      }

  } while ($attempt -lt $MaxRetries)

  Write-Host "Failed to install after $MaxRetries attempts." -ForegroundColor Red
}

function getProgramFiles32bit() {
  $out = ${env:PROGRAMFILES(X86)}
  if ($null -eq $out) {
    $out = ${env:PROGRAMFILES}
  }

  if ($null -eq $out) {
    MyThrow("Could not find [Program Files 32-bit]")
  }

  return $out
}

function getProgramFiles64bit() {
  $out = ${env:ProgramFiles}

  if ($null -eq $out) {
    MyThrow("Could not find [Program Files 32-bit]")
  }

  return $out
}

function getLatestVisualStudioWithDesktopWorkloadPath([bool]$required = $true) {
  $programFiles = getProgramFiles32bit
  $vswhereExe = "$programFiles\Microsoft Visual Studio\Installer\vswhere.exe"
  if (Test-Path $vswhereExe) {
    $output = & $vswhereExe -products * -latest -requires Microsoft.VisualStudio.Workload.NativeDesktop -format xml
    [xml]$asXml = $output
    foreach ($instance in $asXml.instances.instance) {
      $installationPath = $instance.InstallationPath -replace "\\$" # Remove potential trailing backslash
    }
    if (!$installationPath) {
      #Write-Host "Warning: no full Visual Studio setup has been found, extending search to include also partial installations" -ForegroundColor Yellow
      $output = & $vswhereExe -products * -latest -format xml
      [xml]$asXml = $output
      foreach ($instance in $asXml.instances.instance) {
        $installationPath = $instance.InstallationPath -replace "\\$" # Remove potential trailing backslash
      }
    }
    if (!$installationPath) {
      #Write-Host "Warning: no full Visual Studio setup has been found, extending search to include also pre-release installations" -ForegroundColor Yellow
      $output = & $vswhereExe -prerelease -products * -latest -format xml
      [xml]$asXml = $output
      foreach ($instance in $asXml.instances.instance) {
        $installationPath = $instance.InstallationPath -replace "\\$" # Remove potential trailing backslash
      }
    }
    if (!$installationPath) {
      if ($required) {
        MyThrow("Could not locate any installation of Visual Studio")
      }
      else {
        Write-Host "Could not locate any installation of Visual Studio" -ForegroundColor Red
        return $null
      }
    }
  }
  else {
    if ($required) {
      MyThrow("Could not locate vswhere at $vswhereExe")
    }
    else {
      Write-Host "Could not locate vswhere at $vswhereExe" -ForegroundColor Red
      return $null
    }
  }
  return $installationPath
}

function getLatestVisualStudioWithDesktopWorkloadVersion([bool]$required = $true) {
  $programFiles = getProgramFiles32bit
  $vswhereExe = "$programFiles\Microsoft Visual Studio\Installer\vswhere.exe"
  if (Test-Path $vswhereExe) {
    $output = & $vswhereExe -products * -latest -requires Microsoft.VisualStudio.Workload.NativeDesktop -format xml
    [xml]$asXml = $output
    foreach ($instance in $asXml.instances.instance) {
      $installationVersion = $instance.InstallationVersion
    }
    if (!$installationVersion) {
      #Write-Host "Warning: no full Visual Studio setup has been found, extending search to include also partial installations" -ForegroundColor Yellow
      $output = & $vswhereExe -products * -latest -format xml
      [xml]$asXml = $output
      foreach ($instance in $asXml.instances.instance) {
        $installationVersion = $instance.installationVersion
      }
    }
    if (!$installationVersion) {
      #Write-Host "Warning: no full Visual Studio setup has been found, extending search to include also pre-release installations" -ForegroundColor Yellow
      $output = & $vswhereExe -prerelease -products * -latest -format xml
      [xml]$asXml = $output
      foreach ($instance in $asXml.instances.instance) {
        $installationVersion = $instance.installationVersion
      }
    }
    if (!$installationVersion) {
      if ($required) {
        MyThrow("Could not locate any installation of Visual Studio")
      }
      else {
        Write-Host "Could not locate any installation of Visual Studio" -ForegroundColor Red
        return $null
      }
    }
  }
  else {
    if ($required) {
      MyThrow("Could not locate vswhere at $vswhereExe")
    }
    else {
      Write-Host "Could not locate vswhere at $vswhereExe" -ForegroundColor Red
      return $null
    }
  }
  return $installationVersion
}

function setupVisualStudio([bool]$required = $true, [bool]$enable_clang = $false) {
  $CL_EXE = Get-Command "cl" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
  if (-Not $CL_EXE) {
    $vsfound = getLatestVisualStudioWithDesktopWorkloadPath($required)
    if (-Not $vsfound) {
      if ($required) {
        MyThrow("Could not locate any installation of Visual Studio")
      }
      else {
        Write-Host "Could not locate any installation of Visual Studio" -ForegroundColor Red
        return
      }
    }
    else {
      Write-Host "Found VS in ${vsfound}"
      Push-Location "${vsfound}/Common7/Tools"
      cmd.exe /c "VsDevCmd.bat -arch=${vsArchitecture} & set" |
      ForEach-Object {
        if ($_ -match "=") {
          $v = $_.split("="); Set-Item -force -path "ENV:\$($v[0])" -value "$($v[1])"
        }
      }
      Pop-Location
      if ($enable_clang) {
        $env:PATH = "${vsfound}/VC/Tools/Llvm/${vsArchitecture}/bin;$env:PATH"
      }
      Write-Host "Visual Studio Command Prompt variables set"
    }
  }
}

function setupPostgres([bool]$required = $true) {
  function _Set-PostgresBin([string]$binDir) {
    if (-not $binDir) { return $null }

    # Prepend to PATH if not already present (cross-platform separator)
    $pathSep = [IO.Path]::PathSeparator
    $pathEntries = $env:PATH -split [Regex]::Escape($pathSep)
    if (-not ($pathEntries -contains $binDir)) {
      $env:PATH = "$binDir$pathSep$env:PATH"
    }

    $env:POSTGRES_BIN = $binDir
    Write-Host "PostgreSQL bin set to '$binDir'"
    chcp 1252
    Write-Host "Console encoding set to Windows-1252"
  }

  # 1) If psql is already available, use it
  try {
    $psqlCmd = Get-Command ("psql" + $ExecutableSuffix) -ErrorAction SilentlyContinue
    if ($psqlCmd -and $psqlCmd.Source) {
      $binDir = Split-Path -Parent $psqlCmd.Source
      if ($binDir -and (Test-Path $binDir)) {
        return _Set-PostgresBin $binDir
      }
    }
  } catch {}

  # 2) If pg_config is available, ask it for --bindir
  try {
    $pgConfigCmd = Get-Command ("pg_config" + $ExecutableSuffix) -ErrorAction SilentlyContinue
    if ($pgConfigCmd -and $pgConfigCmd.Source) {
      $bindir = & $pgConfigCmd.Source --bindir 2>$null
      if ($bindir) { $bindir = $bindir.Trim() }
      if ($bindir -and (Test-Path $bindir)) {
        return _Set-PostgresBin $bindir
      }
    }
  } catch {}

  # 3) Platform-specific searches
  $foundBin = $null
  if ($IsWindowsPowerShell -or $IsWindows) {
    # --- Windows: search common locations and the registry ---
    $candidates = New-Object System.Collections.Generic.List[string]

    # Program Files variants
    try {
      $pf64 = getProgramFiles64bit
      $pf32 = getProgramFiles32bit
    } catch {}

    foreach ($root in @(
      (Join-Path $pf64 "PostgreSQL"),
      (Join-Path $pf32 "PostgreSQL"),
      "C:\PostgreSQL"
    )) {
      if ($root -and (Test-Path $root)) {
        # Prefer numeric version folders sorted descending
        $versionDirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object {
          try { [version] ($_.Name -replace '[^\d\.]','') } catch { [version]"0.0" }
        } -Descending

        foreach ($v in $versionDirs) {
          $candidates.Add( (Join-Path $v.FullName "bin") )
        }

        # Also add any /bin under the root as fallback
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
          $candidates.Add( (Join-Path $_.FullName "bin") )
        }
      }
    }

    # Registry (EnterpriseDB installers)
    foreach ($hk in @(
      "HKLM:\SOFTWARE\PostgreSQL\Installations",
      "HKLM:\SOFTWARE\WOW6432Node\PostgreSQL\Installations"
    )) {
      if (Test-Path $hk) {
        Get-ChildItem $hk -ErrorAction SilentlyContinue | ForEach-Object {
          try {
            $base = (Get-ItemProperty -Path $_.PsPath -Name "Base Directory" -ErrorAction SilentlyContinue)."Base Directory"
            if ($base) { $candidates.Add( (Join-Path $base "bin") ) }
            $bin  = (Get-ItemProperty -Path $_.PsPath -Name "BinDir" -ErrorAction SilentlyContinue)."BinDir"
            if ($bin)  { $candidates.Add( $bin ) }
          } catch {}
        }
      }
    }

    # Chocolatey (older packages can place tools here)
    if ($env:ChocolateyInstall) {
      $chocoPg = Join-Path $env:ChocolateyInstall "lib\postgresql"
      if (Test-Path $chocoPg) {
        Get-ChildItem -Path $chocoPg -Directory -ErrorAction SilentlyContinue | ForEach-Object {
          $tools = Join-Path $_.FullName "tools"
          if (Test-Path $tools) { $candidates.Add($tools) }
        }
      }
    }

    # Scoop
    if ($env:SCOOP) {
      foreach ($p in @(
        (Join-Path $env:SCOOP "apps\postgresql\current\bin"),
        (Join-Path $env:SCOOP "apps\psql\current\bin")
      )) { $candidates.Add($p) }
    }

    # Validate candidates by checking psql presence
    $foundBin = $candidates |
      Where-Object { $_ -and (Test-Path $_) -and (Test-Path (Join-Path $_ ("psql" + $ExecutableSuffix))) } |
      Select-Object -Unique |
      Select-Object -First 1

  }
  else {
    # --- macOS / Linux ---
    # Homebrew (Intel & Apple Silicon), Debian/Ubuntu, RHEL/CentOS, EDB macOS, source default
    $patterns = @(
      "/opt/homebrew/opt/postgresql/bin",
      "/opt/homebrew/opt/postgresql@*/bin",
      "/usr/local/opt/postgresql/bin",
      "/usr/local/opt/postgresql@*/bin",
      "/usr/lib/postgresql/*/bin",
      "/usr/pgsql-*/bin",
      "/Library/PostgreSQL/*/bin",
      "/usr/local/pgsql/bin",
      "/usr/local/bin",
      "/usr/bin"
    )

    $dirs = @()
    foreach ($pat in $patterns) {
      try {
        # Expand globs (Get-ChildItem handles */ wildcards)
        if ($pat -like "*`**" -or $pat -like "*`**/*") {
          # (not used here, but kept for completeness)
        }
        if ($pat -like "*`**") {
          $dirs += (Get-ChildItem -Path $pat -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        }
        elseif ($pat -like "*`**/*" -or $pat -like "*/bin") {
          $dirs += (Get-ChildItem -Path $pat -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        }
        else {
          if (Test-Path $pat) { $dirs += $pat }
          $dirs += (Get-ChildItem -Path $pat -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        }
      } catch {}
    }

    $foundBin = $dirs |
      Where-Object { $_ -and (Test-Path $_) -and (Test-Path (Join-Path $_ "psql")) } |
      Select-Object -Unique |
      Select-Object -First 1
  }

  if ($foundBin) {
    _Set-PostgresBin $foundBin
  }
  else {
    if ($required) {
      MyThrow("Could not find PostgreSQL bin folder. Please install PostgreSQL or ensure 'psql' is on PATH.")
    }
    else {
      Write-Host "Could not find PostgreSQL bin folder" -ForegroundColor Red
    }
  }
}

function DownloadNinja() {
  Write-Host "Downloading a portable version of Ninja" -ForegroundColor Yellow
  Remove-Item -Force -Recurse -ErrorAction SilentlyContinue ninja
  Remove-Item -Force -ErrorAction SilentlyContinue ninja.zip
  if ($IsWindows -or $IsWindowsPowerShell) {
    $url = "https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-win.zip"
  }
  elseif ($IsLinux) {
    $url = "https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-linux.zip"
  }
  elseif ($IsMacOS) {
    $url = "https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-mac.zip"
  }
  else {
    MyThrow("Unknown OS, unsupported")
  }
  Invoke-RestMethod -Uri $url -Method Get -ContentType application/zip -OutFile "ninja.zip"
  Expand-Archive -Path ninja.zip
  Remove-Item -Force -ErrorAction SilentlyContinue ninja.zip
  return "./ninja${ExecutableSuffix}"
}

function DownloadAria2() {
  Write-Host "Downloading a portable version of Aria2" -ForegroundColor Yellow
  if ($IsWindows -or $IsWindowsPowerShell) {
    $basename = "aria2-1.37.0-win-32bit-build1"
    $zipName = "${basename}.zip"
    $outFolder = "$basename/$basename"
    Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $outFolder
    Remove-Item -Force -ErrorAction SilentlyContinue $zipName
    $url = "https://github.com/aria2/aria2/releases/download/release-1.37.0/$zipName"
    Invoke-RestMethod -Uri $url -Method Get -ContentType application/zip -OutFile $zipName
    Expand-Archive -Path $zipName
  }
  elseif ($IsLinux) {
    $basename = "aria2-1.36.0-linux-gnu-64bit-build1"
    $zipName = "${basename}.tar.bz2"
    $outFolder = $basename
    Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $outFolder
    Remove-Item -Force -ErrorAction SilentlyContinue $zipName
    $url = "https://github.com/q3aql/aria2-static-builds/releases/download/v1.36.0/$zipName"
    Invoke-RestMethod -Uri $url -Method Get -ContentType application/zip -OutFile $zipName
    tar xf $zipName
  }
  elseif ($IsMacOS) {
    $basename = "aria2-1.35.0-osx-darwin"
    $zipName = "${basename}.tar.bz2"
    $outFolder = "aria2-1.35.0/bin"
    Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $outFolder
    Remove-Item -Force -ErrorAction SilentlyContinue $zipName
    $url = "https://github.com/aria2/aria2/releases/download/release-1.35.0/$zipName"
    Invoke-RestMethod -Uri $url -Method Get -ContentType application/zip -OutFile $zipName
    tar xf $zipName
  }
  else {
    MyThrow("Unknown OS, unsupported")
  }
  Remove-Item -Force -ErrorAction SilentlyContinue $zipName
  return "./$outFolder/aria2c${ExecutableSuffix}"
}

function DownloadLicencpp() {
  $licencpp_version = "0.2.5"
  Write-Host "Downloading a portable version of licencpp v${licencpp_version}" -ForegroundColor Yellow
  if ($IsWindows -or $IsWindowsPowerShell) {
    $basename = "licencpp-Windows"
  }
  elseif ($IsLinux) {
    $basename = "licencpp-Linux"
  }
  else {
    MyThrow("Unknown OS, unsupported")
  }
  $zipName = "${basename}.zip"
  $outFolder = "${basename}"
  Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $outFolder
  Remove-Item -Force -ErrorAction SilentlyContinue $zipName
  $url = "https://github.com/cenit/licencpp/releases/download/v${licencpp_version}/$zipName"
  Invoke-RestMethod -Uri $url -Method Get -ContentType application/zip -OutFile $zipName
  Expand-Archive -Path $zipName
  Remove-Item -Force -ErrorAction SilentlyContinue $zipName
  return "./$outFolder/licencpp${ExecutableSuffix}"
}

function Download7Zip() {
  Write-Host "Downloading a portable version of 7-Zip" -ForegroundColor Yellow
  if ($IsWindows -or $IsWindowsPowerShell) {
    $basename = "7za920"
    $zipName = "${basename}.zip"
    $outFolder = "$basename"
    $outSuffix = "a"
    Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $outFolder
    Remove-Item -Force -ErrorAction SilentlyContinue $zipName
    $url = "https://www.7-zip.org/a/$zipName"
    Invoke-RestMethod -Uri $url -Method Get -ContentType application/zip -OutFile $zipName
    Expand-Archive -Path $zipName
  }
  elseif ($IsLinux) {
    $basename = "7z2201-linux-x64"
    $zipName = "${basename}.tar.xz"
    $outFolder = $basename
    $outSuffix = "z"
    Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $outFolder
    Remove-Item -Force -ErrorAction SilentlyContinue $zipName
    $url = "https://www.7-zip.org/a/$zipName"
    Invoke-RestMethod -Uri $url -Method Get -ContentType application/zip -OutFile $zipName
    tar xf $zipName
  }
  elseif ($IsMacOS) {
    $basename = "7z2107-mac"
    $zipName = "${basename}.tar.xz"
    $outFolder = $basename
    $outSuffix = "z"
    Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $outFolder
    Remove-Item -Force -ErrorAction SilentlyContinue $zipName
    $url = "https://www.7-zip.org/a/$zipName"
    Invoke-RestMethod -Uri $url -Method Get -ContentType application/zip -OutFile $zipName
    tar xf $zipName
  }
  else {
    MyThrow("Unknown OS, unsupported")
  }
  Remove-Item -Force -ErrorAction SilentlyContinue $zipName
  return "./$outFolder/7z${outSuffix}${ExecutableSuffix}"
}

Function MyThrow ($Message) {
  if ($global:DisableInteractive) {
    Write-Host $Message -ForegroundColor Red
    throw
  }
  else {
    # Check if running in PowerShell ISE
    if ($psISE) {
      # "ReadKey" not supported in PowerShell ISE.
      # Show MessageBox UI
      $Shell = New-Object -ComObject "WScript.Shell"
      $Shell.Popup($Message, 0, "OK", 0)
      throw
    }

    $Ignore =
    16, # Shift (left or right)
    17, # Ctrl (left or right)
    18, # Alt (left or right)
    20, # Caps lock
    91, # Windows key (left)
    92, # Windows key (right)
    93, # Menu key
    144, # Num lock
    145, # Scroll lock
    166, # Back
    167, # Forward
    168, # Refresh
    169, # Stop
    170, # Search
    171, # Favorites
    172, # Start/Home
    173, # Mute
    174, # Volume Down
    175, # Volume Up
    176, # Next Track
    177, # Previous Track
    178, # Stop Media
    179, # Play
    180, # Mail
    181, # Select Media
    182, # Application 1
    183  # Application 2

    Write-Host $Message -ForegroundColor Red
    Write-Host -NoNewline "Press any key to continue..."
    while (($null -eq $KeyInfo.VirtualKeyCode) -or ($Ignore -contains $KeyInfo.VirtualKeyCode)) {
      $KeyInfo = $Host.UI.RawUI.ReadKey("NoEcho, IncludeKeyDown")
    }
    Write-Host ""
    throw
  }
}

Function CopyTexFile ($MyFile) {
  $MyFileName = Split-Path $MyFile -Leaf
  New-Item -ItemType Directory -Force -Path "~/${latex_path}" | Out-Null
  if (-Not (Test-Path "~/${latex_path}/$MyFileName" )) {
    Write-Host "Copying $MyFile to ~/${latex_path}"
    Copy-Item "$MyFile" "~/${latex_path}"
  }
  else {
    Write-Host "~/${latex_path}/$MyFileName already present"
  }
}

Function dos2unix {
  Param (
    [Parameter(mandatory = $true)]
    [string[]]$path
  )

  Get-ChildItem -File -Recurse -Path $path |
  ForEach-Object {
    Write-Host "Converting $_"
    $x = get-content -raw -path $_.fullname; $x -replace "`r`n", "`n" | Set-Content -NoNewline -Force -path $_.fullname
  }
}

Function unix2dos {
  Param (
    [Parameter(mandatory = $true)]
    [string[]]$path
  )

  Get-ChildItem -File -Recurse -Path $path |
  ForEach-Object {
    $x = get-content -raw -path $_.fullname
    $SearchStr = [regex]::Escape("`r`n")
    $SEL = Select-String -InputObject $x -Pattern $SearchStr
    if ($null -ne $SEL) {
      Write-Host "Converting $_"
      # do nothing: avoid creating files containing `r`r`n when using unix2dos twice on the same file
    }
    else {
      Write-Host "Converting $_"
      $x -replace "`n", "`r`n" | Set-Content -NoNewline -Force -path $_.fullname
    }
  }
}

Function UpdateRepo {
  if ($GIT_EXE) {
    Get-ChildItem -Directory |
      ForEach-Object {
      Set-Location $_.Name
      git pull
      git submodule update --recursive
      Set-Location ..
    }
  }
}


$cuda_version_full = "12.6.2"
$cuda_version_short = "12.6"
$cuda_version_full_dashed = $cuda_version_full.replace('.', '-')
$cuda_version_short_dashed = $cuda_version_short.replace('.', '-')

Export-ModuleMember -Variable cuda_version_full
Export-ModuleMember -Variable cuda_version_short
Export-ModuleMember -Variable cuda_version_full_dashed
Export-ModuleMember -Variable cuda_version_short_dashed
Export-ModuleMember -Variable utils_psm1_version
Export-ModuleMember -Variable IsWindowsPowerShell
Export-ModuleMember -Variable IsInGitSubmodule
Export-ModuleMember -Variable 64bitPwsh
Export-ModuleMember -Variable 64bitOS
Export-ModuleMember -Variable osArchitecture
Export-ModuleMember -Variable vcpkgArchitecture
Export-ModuleMember -Variable vsArchitecture
Export-ModuleMember -Variable ExecutableSuffix
Export-ModuleMember -Function activateVenv
Export-ModuleMember -Function Install-RequirementsWithRetry
Export-ModuleMember -Function getProgramFiles32bit
Export-ModuleMember -Function getProgramFiles64bit
Export-ModuleMember -Function getLatestVisualStudioWithDesktopWorkloadPath
Export-ModuleMember -Function getLatestVisualStudioWithDesktopWorkloadVersion
Export-ModuleMember -Function setupVisualStudio
Export-ModuleMember -Function setupPostgres
Export-ModuleMember -Function DownloadNinja
Export-ModuleMember -Function DownloadAria2
Export-ModuleMember -Function Download7Zip
Export-ModuleMember -Function DownloadLicencpp
Export-ModuleMember -Function MyThrow
Export-ModuleMember -Function CopyTexFile
Export-ModuleMember -Function dos2unix
Export-ModuleMember -Function unix2dos
Export-ModuleMember -Function UpdateRepo
