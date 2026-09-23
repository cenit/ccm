function New-CcmSkillNuspecContent {
    <#
    .SYNOPSIS
    Assemble a skill package's nuspec content as a line array.

    .DESCRIPTION
    Extracted from the skills pipeline's inline "Pack skills" step
    (`azure-pipelines-skills.yml`) so its backward-compatibility guarantee --
    a skill declaring no `requires:` packs a nuspec byte-identical to the one
    produced before dependency support existed -- is asserted by a test
    rather than only a comment. Every skill packs through this
    template, so a regression here breaks every skill's package at once.

    NuGet requires `<dependencies>` inside `<metadata>`, and an empty
    `-Dependency` (the default) omits the element entirely, which is what
    preserves byte-identical output for a skill declaring nothing.

    .PARAMETER PackageId
    Full NuGet package id, e.g. 'skill-my-skill'.

    .PARAMETER Version
    The skill's semver, e.g. '1.2.0'.

    .PARAMETER Description
    Raw description text, as read from the skill's SKILL.md frontmatter (or
    the pipeline's fallback string when frontmatter has none). NuGet limits
    description length, so this is trimmed to 3900 characters with '...'
    appended when longer, then XML-escaped via
    [System.Security.SecurityElement]::Escape.

    .PARAMETER SkillDirectory
    Absolute path to the skill's source folder; becomes the `<file src="...">`
    root (with `\**\*` appended).

    .PARAMETER ContentTarget
    The `<file target="...">` value, e.g. 'content\my-skill'.

    .PARAMETER Dependency
    Zero or more already-resolved dependencies, each an object with an `Id`
    (the full, prefixed package id, e.g. 'skill-base-skill') and a
    `MinVersion`. Building the prefixed id is the caller's job -- this
    function has no knowledge of the pipeline's packagePrefix parameter.

    .PARAMETER Authors
    Value written to both `<authors>` and `<owners>`.

    .EXAMPLE
    New-CcmSkillNuspecContent -PackageId 'skill-my-skill' -Version '1.0.0' `
      -Description 'An example skill.' -SkillDirectory 'C:\repo\my-skill' `
      -ContentTarget 'content\my-skill'

    .EXAMPLE
    New-CcmSkillNuspecContent -PackageId 'skill-my-skill' -Version '1.0.0' `
      -Description 'An example skill.' -SkillDirectory 'C:\repo\my-skill' `
      -ContentTarget 'content\my-skill' `
      -Dependency @([pscustomobject]@{ Id = 'skill-base-skill'; MinVersion = '1.0.0' })
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackageId,

        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Description,

        [Parameter(Mandatory)]
        [string]$SkillDirectory,

        [Parameter(Mandatory)]
        [string]$ContentTarget,

        [object[]]$Dependency = @(),

        [string]$Authors = 'Stefano Sinigardi'
    )

    # NuGet description is limited; trim to 3900 chars and escape XML.
    $desc = $Description
    if ($desc.Length -gt 3900) { $desc = $desc.Substring(0, 3900) + '...' }
    $descXml = [System.Security.SecurityElement]::Escape($desc)

    # A skill declaring nothing produces exactly the nuspec this template
    # produced before dependency support existed.
    $depLines = @()
    if (@($Dependency).Count -gt 0) {
        $depLines += '    <dependencies>'
        foreach ($d in $Dependency) {
            $depLines += "      <dependency id=`"$($d.Id)`" version=`"$($d.MinVersion)`" />"
        }
        $depLines += '    </dependencies>'
    }

    @(
        '<?xml version="1.0" encoding="utf-8"?>',
        '<package xmlns="http://schemas.microsoft.com/packaging/2010/07/nuspec.xsd">',
        '  <metadata>',
        "    <id>$PackageId</id>",
        "    <version>$Version</version>",
        "    <authors>$([System.Security.SecurityElement]::Escape($Authors))</authors>",
        "    <owners>$([System.Security.SecurityElement]::Escape($Authors))</owners>",
        "    <description>$descXml</description>",
        '    <requireLicenseAcceptance>false</requireLicenseAcceptance>',
        '    <tags>claude-skill codex</tags>'
    ) + $depLines + @(
        '  </metadata>',
        '  <files>',
        "    <file src=`"$SkillDirectory\**\*`" target=`"$ContentTarget`" exclude=`"**\*.log;**\.git\**`" />",
        '  </files>',
        '</package>'
    )
}
