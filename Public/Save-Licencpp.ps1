function Save-Licencpp {
    [CmdletBinding()]
    param()
    $licencpp_version = '0.2.6'
    Write-Host "Downloading a portable version of licencpp v${licencpp_version}" -ForegroundColor Yellow
    if ($IsWindows -or $IsWindowsPowerShell) {
        $basename = 'licencpp-Windows'
    } elseif ($IsLinux) {
        $basename = 'licencpp-Linux'
    } else {
        Write-CcmFatalError 'Unknown OS, unsupported'
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
