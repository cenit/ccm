# Pester tests for setup-route53-zone.ps1's -IncludeApex option.
BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot ".." "setup-route53-zone.ps1"
    $script:ScriptText = Get-Content $script:ScriptPath -Raw
}

Describe "setup-route53-zone.ps1 -IncludeApex" {
    It "declares an IncludeApex switch parameter" {
        $script:ScriptText | Should -Match '\[switch\]\$IncludeApex'
    }

    It "documents the parameter" {
        $script:ScriptText | Should -Match '\.PARAMETER IncludeApex'
    }

    It "passes the apex as a subject alternative name when the switch is set" {
        $script:ScriptText | Should -Match 'subject-alternative-names'
    }

    It "still requests the wildcard as the primary domain name" {
        $script:ScriptText | Should -Match '--domain-name'
        $script:ScriptText | Should -Match '"\*\.\$ParentDomain"'
    }

    It "iterates every DomainValidationOptions entry, not just the first" {
        # A two-name certificate produces two validation records. Indexing [0]
        # would validate the wildcard and silently leave the apex pending.
        $script:ScriptText | Should -Not -Match 'DomainValidationOptions\[0\]'
        $script:ScriptText | Should -Match 'foreach.*DomainValidationOptions'
    }

    It "parses as valid PowerShell" {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$null, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }
}

Describe "setup-route53-zone.ps1 ACM validation-record polling" {
    # ACM does not always populate DomainValidationOptions[*].ResourceRecord
    # immediately after request-certificate returns. A fixed 3-second sleep
    # was observed in production to be too short: it produced zero validation
    # CNAMEs and no diagnostic, silently leaving the certificate stuck at
    # PENDING_VALIDATION. It must be replaced with a bounded poll.

    It "no longer uses the fixed 3-second sleep before reading validation records" {
        $script:ScriptText | Should -Not -Match 'Start-Sleep\s+-Seconds\s+3\b'
    }

    It "polls describe-certificate in a bounded loop until ResourceRecord is populated" {
        # Must be distinguishable from the pre-existing Step 4 issuance-wait
        # loop, which also loops on describe-certificate but only ever checks
        # Certificate.Status, never ResourceRecord/DomainValidationOptions.
        $script:ScriptText | Should -Match '(?s)\b(for|while)\b\s*\([^)]*[Aa]ttempt[^)]*\)\s*\{[^}]*describe-certificate[^}]*ResourceRecord'
    }

    It "fails with a message naming the certificate ARN when validation records never appear" {
        $script:ScriptText | Should -Match '(?s)\$\w*[Pp]opulated\w*\)\s*\{[^}]*certificateArn'
    }

    It "tells the user re-running the script is safe and will reuse the existing certificate" {
        $script:ScriptText | Should -Match '(?i)re-running this script is safe'
    }

    It "exits non-zero (rather than silently continuing) when validation records time out" {
        $script:ScriptText | Should -Match '(?s)\$\w*[Pp]opulated\w*\)\s*\{[^}]*exit\s+1'
    }

    It "still iterates every DomainValidationOptions entry to write each record with UPSERT" {
        # The poll must not replace the existing per-entry record creation;
        # a wildcard and its apex can validate with the identical record name,
        # so CREATE would fail on the duplicate.
        $script:ScriptText | Should -Match 'foreach.*DomainValidationOptions'
        $script:ScriptText | Should -Match '(?i)"UPSERT"'
    }
}
