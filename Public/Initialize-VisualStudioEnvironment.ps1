function Initialize-VisualStudioEnvironment {
    [CmdletBinding()]
    param(
        [bool]$required     = $true,
        [bool]$enable_clang = $false
    )
    $CL_EXE = (Get-Command 'cl' -ErrorAction SilentlyContinue).Definition
    if ($CL_EXE) { return }

    $vsfound = Get-VisualStudioPath -required $required
    if (-not $vsfound) {
        if ($required) { Write-CcmFatalError 'Could not locate any installation of Visual Studio' }
        else { Write-Host 'Could not locate any installation of Visual Studio' -ForegroundColor Red; return }
    }

    Write-Host "Found VS in ${vsfound}"
    Push-Location "${vsfound}/Common7/Tools"
    # Note: Use ".\" prefix because cmd.exe spawned from certain environments
    # (e.g., Git Bash, MSYS2) doesn't search current directory for batch files
    cmd.exe /c ".\VsDevCmd.bat -arch=${vsArchitecture} & set" |
    ForEach-Object {
        if ($_ -match '=') {
            $v = $_.split('='); Set-Item -Force -Path "ENV:\$($v[0])" -Value "$($v[1])"
        }
    }
    Pop-Location
    if ($enable_clang) {
        $env:PATH = "${vsfound}/VC/Tools/Llvm/${vsArchitecture}/bin;$env:PATH"
    }
    Write-Host 'Visual Studio Command Prompt variables set'
}
