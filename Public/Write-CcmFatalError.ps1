function Write-CcmFatalError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)

    if ($global:DisableInteractive) {
        Write-Host $Message -ForegroundColor Red
        throw
    } else {
        if ($psISE) {
            $Shell = New-Object -ComObject 'WScript.Shell'
            $Shell.Popup($Message, 0, 'OK', 0)
            throw
        }
        $Ignore = 16,17,18,20,91,92,93,144,145,166,167,168,169,170,171,172,173,174,175,176,177,178,179,180,181,182,183
        Write-Host $Message -ForegroundColor Red
        Write-Host -NoNewline 'Press any key to continue...'
        while (($null -eq $KeyInfo.VirtualKeyCode) -or ($Ignore -contains $KeyInfo.VirtualKeyCode)) {
            $KeyInfo = $Host.UI.RawUI.ReadKey('NoEcho, IncludeKeyDown')
        }
        Write-Host ''
        throw
    }
}
