function Test-IsContainerizedRepository {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$Path = (Get-Location).Path
    )

    $signalNames = @(
        'Dockerfile', 'Containerfile',
        'docker-compose.yml', 'docker-compose.yaml',
        'compose.yml', 'compose.yaml',
        '.dockerignore'
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    $hits = Get-ChildItem -LiteralPath $Path -Recurse -Depth 1 -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $signalNames -contains $_.Name }

    return [bool]$hits
}
