function Initialize-PostgresEnvironment {
    [CmdletBinding()]
    param([bool]$required = $true)

    # Helper: finalize - set env vars and PATH, return bin dir
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
            $pf64 = Get-ProgramFiles64Bit
            $pf32 = Get-ProgramFiles32Bit
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
            Write-CcmFatalError "Could not find PostgreSQL bin folder. Please install PostgreSQL or ensure 'psql' is on PATH."
        }
        else {
            Write-Host "Could not find PostgreSQL bin folder" -ForegroundColor Red
        }
    }
}
