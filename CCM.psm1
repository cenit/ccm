$ErrorActionPreference = 'Stop'

$IsWindowsPowerShell = $PSVersionTable.PSVersion.Major -le 5
$ExecutableSuffix    = if ($IsWindowsPowerShell -or $IsWindows) { '.exe' } else { '' }
$64bitPwsh           = [Environment]::Is64BitProcess
$64bitOS             = [Environment]::Is64BitOperatingSystem
$osArchitecture      = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture

switch ($osArchitecture) {
    'X86'   { $vcpkgArchitecture = 'x86';   $vsArchitecture = 'Win32' }
    'X64'   { $vcpkgArchitecture = 'x64';   $vsArchitecture = 'x64'   }
    'Arm'   { $vcpkgArchitecture = 'arm';   $vsArchitecture = 'arm'   }
    'Arm64' { $vcpkgArchitecture = 'arm64'; $vsArchitecture = 'arm64' }
    default { $vcpkgArchitecture = 'x64';   $vsArchitecture = 'x64'   }
}

Push-Location $PSScriptRoot
$GIT_EXE = (Get-Command 'git' -ErrorAction SilentlyContinue).Definition
if ($GIT_EXE) {
    $sub = git rev-parse --show-superproject-working-tree 2>$null
    $IsInGitSubmodule = -not [string]::IsNullOrEmpty($sub)
} else {
    $IsInGitSubmodule = $false
}
Pop-Location

$utils_psm1_version = (Import-PowerShellDataFile (Join-Path $PSScriptRoot 'CCM.psd1')).ModuleVersion

$cuda_version_full = "12.6.2"
$cuda_version_short = "12.6"
$cuda_version_full_dashed = $cuda_version_full.replace('.', '-')
$cuda_version_short_dashed = $cuda_version_short.replace('.', '-')

$private = @(Get-ChildItem (Join-Path $PSScriptRoot 'Private') -Filter *.ps1 -ErrorAction SilentlyContinue)
$public  = @(Get-ChildItem (Join-Path $PSScriptRoot 'Public')  -Filter *.ps1 -ErrorAction SilentlyContinue)
foreach ($f in $private + $public) { . $f.FullName }

if ($public.Count -gt 0) {
    Export-ModuleMember -Function $public.BaseName -Alias '*' -Variable @(
        'IsWindowsPowerShell', 'IsInGitSubmodule', '64bitPwsh', '64bitOS',
        'osArchitecture', 'vcpkgArchitecture', 'vsArchitecture',
        'ExecutableSuffix', 'utils_psm1_version',
        'cuda_version_full', 'cuda_version_short',
        'cuda_version_full_dashed', 'cuda_version_short_dashed'
    )
}
