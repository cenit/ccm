function Enable-PythonVenv {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VenvPath)

    if (-not (Test-Path $VenvPath)) { Write-CcmFatalError "Could not find venv at $VenvPath" }
    $VenvPath = (Resolve-Path $VenvPath).Path

    if ($IsWindowsPowerShell -or $IsWindows) {
        $bin_dir = Join-Path $VenvPath 'Scripts'
    } else {
        $bin_dir = Join-Path $VenvPath 'bin'
    }

    if ($env:VIRTUAL_ENV -eq $VenvPath) {
        Write-Host 'Venv already activated'
        return
    }

    Write-Host 'Activating venv'

    # Python's standard `venv` module emits `Activate.ps1` on every platform,
    # but `uv venv` on Linux/macOS only writes the POSIX `activate` script —
    # no PowerShell activator. Probe both common name variants, then fall
    # back to in-process emulation. PowerShell propagates `$env:` changes to
    # the caller's scope because they live on the process environment block.
    $activate_script = @(
        (Join-Path $bin_dir 'Activate.ps1'),
        (Join-Path $bin_dir 'activate.ps1')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($activate_script) {
        & $activate_script
        return
    }

    Write-Host "No PowerShell activator in '$bin_dir' (typical for uv-created venvs on non-Windows); emulating activation in-process" -ForegroundColor Yellow

    $env:VIRTUAL_ENV = $VenvPath
    $env:PATH = "$bin_dir$([IO.Path]::PathSeparator)$env:PATH"
    if ($env:PYTHONHOME) {
        Remove-Item Env:\PYTHONHOME -ErrorAction SilentlyContinue
    }
}
