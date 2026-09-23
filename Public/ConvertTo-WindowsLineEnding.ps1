function ConvertTo-WindowsLineEnding {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$path)
    Get-ChildItem -File -Recurse -Path $path | ForEach-Object {
        $x = Get-Content -Raw -Path $_.FullName
        $SearchStr = [regex]::Escape("`r`n")
        $SEL = Select-String -InputObject $x -Pattern $SearchStr
        if ($null -ne $SEL) {
            Write-Host "Converting $_"
            # already has CRLF — avoid creating CRRLF on a second pass
        } else {
            Write-Host "Converting $_"
            $x -replace "`n", "`r`n" | Set-Content -NoNewline -Force -Path $_.FullName
        }
    }
}
