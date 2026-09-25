function Get-VisualStudioPath {
    [CmdletBinding()]
    param([bool]$required = $true)

    $programFiles = Get-ProgramFiles32Bit
    $vswhereExe = "$programFiles\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhereExe)) {
        if ($required) { Write-CcmFatalError "Could not locate vswhere at $vswhereExe" }
        else { Write-Host "Could not locate vswhere at $vswhereExe" -ForegroundColor Red; return $null }
    }

    foreach ($vswhereArgs in @(
        @('-products','*','-latest','-requires','Microsoft.VisualStudio.Workload.NativeDesktop','-format','xml'),
        @('-products','*','-latest','-format','xml'),
        @('-prerelease','-products','*','-latest','-format','xml')
    )) {
        $output = & $vswhereExe @vswhereArgs
        [xml]$asXml = $output
        $installationPath = $null
        foreach ($instance in $asXml.instances.instance) {
            $installationPath = $instance.InstallationPath -replace '\\$',''
        }
        if ($installationPath) { return $installationPath }
    }

    if ($required) { Write-CcmFatalError 'Could not locate any installation of Visual Studio' }
    else { Write-Host 'Could not locate any installation of Visual Studio' -ForegroundColor Red; return $null }
}
