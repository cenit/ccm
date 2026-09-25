BeforeAll {
    $script:RepoRoot     = Split-Path -Parent $PSScriptRoot
    $script:ManifestPath = Join-Path $script:RepoRoot 'CCM.psd1'
    $script:ChangelogDir = Join-Path $script:RepoRoot 'changelog.d'

    # Import-PowerShellDataFile, not Import-Module: this has to read the version
    # the manifest DECLARES, and importing would make a broken manifest fail as
    # a module-load error somewhere else instead of as a version assertion here.
    $script:Version = [version](Import-PowerShellDataFile -Path $script:ManifestPath).ModuleVersion

    # README.md documents the convention and is not an entry. Anything else in
    # here is one, including a file whose name does not parse -- that is a
    # finding rather than something to filter away.
    $script:EntryFiles = @(
        Get-ChildItem -Path $script:ChangelogDir -Filter '*.md' -File |
            Where-Object { $_.BaseName -ne 'README' }
    )
}

# Why a file per version rather than a lint on the manifest: a version collision
# is invisible to code review AND to git. Three PRs once each bumped 1.35.0 to
# 1.36.0, and all three merged clean, because git only reports a conflict when
# the two sides DIFFER -- and every side had written the same string to the same
# line. No assertion about a single file's contents can see a second PR.
#
# What can: making both PRs create the SAME PATH with different content. That is
# an add/add conflict, which git refuses to merge and no rebase quietly resolves.
# The tests below exist to guarantee that both PRs really do create it.
Describe 'version and changelog.d' {
    It 'ships a changelog entry for the version the manifest declares' {
        # The load-bearing one. Without it a PR can bump the manifest and add no
        # file, which puts the collision back exactly where it was.
        $expected = Join-Path $script:ChangelogDir "$($script:Version).md"
        Test-Path -Path $expected | Should -BeTrue -Because @"
CCM.psd1 declares $($script:Version) but changelog.d/$($script:Version).md does not exist.
Add it -- a heading and a few lines is enough. It is what makes two PRs choosing
the same version collide in git instead of merging silently. See changelog.d/README.md.
"@
    }

    It 'names every entry after a version, so the directory can be ordered' {
        # An entry called `dropzone.md` or `1.38.md` sorts nowhere and silently
        # drops out of the highest-version check below, taking that check's
        # meaning with it.
        $unparseable = @(
            $script:EntryFiles | Where-Object {
                $parsed = $null
                -not [version]::TryParse($_.BaseName, [ref]$parsed)
            } | ForEach-Object { $_.Name }
        )
        $unparseable | Should -BeNullOrEmpty
    }

    It 'keeps the manifest at the highest version any entry describes' {
        # The other direction, and the one a reviewer is least likely to notice:
        # an entry added for 1.39.0 while the manifest still says 1.38.0 means
        # the bump was forgotten, and the release ships under the previous
        # number. Without this, the test above would still pass.
        $versions = @(
            $script:EntryFiles | ForEach-Object {
                $parsed = $null
                if ([version]::TryParse($_.BaseName, [ref]$parsed)) { $parsed }
            }
        )
        $versions | Should -Not -BeNullOrEmpty -Because 'changelog.d must hold at least one entry'
        $highest = ($versions | Sort-Object -Descending)[0]
        $script:Version | Should -Be $highest
    }

    It 'gives every entry a heading naming its own version' {
        # Stops the requirement being satisfied by an empty file. The heading has
        # to match the filename, so a copy-pasted entry from the previous release
        # is caught rather than counted.
        $mismatched = @(
            foreach ($file in $script:EntryFiles) {
                $first = (Get-Content -Path $file.FullName -TotalCount 1)
                if ($first -notmatch "^#\s+$([regex]::Escape($file.BaseName))\s*$") { $file.Name }
            }
        )
        $mismatched | Should -BeNullOrEmpty
    }
}
