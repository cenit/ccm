function Save-Aria2 {
    [CmdletBinding()]
    param()
    Write-Host 'Downloading a portable version of Aria2' -ForegroundColor Yellow
    if ($IsWindows -or $IsWindowsPowerShell) {
        $basename = 'aria2-1.37.0-win-32bit-build1'
        $zipName  = "${basename}.zip"
        $outFolder = "$basename/$basename"
        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $outFolder
        Remove-Item -Force -ErrorAction SilentlyContinue $zipName
        $url = "https://github.com/aria2/aria2/releases/download/release-1.37.0/$zipName"
        Invoke-RestMethod -Uri $url -Method Get -ContentType application/zip -OutFile $zipName
        Expand-Archive -Path $zipName
    } elseif ($IsLinux) {
        $basename = 'aria2-1.36.0-linux-gnu-64bit-build1'
        $zipName  = "${basename}.tar.bz2"
        $outFolder = $basename
        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $outFolder
        Remove-Item -Force -ErrorAction SilentlyContinue $zipName
        $url = "https://github.com/q3aql/aria2-static-builds/releases/download/v1.36.0/$zipName"
        Invoke-RestMethod -Uri $url -Method Get -ContentType application/zip -OutFile $zipName
        tar xf $zipName
    } elseif ($IsMacOS) {
        $basename = 'aria2-1.35.0-osx-darwin'
        $zipName  = "${basename}.tar.bz2"
        $outFolder = 'aria2-1.35.0/bin'
        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $outFolder
        Remove-Item -Force -ErrorAction SilentlyContinue $zipName
        $url = "https://github.com/aria2/aria2/releases/download/release-1.35.0/$zipName"
        Invoke-RestMethod -Uri $url -Method Get -ContentType application/zip -OutFile $zipName
        tar xf $zipName
    } else {
        Write-CcmFatalError 'Unknown OS, unsupported'
    }
    Remove-Item -Force -ErrorAction SilentlyContinue $zipName
    return "./$outFolder/aria2c${ExecutableSuffix}"
}
