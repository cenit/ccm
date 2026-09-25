function Stop-CcmLogging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [pscustomobject]$State
    )
    process {
        if (-not $State) { return }
        if ($State.Stopped) { return }
        try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
        if ($State.EventSubscriberId) {
            Unregister-Event -SubscriptionId $State.EventSubscriberId -ErrorAction SilentlyContinue
            $State.EventSubscriberId = $null
        }
        $State.Stopped = $true
    }
}
