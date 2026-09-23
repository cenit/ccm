function Copy-TexFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MyFile)
    $MyFileName = Split-Path $MyFile -Leaf
    New-Item -ItemType Directory -Force -Path "~/${latex_path}" | Out-Null
    if (-not (Test-Path "~/${latex_path}/$MyFileName")) {
        Write-Host "Copying $MyFile to ~/${latex_path}"
        Copy-Item $MyFile "~/${latex_path}"
    } else {
        Write-Host "~/${latex_path}/$MyFileName already present"
    }
}
