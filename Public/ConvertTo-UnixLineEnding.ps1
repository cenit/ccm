function ConvertTo-UnixLineEnding {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$path)
    Get-ChildItem -File -Recurse -Path $path | ForEach-Object {
        Write-Host "Converting $_"
        $x = Get-Content -Raw -Path $_.FullName
        $x -replace "`r`n", "`n" | Set-Content -NoNewline -Force -Path $_.FullName
    }
}
