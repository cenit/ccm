function Save-Ninja {
    [CmdletBinding()]
    param()
    Write-Host 'Downloading a portable version of Ninja' -ForegroundColor Yellow
    Remove-Item -Force -Recurse -ErrorAction SilentlyContinue ninja
    Remove-Item -Force -ErrorAction SilentlyContinue ninja.zip
    if ($IsWindows -or $IsWindowsPowerShell) {
        $url = 'https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-win.zip'
    } elseif ($IsLinux) {
        $url = 'https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-linux.zip'
    } elseif ($IsMacOS) {
        $url = 'https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-mac.zip'
    } else {
        Write-CcmFatalError 'Unknown OS, unsupported'
    }
    Invoke-RestMethod -Uri $url -Method Get -ContentType application/zip -OutFile 'ninja.zip'
    Expand-Archive -Path ninja.zip
    Remove-Item -Force -ErrorAction SilentlyContinue ninja.zip
    return "./ninja${ExecutableSuffix}"
}
