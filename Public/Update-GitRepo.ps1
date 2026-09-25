function Update-GitRepo {
    [CmdletBinding()]
    param()
    if ($GIT_EXE) {
        Get-ChildItem -Directory | ForEach-Object {
            Set-Location $_.Name
            git pull
            git submodule update --recursive
            Set-Location ..
        }
    }
}
