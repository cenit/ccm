function Save-7Zip {
    [CmdletBinding()]
    param()
    Write-Host 'Downloading a portable version of 7-Zip' -ForegroundColor Yellow
    if ($IsWindows -or $IsWindowsPowerShell) {
        $basename = '7za920'
        $zipName  = "${basename}.zip"
        $outFolder = "$basename"
        $outSuffix = 'a'
        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $outFolder
        Remove-Item -Force -ErrorAction SilentlyContinue $zipName
        $url = "https://www.7-zip.org/a/$zipName"
        Invoke-RestMethod -Uri $url -Method Get -ContentType application/zip -OutFile $zipName
        Expand-Archive -Path $zipName
    } elseif ($IsLinux) {
        $basename = '7z2201-linux-x64'
        $zipName  = "${basename}.tar.xz"
        $outFolder = $basename
        $outSuffix = 'z'
        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $outFolder
        Remove-Item -Force -ErrorAction SilentlyContinue $zipName
        $url = "https://www.7-zip.org/a/$zipName"
        Invoke-RestMethod -Uri $url -Method Get -ContentType application/zip -OutFile $zipName
        tar xf $zipName
    } elseif ($IsMacOS) {
        $basename = '7z2107-mac'
        $zipName  = "${basename}.tar.xz"
        $outFolder = $basename
        $outSuffix = 'z'
        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $outFolder
        Remove-Item -Force -ErrorAction SilentlyContinue $zipName
        $url = "https://www.7-zip.org/a/$zipName"
        Invoke-RestMethod -Uri $url -Method Get -ContentType application/zip -OutFile $zipName
        tar xf $zipName
    } else {
        Write-CcmFatalError 'Unknown OS, unsupported'
    }
    Remove-Item -Force -ErrorAction SilentlyContinue $zipName
    return "./$outFolder/7z${outSuffix}${ExecutableSuffix}"
}
