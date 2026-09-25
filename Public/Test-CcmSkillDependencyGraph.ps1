function Test-CcmSkillDependencyGraph {
    <#
    .SYNOPSIS
    Validate the `requires:` declarations of every skill in one repository.

    .DESCRIPTION
    Checks three things and returns every problem at once, so a failing build
    names all of them rather than the first:

      - grammar, via ConvertFrom-CcmSkillRequirement
      - same-repo satisfiability: a required skill that lives in this repo must
        be at or above the declared minimum. This is the check that catches
        "raised the requirement, forgot to bump the dependency", which is
        otherwise invisible until a user installs.
      - cycles: the install client resolves depth-first, and a cycle has no
        valid install order.

    A required skill that is NOT in the map lives in another repository; the
    pipeline checks those against the feed, because only the feed knows.

    .PARAMETER Skill
    Map of skill name -> @{ Version = '<semver>'; Requires = '<raw requires>' }.

    .EXAMPLE
    Test-CcmSkillDependencyGraph -Skill @{
      'my-skill'   = @{ Version = '1.0.0'; Requires = 'base-skill>=1.0.0' }
      'base-skill' = @{ Version = '1.2.0'; Requires = '' }
    }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Skill
    )

    $errors = @()
    $parsed = @{}

    foreach ($name in $Skill.Keys) {
        try {
            $parsed[$name] = @(ConvertFrom-CcmSkillRequirement -Requirement ([string]$Skill[$name].Requires))
        }
        catch {
            $errors += "${name}: $($_.Exception.Message)"
            $parsed[$name] = @()
        }
    }

    foreach ($name in $parsed.Keys) {
        foreach ($dep in $parsed[$name]) {
            if (-not $Skill.ContainsKey($dep.SkillName)) { continue }
            $have = [version](([string]$Skill[$dep.SkillName].Version) -replace '-.*$', '')
            $need = [version]($dep.MinVersion -replace '-.*$', '')
            if ($have -lt $need) {
                $errors += "${name}: requires $($dep.SkillName)>=$($dep.MinVersion) but this repo has $($dep.SkillName)@$($Skill[$dep.SkillName].Version)"
            }
        }
    }

    # A cycle exists exactly when some skill can transitively reach itself.
    # Breadth-first from each node rather than a coloured DFS: the graphs are
    # tiny, and this needs no recursion inside a module function.
    foreach ($start in $parsed.Keys) {
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $queue = [System.Collections.Generic.Queue[string]]::new()
        foreach ($dep in $parsed[$start]) { $queue.Enqueue($dep.SkillName) }

        while ($queue.Count -gt 0) {
            $node = $queue.Dequeue()
            if ($node -eq $start) {
                $errors += "${start}: dependency cycle -- it transitively requires itself"
                break
            }
            if (-not $seen.Add($node)) { continue }
            if ($parsed.ContainsKey($node)) {
                foreach ($dep in $parsed[$node]) { $queue.Enqueue($dep.SkillName) }
            }
        }
    }

    # Bare, not `, $errors` -- callers wrap in `@()`. See Task 1's note.
    $errors
}
