#! /usr/bin/env pwsh

<#

.SYNOPSIS
    setup-azure-devops-iam
    Created By: Stefano Sinigardi
    Created Date: April 18, 2026

.DESCRIPTION
    Generic, portable helper for provisioning the IAM user that an Azure DevOps
    pipeline uses to deploy a containerized application to AWS ECS.

    Reads:
      - ecs-config.json in the project root (for ProjectName, AwsRegion, AwsAccountId, SecretsPrefix, Route53HostedZoneId)
      - deploy/azure-devops-iam-policy.json in the project root (scoped permissions; project-specific)

    Does:
      - Validates the caller's AWS credentials (admin-level SSO session expected)
      - Substitutes placeholders in the policy JSON (${AWS_ACCOUNT_ID}, ${AWS_REGION}, ${PROJECT_NAME}, ${SECRETS_PREFIX}, ${ROUTE53_HOSTED_ZONE_ID})
      - Creates the IAM user (idempotent; re-running against an existing user is safe)
      - Attaches the substituted policy as an inline policy, or as a customer-managed
        policy when it exceeds the IAM user inline-policy size limit
      - Creates a fresh access key (prints to stdout ONCE; cannot be retrieved later)
      - Prints the values the operator must paste into the Azure DevOps variable group

    This script intentionally does NOT write secrets to disk or attempt to push
    them into Azure DevOps automatically - copy/paste is the single trust boundary.

.PARAMETER ConfigFile
    Path to ecs-config.json. Default: auto-detected as ecs-config.json in the project root
    (the parent directory of CCM/).

.PARAMETER PolicyFile
    Path to the scoped IAM policy JSON with placeholders.
    Default: deploy/azure-devops-iam-policy.json in the project root.

.PARAMETER UserName
    IAM user name. Default: "${ProjectName}-azure-devops-deploy".

.PARAMETER PolicyName
    Inline policy name attached to the user. Default: "${ProjectName}-deploy-policy".

.PARAMETER RegenerateAccessKey
    If the user already has an access key, delete it and issue a fresh one.
    Without this switch, an existing key is kept and the script prints a reminder
    that the secret portion cannot be recovered.

.PARAMETER AwsRegion
    Override AWS region. Default: read from ecs-config.json, fallback "eu-central-1".

.PARAMETER AwsAccountId
    Override AWS account ID. Default: auto-detected via `aws sts get-caller-identity`.

.PARAMETER Remove
    Delete the deploy user, its access keys and its policies instead of
    creating them. Use when retiring or renaming a project. Prompts for
    confirmation per deletion (ConfirmImpact 'High', like
    remove-aws-infrastructure.ps1); pass -Confirm:$false for an unattended
    removal, or -WhatIf for a dry run.

    Deletes every access key on the user, every inline policy on the user
    (not only one named $PolicyName - a dedicated deploy user only ever has
    the one this script attached, but if -UserName points at an existing or
    shared identity, ALL of its inline policies are deleted), and the
    customer-managed $PolicyName if that is instead how the policy was
    attached. Which attachment path was used depends on the policy's size at
    creation time, so both are always checked; either, or neither, may be
    present. Does not touch group memberships, a console login profile, MFA
    devices, or SSH public keys - this script only ever creates a
    programmatic (access-key-only) user, so those are out of scope and, if
    present on a repurposed user, are left alone.

    IAM refuses to delete a user that still owns access keys or attached
    policies, so the order is fixed: keys, then policies, then user. Runs
    before the deploy policy file is loaded or validated, so it still works
    when deploy/azure-devops-iam-policy.json is missing or stale - exactly
    the state a project being retired is likely to be in. Every mutating
    call's exit code is checked: "Removal complete." is only printed once
    every step has confirmed success; a failure anywhere prints a "FAILED,
    still present" line instead and exits non-zero; a -WhatIf run instead
    prints "Dry run - nothing was removed." (every mutation is skipped under
    -WhatIf, so it can never itself confirm removal - same reason
    remove-aws-infrastructure.ps1 withholds its own "Nothing remained"
    message under -WhatIf).

    Declining a confirmation prompt is treated the same way, because a
    decline is not a failure and would otherwise slip past the check above:
    each skipped action prints a "SKIPPED" line, and the run ends with
    "INCOMPLETE, still present" and a non-zero exit instead of an all-clear.
    This matters most on a PARTIAL decline - accepting the access-key
    deletion but declining the user deletion leaves a real identity behind,
    and on a full decline nothing is deleted at all. Re-run to finish.

.EXAMPLE
    ./CCM/setup-azure-devops-iam.ps1
    First-time setup: reads ecs-config.json + deploy/azure-devops-iam-policy.json,
    creates the user, attaches the policy, issues an access key.

.EXAMPLE
    ./CCM/setup-azure-devops-iam.ps1 -RegenerateAccessKey
    Rotate the existing access key (e.g., for quarterly rotation).

.EXAMPLE
    ./CCM/setup-azure-devops-iam.ps1 -Remove -WhatIf
    Preview deleting the deploy user, its access keys and its policy.

.NOTES
    This is a generic reusable script. Each project supplies its own
    deploy/azure-devops-iam-policy.json describing the scoped permissions that
    project's pipeline actually needs.

#>

<#
Copyright (c) Stefano Sinigardi

MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED *AS IS*, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
#>

# ConfirmImpact 'High' so -Remove prompts per deletion by default, matching
# remove-aws-infrastructure.ps1 - deleting the deploy identity is no less
# destructive than deleting the stack it deploys. The creation path has no
# ShouldProcess gates, so it never prompts. Unattended removals opt out
# explicitly with -Confirm:$false.
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [string]$PolicyFile,

    [Parameter(Mandatory = $false)]
    [string]$UserName,

    [Parameter(Mandatory = $false)]
    [string]$PolicyName,

    [Parameter(Mandatory = $false)]
    [switch]$RegenerateAccessKey,

    [Parameter(Mandatory = $false)]
    [string]$AwsRegion,

    [Parameter(Mandatory = $false)]
    [string]$AwsAccountId,

    [Parameter(Mandatory = $false)]
    [switch]$Remove
)

$ErrorActionPreference = "Stop"

$setup_azure_devops_iam_ps1_version = "1.0.0"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

if (Test-Path $ScriptDir/utils.psm1) {
    Import-Module -Name $ScriptDir/utils.psm1 -Force
}

# Needed for Get-CcmEcsDeployPolicyGaps below; utils.psm1 also imports the module,
# but this script must work without the legacy shim present.
Import-Module (Join-Path $ScriptDir "CCM.psd1") -Force

Write-Host "setup-azure-devops-iam script version $setup_azure_devops_iam_ps1_version" -ForegroundColor Cyan
Write-Host "Project root: $ProjectRoot"
Write-Host ""

# ---------------------------------------------------------------------------
# Load ecs-config.json
# ---------------------------------------------------------------------------
if (-not $ConfigFile) {
    $ConfigFile = Join-Path $ProjectRoot "ecs-config.json"
}
if (-not (Test-Path $ConfigFile)) {
    throw "ecs-config.json not found at $ConfigFile. Provide -ConfigFile or run from a project using this pattern."
}

Write-Host "Loading project configuration from $ConfigFile" -ForegroundColor Cyan
$fileConfig = Get-Content $ConfigFile -Raw | ConvertFrom-Json

$ProjectName   = $fileConfig.ProjectName
$SecretsPrefix = $fileConfig.SecretsPrefix
$Route53HostedZoneId = $fileConfig.Route53HostedZoneId
if (-not $AwsRegion) { $AwsRegion = $fileConfig.AwsRegion }
if (-not $AwsRegion) { $AwsRegion = "eu-central-1" }

if (-not $ProjectName) {
    throw "ecs-config.json at $ConfigFile is missing 'ProjectName'."
}
if (-not $SecretsPrefix) {
    $SecretsPrefix = $ProjectName
    Write-Host "No SecretsPrefix in config; defaulting to ProjectName ($ProjectName)" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Validate AWS credentials & resolve account id
# ---------------------------------------------------------------------------
if (Get-Command Assert-AwsSsoSession -ErrorAction SilentlyContinue) {
    $identity = Assert-AwsSsoSession -AwsRegion $AwsRegion | ConvertFrom-Json
} else {
    $identityRaw = aws sts get-caller-identity --region $AwsRegion
    if ($LASTEXITCODE -ne 0) {
        throw "aws sts get-caller-identity failed. Run 'aws sso login' (or set AWS access keys) and retry."
    }
    $identity = $identityRaw | ConvertFrom-Json
}

if (-not $AwsAccountId) {
    $AwsAccountId = $identity.Account
}
Write-Host "AWS account: $AwsAccountId" -ForegroundColor Green
Write-Host "AWS region:  $AwsRegion" -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------------------
# Resolve the deploy identity's names, and handle -Remove
# ---------------------------------------------------------------------------
# -Remove must not depend on anything below this point - in particular, not
# on deploy/azure-devops-iam-policy.json existing, or on it passing
# Get-CcmEcsDeployPolicyGaps. Retiring a project is exactly when that file is
# most likely to be missing or stale, and a future required action added to
# the gap check must not start blocking removal of already-provisioned
# projects retroactively. So -Remove is handled here, using only
# $ProjectName/$UserName/$PolicyName/$AwsAccountId, before the policy file is
# ever touched.
if (-not $UserName)   { $UserName   = "$ProjectName-azure-devops-deploy" }
if (-not $PolicyName) { $PolicyName = "$ProjectName-deploy-policy" }

if ($Remove) {
    Write-Host "Removing deploy identity for '$ProjectName'..." -ForegroundColor Yellow

    # Runs `aws <ArgumentList>`, capturing stdout and stderr separately -
    # stderr goes to a temp file rather than through 2>&1, so a real failure
    # is never merged into (or mistaken for) the stdout this branch parses.
    # Mirrors Invoke-CcmAws in remove-aws-infrastructure.ps1.
    #
    # This function is called unconditionally for lookups (list-access-keys,
    # list-user-policies, get-policy, list-policy-versions) even under
    # -WhatIf, so its own bookkeeping must not itself be treated as the
    # action being previewed: both the `2>$errFile` stream redirection and
    # `Remove-Item` below independently honour the caller's $WhatIfPreference
    # (a PowerShell redirection-to-file is itself ShouldProcess-aware), which
    # would otherwise silently skip writing the temp file under -WhatIf and
    # make every real error indistinguishable from "not found" - exactly
    # backwards from the honesty this script is trying to provide. Scoping
    # $WhatIfPreference to $false here affects only that internal plumbing;
    # every actual AWS mutation below is still gated by its own explicit
    # $PSCmdlet.ShouldProcess(...) check, so -WhatIf still prevents every
    # real delete/detach call exactly as before.
    function Invoke-CcmIamCall {
        param([Parameter(Mandatory)][string[]]$ArgumentList)
        $WhatIfPreference = $false
        $errFile = [System.IO.Path]::GetTempFileName()
        try {
            $stdout = & aws @ArgumentList 2>$errFile
            [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                StdOut   = $stdout
                StdErr   = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
            }
        } finally {
            Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue
        }
    }

    # A non-zero exit code alone is not proof the thing is absent - it is
    # also what an expired session or a real AWS-side failure looks like.
    # Only a recognised "does not exist" signal counts as absence.
    function Test-CcmIamNotFound {
        param([string]$StdErr)
        if (-not $StdErr) { return $false }
        $StdErr -match 'NoSuchEntity'
    }

    # Reuse the account id already resolved above rather than re-querying:
    # re-querying would also silently discard an explicit -AwsAccountId.
    $managedPolicyArn = "arn:aws:iam::${AwsAccountId}:policy/$PolicyName"

    # Set whenever a mutating call, or a lookup needed to decide one, fails
    # for a reason other than "does not exist". Checked once at the end to
    # decide whether "Removal complete." would be an honest thing to print -
    # same principle remove-aws-infrastructure.ps1 uses for its closing
    # "Nothing remained" message.
    $hadRemovalError = $false

    # Incremented whenever a ShouldProcess gate says no, which under an
    # interactive run means the operator declined that prompt. A decline is
    # not an error - nothing failed - so $hadRemovalError stays $false, and
    # without tracking it separately a declined run would fall straight
    # through to "Removal complete." That is the worst possible false
    # all-clear on this particular script: decline every prompt and the
    # operator is told the identity is retired while its long-lived static
    # access key is still live and can still deploy. Partial declines are
    # the realistic case too (accept the key deletion, decline the user
    # deletion, leaving an orphaned user behind), so this counts skipped
    # actions rather than being a single "nothing happened" flag.
    $declinedActions = 0

    # 1. Access keys - IAM refuses to delete a user that still owns one.
    $keysLookup = Invoke-CcmIamCall -ArgumentList @(
        "iam", "list-access-keys", "--user-name", $UserName,
        "--query", "AccessKeyMetadata[].AccessKeyId", "--output", "json"
    )
    if ($keysLookup.ExitCode -eq 0) {
        $keyIds = @($keysLookup.StdOut | ConvertFrom-Json)
        if ($keyIds.Count -eq 0) {
            Write-Host "  No access keys on $UserName - skipping" -ForegroundColor DarkGray
        }
        foreach ($keyId in $keyIds) {
            if ($PSCmdlet.ShouldProcess("access key $keyId of $UserName", "Delete")) {
                $delKey = Invoke-CcmIamCall -ArgumentList @("iam", "delete-access-key", "--user-name", $UserName, "--access-key-id", $keyId)
                if ($delKey.ExitCode -eq 0) {
                    Write-Host "  Deleted access key $keyId" -ForegroundColor Green
                } else {
                    Write-Host "  ERROR: failed to delete access key ${keyId}: $($delKey.StdErr)" -ForegroundColor Red
                    $hadRemovalError = $true
                }
            } else {
                Write-Host "  SKIPPED access key $keyId - still live" -ForegroundColor Yellow
                $declinedActions++
            }
        }
    } elseif (Test-CcmIamNotFound -StdErr $keysLookup.StdErr) {
        Write-Host "  No IAM user '$UserName' - skipping key removal" -ForegroundColor DarkGray
    } else {
        Write-Host "  ERROR: list-access-keys failed for ${UserName}: $($keysLookup.StdErr)" -ForegroundColor Red
        $hadRemovalError = $true
    }

    # 2. Inline policies - attached via `put-user-policy` when the policy is
    # small enough (<= the inline size limit) at creation time. This is
    # independent of the managed-policy path in step 3: which one was used
    # depends on policy size, so both must be checked - either, or neither,
    # may be present, and skipping this one leaves the user still owning an
    # attached policy, which makes step 4's delete-user fail. Every inline
    # policy on the user is removed here, not only one named $PolicyName - a
    # dedicated deploy user only ever has the one this script attached, but
    # if -UserName points at an existing/shared identity, all of its inline
    # policies are deleted.
    $inlineLookup = Invoke-CcmIamCall -ArgumentList @(
        "iam", "list-user-policies", "--user-name", $UserName,
        "--query", "PolicyNames[]", "--output", "json"
    )
    if ($inlineLookup.ExitCode -eq 0) {
        $inlineNames = @($inlineLookup.StdOut | ConvertFrom-Json)
        if ($inlineNames.Count -eq 0) {
            Write-Host "  No inline policies on $UserName - skipping" -ForegroundColor DarkGray
        }
        foreach ($inlineName in $inlineNames) {
            if ($PSCmdlet.ShouldProcess("inline policy $inlineName on $UserName", "Delete")) {
                $delInline = Invoke-CcmIamCall -ArgumentList @("iam", "delete-user-policy", "--user-name", $UserName, "--policy-name", $inlineName)
                if ($delInline.ExitCode -eq 0) {
                    Write-Host "  Deleted inline policy $inlineName" -ForegroundColor Green
                } else {
                    Write-Host "  ERROR: failed to delete inline policy ${inlineName}: $($delInline.StdErr)" -ForegroundColor Red
                    $hadRemovalError = $true
                }
            } else {
                Write-Host "  SKIPPED inline policy $inlineName - still attached" -ForegroundColor Yellow
                $declinedActions++
            }
        }
    } elseif (Test-CcmIamNotFound -StdErr $inlineLookup.StdErr) {
        Write-Host "  No IAM user '$UserName' - skipping inline policy removal" -ForegroundColor DarkGray
    } else {
        Write-Host "  ERROR: list-user-policies failed for ${UserName}: $($inlineLookup.StdErr)" -ForegroundColor Red
        $hadRemovalError = $true
    }

    # 3. Managed policy - detach, then delete it and all its versions. "No
    # such managed policy" is a normal absence here (the policy may well
    # have been attached inline instead, per step 2), not a failure.
    $policyLookup = Invoke-CcmIamCall -ArgumentList @("iam", "get-policy", "--policy-arn", $managedPolicyArn)
    if ($policyLookup.ExitCode -eq 0) {
        if ($PSCmdlet.ShouldProcess("$PolicyName from $UserName", "Detach")) {
            $detach = Invoke-CcmIamCall -ArgumentList @("iam", "detach-user-policy", "--user-name", $UserName, "--policy-arn", $managedPolicyArn)
            if ($detach.ExitCode -ne 0 -and -not (Test-CcmIamNotFound -StdErr $detach.StdErr)) {
                Write-Host "  ERROR: failed to detach ${PolicyName}: $($detach.StdErr)" -ForegroundColor Red
                $hadRemovalError = $true
            }
        } else {
            Write-Host "  SKIPPED detaching $PolicyName - still attached" -ForegroundColor Yellow
            $declinedActions++
        }

        $versionsLookup = Invoke-CcmIamCall -ArgumentList @(
            "iam", "list-policy-versions", "--policy-arn", $managedPolicyArn,
            "--query", "Versions[?!IsDefaultVersion].VersionId", "--output", "json"
        )
        if ($versionsLookup.ExitCode -eq 0) {
            foreach ($v in @($versionsLookup.StdOut | ConvertFrom-Json)) {
                if ($PSCmdlet.ShouldProcess("$PolicyName version $v", "Delete")) {
                    $delVersion = Invoke-CcmIamCall -ArgumentList @("iam", "delete-policy-version", "--policy-arn", $managedPolicyArn, "--version-id", $v)
                    if ($delVersion.ExitCode -ne 0) {
                        Write-Host "  ERROR: failed to delete ${PolicyName} version ${v}: $($delVersion.StdErr)" -ForegroundColor Red
                        $hadRemovalError = $true
                    }
                } else {
                    Write-Host "  SKIPPED $PolicyName version $v - still present" -ForegroundColor Yellow
                    $declinedActions++
                }
            }
        } elseif (-not (Test-CcmIamNotFound -StdErr $versionsLookup.StdErr)) {
            Write-Host "  ERROR: list-policy-versions failed for ${PolicyName}: $($versionsLookup.StdErr)" -ForegroundColor Red
            $hadRemovalError = $true
        }

        if ($PSCmdlet.ShouldProcess($PolicyName, "Delete policy")) {
            $delPolicy = Invoke-CcmIamCall -ArgumentList @("iam", "delete-policy", "--policy-arn", $managedPolicyArn)
            if ($delPolicy.ExitCode -ne 0 -and -not (Test-CcmIamNotFound -StdErr $delPolicy.StdErr)) {
                Write-Host "  ERROR: failed to delete policy ${PolicyName}: $($delPolicy.StdErr)" -ForegroundColor Red
                $hadRemovalError = $true
            }
        } else {
            Write-Host "  SKIPPED deleting policy $PolicyName - still present" -ForegroundColor Yellow
            $declinedActions++
        }
    } elseif (Test-CcmIamNotFound -StdErr $policyLookup.StdErr) {
        Write-Host "  No managed policy $PolicyName - skipping (may have been attached inline instead)" -ForegroundColor DarkGray
    } else {
        Write-Host "  ERROR: get-policy failed for ${PolicyName}: $($policyLookup.StdErr)" -ForegroundColor Red
        $hadRemovalError = $true
    }

    # 4. The user itself - IAM refuses this while any key or policy from
    # steps 1-3 is still attached, so a failure here almost always means one
    # of those was missed rather than a new problem.
    if ($PSCmdlet.ShouldProcess($UserName, "Delete user")) {
        $deleteUser = Invoke-CcmIamCall -ArgumentList @("iam", "delete-user", "--user-name", $UserName)
        if ($deleteUser.ExitCode -ne 0 -and -not (Test-CcmIamNotFound -StdErr $deleteUser.StdErr)) {
            Write-Host "  ERROR: failed to delete user ${UserName}: $($deleteUser.StdErr)" -ForegroundColor Red
            $hadRemovalError = $true
        }
    } else {
        Write-Host "  SKIPPED user $UserName - still present" -ForegroundColor Yellow
        $declinedActions++
    }

    if ($hadRemovalError) {
        Write-Host ""
        Write-Host "FAILED, still present: one or more resources for '$ProjectName' were not removed - see the ERROR line(s) above. Resolve them and re-run before treating this identity as retired." -ForegroundColor Red
        exit 1
    }

    # Every mutating call above is gated by ShouldProcess, so under -WhatIf
    # none of them ran - $hadRemovalError being $false here only means
    # nothing was ATTEMPTED, not that anything was actually removed.
    # Printing "Removal complete." in that case would be exactly the false
    # all-clear remove-aws-infrastructure.ps1 already guards against for the
    # same reason.
    if ($WhatIfPreference) {
        Write-Host "Dry run - nothing was removed." -ForegroundColor Cyan
        exit 0
    }

    # Must come AFTER the -WhatIf check: -WhatIf drives every ShouldProcess
    # gate false too, so $declinedActions is at its maximum on a dry run.
    # Reaching here with declines means an interactive operator answered no
    # to at least one prompt while the rest of the run really did delete
    # things. Nothing FAILED, so the error path above did not fire - but the
    # identity is not retired either, and saying "Removal complete." would
    # tell the operator that the access key they just declined to delete is
    # gone. Exit non-zero for the same reason the failure path does: text is
    # not machine-readable, and anything scripting this (a runbook, CI) must
    # not read a partial removal as a finished one.
    if ($declinedActions -gt 0) {
        Write-Host ""
        Write-Host "INCOMPLETE, still present: $declinedActions action(s) declined at the prompt - see the SKIPPED line(s) above. This identity is NOT retired, and a declined access key is still live and can still deploy. Re-run to finish, or re-run with -Confirm:`$false to remove everything without prompting." -ForegroundColor Red
        exit 1
    }

    Write-Host "Removal complete. Clear the Azure DevOps variable group's credentials too - they are now dead." -ForegroundColor Cyan
    exit 0
}

# ---------------------------------------------------------------------------
# Load & substitute the policy JSON
# ---------------------------------------------------------------------------
if (-not $PolicyFile) {
    $PolicyFile = Join-Path $ProjectRoot "deploy/azure-devops-iam-policy.json"
}
if (-not (Test-Path $PolicyFile)) {
    throw "IAM policy file not found at $PolicyFile. Create deploy/azure-devops-iam-policy.json with the project-specific scoped permissions."
}

Write-Host "Loading IAM policy from $PolicyFile" -ForegroundColor Cyan
$policyRaw = Get-Content $PolicyFile -Raw

# Match the ${VAR} placeholder style used by deploy/ecs/task-definition-live.json.
$policyRaw = $policyRaw -replace '\$\{AWS_ACCOUNT_ID\}', $AwsAccountId
$policyRaw = $policyRaw -replace '\$\{AWS_REGION\}',     $AwsRegion
$policyRaw = $policyRaw -replace '\$\{PROJECT_NAME\}',   $ProjectName
$policyRaw = $policyRaw -replace '\$\{SECRETS_PREFIX\}', $SecretsPrefix
$policyRaw = $policyRaw -replace '\$\{ROUTE53_HOSTED_ZONE_ID\}', $Route53HostedZoneId

# Parse and re-serialize to: (a) validate JSON, (b) strip the _comment field IAM won't accept.
try {
    $policyObj = $policyRaw | ConvertFrom-Json
} catch {
    throw "Policy file is not valid JSON after substitution: $($_.Exception.Message)"
}
if ($policyObj.PSObject.Properties.Name -contains '_comment') {
    $policyObj.PSObject.Properties.Remove('_comment')
}
$policyJson = $policyObj | ConvertTo-Json -Depth 20 -Compress
$policySizeBytes = [System.Text.Encoding]::UTF8.GetByteCount($policyJson)
$inlinePolicyLimitBytes = 2048
$managedPolicyLimitBytes = 6144
if ($policySizeBytes -gt $managedPolicyLimitBytes) {
    throw "IAM policy is $policySizeBytes bytes after compaction, which exceeds the managed policy limit of $managedPolicyLimitBytes bytes. Split deploy/azure-devops-iam-policy.json into smaller policies."
}

# ---------------------------------------------------------------------------
# Validate the policy grants what this project's enabled ecs-config.json
# features actually need, BEFORE attaching it. Some actions (e.g. the
# Resource Groups Tagging API call in cleanup-ecs-previews.ps1) are only
# exercised by a daily cron - a missing grant there fails silently for weeks
# instead of at the next pipeline run. Fail loudly here instead.
# ---------------------------------------------------------------------------
$policyGaps = Get-CcmEcsDeployPolicyGaps -PolicyObject $policyObj -Config $fileConfig

if ($policyGaps.MissingRecommended.Count -gt 0) {
    # Only reachable through an optional switch (-RunMigrations, -SkipBuild), so
    # warn rather than block: requiring these would reject policies that are
    # correct for projects that never use those switches.
    Write-Host ""
    Write-Host "Policy validation: $PolicyFile does not grant these optional action(s):" -ForegroundColor Yellow
    foreach ($m in $policyGaps.MissingRecommended) { Write-Host "  - $m" -ForegroundColor Yellow }
    Write-Host "  Add them if this project uses those switches." -ForegroundColor Yellow
}
if ($policyGaps.Missing.Count -gt 0) {
    Write-Host ""
    Write-Host "Policy validation FAILED - $PolicyFile does not grant:" -ForegroundColor Red
    foreach ($m in $policyGaps.Missing) { Write-Host "  - $m" -ForegroundColor Red }
    Write-Host ""
    throw "Refusing to attach an incomplete IAM policy. Add the missing action(s) above to $PolicyFile, then re-run this script."
}
Write-Host "Policy validation passed: all $($policyGaps.RequiredCount) required action(s) are granted." -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------------------
# Create or update the IAM user
# ---------------------------------------------------------------------------
Write-Host "IAM user name:   $UserName" -ForegroundColor Cyan
Write-Host "IAM policy name: $PolicyName" -ForegroundColor Cyan
Write-Host ""

$userExists = $false
$getUser = aws iam get-user --user-name $UserName 2>&1
if ($LASTEXITCODE -eq 0) {
    $userExists = $true
    Write-Host "User $UserName already exists; updating policy" -ForegroundColor Yellow
} else {
    Write-Host "Creating IAM user $UserName..." -ForegroundColor Yellow
    aws iam create-user --user-name $UserName --tags "Key=ManagedBy,Value=CCM" "Key=Project,Value=$ProjectName" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "aws iam create-user failed for $UserName"
    }
    Write-Host "Created user $UserName" -ForegroundColor Green
}

# Attach the policy. IAM user inline policies are limited to 2048 bytes, so larger
# deploy policies are attached as customer-managed policies instead.
$tmpPolicyFile = [System.IO.Path]::GetTempFileName()
try {
    Set-Content -Path $tmpPolicyFile -Value $policyJson -Encoding UTF8
    Write-Host "Policy size: $policySizeBytes bytes" -ForegroundColor Cyan

    if ($policySizeBytes -le $inlinePolicyLimitBytes) {
        Write-Host "Attaching inline policy $PolicyName..." -ForegroundColor Yellow
        aws iam put-user-policy `
            --user-name $UserName `
            --policy-name $PolicyName `
            --policy-document "file://$tmpPolicyFile" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "aws iam put-user-policy failed"
        }
    } else {
        $managedPolicyArn = "arn:aws:iam::${AwsAccountId}:policy/$PolicyName"
        Write-Host "Policy exceeds inline limit; using customer-managed policy $managedPolicyArn" -ForegroundColor Yellow

        $existingPolicyRaw = aws iam get-policy --policy-arn $managedPolicyArn --output json 2>$null
        if ($LASTEXITCODE -eq 0 -and $existingPolicyRaw) {
            $versionsRaw = aws iam list-policy-versions --policy-arn $managedPolicyArn --output json
            if ($LASTEXITCODE -ne 0) {
                throw "aws iam list-policy-versions failed for $managedPolicyArn"
            }
            $versions = @((($versionsRaw | ConvertFrom-Json).Versions))
            if ($versions.Count -ge 5) {
                $oldestNonDefault = $versions |
                    Where-Object { -not $_.IsDefaultVersion } |
                    Sort-Object CreateDate |
                    Select-Object -First 1
                if (-not $oldestNonDefault) {
                    throw "Managed policy $managedPolicyArn has no deletable non-default versions."
                }
                Write-Host "Deleting old managed policy version $($oldestNonDefault.VersionId)..." -ForegroundColor Yellow
                aws iam delete-policy-version `
                    --policy-arn $managedPolicyArn `
                    --version-id $oldestNonDefault.VersionId | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "aws iam delete-policy-version failed for $managedPolicyArn"
                }
            }

            Write-Host "Creating new managed policy version..." -ForegroundColor Yellow
            aws iam create-policy-version `
                --policy-arn $managedPolicyArn `
                --policy-document "file://$tmpPolicyFile" `
                --set-as-default | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "aws iam create-policy-version failed for $managedPolicyArn"
            }
        } else {
            Write-Host "Creating managed policy $PolicyName..." -ForegroundColor Yellow
            $createdPolicyRaw = aws iam create-policy `
                --policy-name $PolicyName `
                --policy-document "file://$tmpPolicyFile" `
                --tags "Key=ManagedBy,Value=CCM" "Key=Project,Value=$ProjectName" `
                --output json
            if ($LASTEXITCODE -ne 0) {
                throw "aws iam create-policy failed for $PolicyName"
            }
            $managedPolicyArn = ($createdPolicyRaw | ConvertFrom-Json).Policy.Arn
        }

        Write-Host "Attaching managed policy to $UserName..." -ForegroundColor Yellow
        aws iam attach-user-policy `
            --user-name $UserName `
            --policy-arn $managedPolicyArn | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "aws iam attach-user-policy failed for $managedPolicyArn"
        }

        aws iam delete-user-policy --user-name $UserName --policy-name $PolicyName 2>$null | Out-Null
        $LASTEXITCODE = 0
    }
    Write-Host "Policy attached" -ForegroundColor Green
} finally {
    Remove-Item -Path $tmpPolicyFile -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Manage access keys
# ---------------------------------------------------------------------------
$existingKeysRaw = aws iam list-access-keys --user-name $UserName
if ($LASTEXITCODE -ne 0) {
    throw "aws iam list-access-keys failed for $UserName"
}
$existingKeys = ($existingKeysRaw | ConvertFrom-Json).AccessKeyMetadata

$shouldCreateKey = $false
if ($existingKeys.Count -eq 0) {
    $shouldCreateKey = $true
    Write-Host "No existing access keys; creating one..." -ForegroundColor Yellow
} elseif ($RegenerateAccessKey) {
    Write-Host "-RegenerateAccessKey set; deleting existing key(s)..." -ForegroundColor Yellow
    foreach ($k in $existingKeys) {
        aws iam delete-access-key --user-name $UserName --access-key-id $k.AccessKeyId | Out-Null
        Write-Host "Deleted access key $($k.AccessKeyId)" -ForegroundColor Yellow
    }
    $shouldCreateKey = $true
} else {
    Write-Host ""
    Write-Host "User already has $($existingKeys.Count) active access key(s). The secret portion" -ForegroundColor Yellow
    Write-Host "of an AWS access key can only be retrieved at creation time - if you have lost it," -ForegroundColor Yellow
    Write-Host "re-run with -RegenerateAccessKey to issue a fresh one." -ForegroundColor Yellow
    foreach ($k in $existingKeys) {
        Write-Host "  - $($k.AccessKeyId) (created $($k.CreateDate))" -ForegroundColor Yellow
    }
}

if ($shouldCreateKey) {
    $newKeyRaw = aws iam create-access-key --user-name $UserName
    if ($LASTEXITCODE -ne 0) {
        throw "aws iam create-access-key failed"
    }
    $newKey = ($newKeyRaw | ConvertFrom-Json).AccessKey

    Write-Host ""
    Write-Host "=================================================================" -ForegroundColor Green
    Write-Host "  Access key created. Copy these values NOW - the secret will NOT" -ForegroundColor Green
    Write-Host "  be shown again and cannot be retrieved later." -ForegroundColor Green
    Write-Host "=================================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  AWS_ACCESS_KEY_ID     = $($newKey.AccessKeyId)"     -ForegroundColor Cyan
    Write-Host "  AWS_SECRET_ACCESS_KEY = $($newKey.SecretAccessKey)" -ForegroundColor Cyan
    Write-Host "  AWS_DEFAULT_REGION    = $AwsRegion"                 -ForegroundColor Cyan
    Write-Host "  AWS_ACCOUNT_ID        = $AwsAccountId"              -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Paste the four values above into Azure DevOps:" -ForegroundColor Yellow
    Write-Host "  Project Settings -> Pipelines -> Library -> Variable groups"     -ForegroundColor Yellow
    Write-Host "  -> create group '$ProjectName-deploy'"                           -ForegroundColor Yellow
    Write-Host "  -> mark AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY as 'secret'" -ForegroundColor Yellow
    Write-Host "  -> authorize the group for the pipeline that uses it"            -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "Done." -ForegroundColor Green
