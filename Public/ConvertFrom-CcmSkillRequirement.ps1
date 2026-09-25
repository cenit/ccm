function ConvertFrom-CcmSkillRequirement {
    <#
    .SYNOPSIS
    Parse a skill's `requires:` frontmatter value into dependency objects.

    .DESCRIPTION
    The value is one line, comma-separated, each entry `<name>>=<semver>`.
    Single-line and regex-parseable by design: the skills pipeline reads
    frontmatter with regexes and has no YAML parser, so a block sequence would
    force a YAML dependency into the shared template.

    Throws on a malformed entry - one that doesn't match the
    `<name>>=<semver>` shape - rather than skipping it. A typo here would
    otherwise become a NuGet dependency on a package that cannot exist, and the
    failure would surface at install time on someone else's machine.

    An empty comma segment (a trailing comma, or a doubled comma between two
    entries) is tolerated rather than treated as malformed: it carries no
    name or version to typo, so it can only be leftover list punctuation from
    an edit, and dropping it yields exactly what the author meant.

    .PARAMETER Requirement
    The raw `requires:` value. Empty or whitespace yields no dependencies.

    .EXAMPLE
    ConvertFrom-CcmSkillRequirement -Requirement 'my-skill>=1.0.0, other-skill>=2.0.0'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Requirement
    )

    $result = @()
    if ([string]::IsNullOrWhiteSpace($Requirement)) { return $result }

    foreach ($entry in $Requirement -split ',') {
        $trimmed = $entry.Trim()
        if (-not $trimmed) { continue }

        # Any install client that parses `requires:` must use this exact
        # grammar, or it silently drops entries a newer pipeline would accept.
        $pattern = '^(?<name>[a-z0-9]+(?:-[a-z0-9]+)*)\s*>=\s*(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)$'
        if ($trimmed -notmatch $pattern) {
            throw "Invalid requires entry '$trimmed'. Expected '<skill-name>>=<semver>', e.g. 'my-skill>=1.0.0'."
        }

        $result += [pscustomobject]@{
            SkillName  = $matches['name']
            MinVersion = $matches['version']
        }
    }

    # Deliberately no leading-comma "force array" wrap here: the pipeline
    # auto-enumerates $result on the way out, and callers normalize back to an
    # array with `@(...)` at the call site (as every consumer of this function
    # does). Wrapping with a leading comma here as well would double-wrap:
    # @() at the call site would then see a single emitted object (the
    # already-wrapped array) instead of its individual elements, turning a
    # 2-entry result into Count 1 and an empty result into Count 1 instead of 0.
    $result
}
