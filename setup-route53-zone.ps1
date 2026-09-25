#! /usr/bin/env pwsh

<#

.SYNOPSIS
    setup-route53-zone
    Created By: Stefano Sinigardi
    Created Date: March 13, 2026

.DESCRIPTION
    One-time setup script for Route 53 DNS zone delegation and wildcard TLS certificate.

    This script:
      1. Creates a Route 53 hosted zone for the parent domain (e.g., apps.example.com)
      2. Displays the NS records to send to IT for delegation
      3. Requests a wildcard ACM certificate (*.apps.example.com)
      4. Creates the DNS validation record in Route 53
      5. Waits for the certificate to be issued
      6. Outputs the hosted zone ID and certificate ARN for ecs-config.json

    After running this script, IT must add the NS records to the corporate DNS.
    Once that is done, all *.apps.example.com subdomains are managed in Route 53
    and covered by the wildcard certificate.

    This script is idempotent:
      - If the hosted zone already exists, it reuses it
      - If the certificate already exists, it reuses it
      - If the validation record already exists, it skips creation

    Prerequisites:
      - AWS CLI configured with admin credentials
      - A parent domain agreed with IT (e.g., apps.example.com)

.PARAMETER ParentDomain
    The parent domain for all PoC subdomains (required)
    Example: "apps.example.com"

.PARAMETER AwsRegion
    AWS region for ACM certificate. Default: "eu-central-1"
    Note: ACM certificates for ALBs must be in the same region as the ALB.

.PARAMETER SkipCertificate
    Skip requesting the wildcard ACM certificate.
    Use this if you only want to create the hosted zone and get the NS records.

.PARAMETER IncludeApex
    Also cover the zone apex (e.g. my-app.example.com itself, not just
    *.my-app.example.com) by requesting it as a subject alternative name.
    Default: off.

    An ACM certificate cannot be amended after issuance, so adding the apex
    later means requesting a second certificate and re-pointing every
    listener that uses this one. If a portal or landing page at the apex is
    even plausible, it is much cheaper to include it now.

.PARAMETER WaitForCertificate
    Wait for the certificate to be issued (up to 10 minutes).
    Default: true. Set -WaitForCertificate:$false to skip waiting.
    The certificate will only be issued after IT adds the NS records.

.PARAMETER ConfigFile
    Path to ecs-config.json to auto-update with the hosted zone ID and certificate ARN.
    Default: auto-detected as ecs-config.json in the project root (parent of CCM/).

.EXAMPLE
    .\CCM\setup-route53-zone.ps1 -ParentDomain "apps.example.com"
    Create hosted zone and wildcard certificate for apps.example.com

.EXAMPLE
    .\CCM\setup-route53-zone.ps1 -ParentDomain "apps.example.com" -SkipCertificate
    Create hosted zone only, get NS records to send to IT

.EXAMPLE
    .\CCM\setup-route53-zone.ps1 -ParentDomain "apps.example.com" -WaitForCertificate:$false
    Create hosted zone and request certificate, but don't wait for issuance

.NOTES
    This is a one-time setup script. Run it once per organization/team.
    After running, update ecs-config.json in each project with the output values.

    The NS records must be added by IT to the corporate DNS before:
      - DNS validation for the ACM certificate will succeed

    The wildcard certificate (*.apps.example.com) covers all first-level subdomains.
    It does NOT cover the bare domain (apps.example.com) or deeper subdomains
    (e.g., foo.bar.apps.example.com).

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

param(
    [Parameter(Mandatory = $true)]
    [string]$ParentDomain,

    [Parameter(Mandatory = $false)]
    [string]$AwsRegion = "eu-central-1",

    [Parameter(Mandatory = $false)]
    [switch]$SkipCertificate,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeApex,

    [Parameter(Mandatory = $false)]
    [bool]$WaitForCertificate = $true,

    [Parameter(Mandatory = $false)]
    [string]$ConfigFile
)

$ErrorActionPreference = "Stop"

# Auto-detect script directory and project root
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

# Import shared utilities
if (Test-Path $ScriptDir/utils.psm1) {
    Import-Module -Name $ScriptDir/utils.psm1 -Force
}

# Validate AWS credentials
Assert-AwsSsoSession -AwsRegion $AwsRegion

# Strip trailing dots from domain
$ParentDomain = $ParentDomain.TrimEnd('.')

Write-Host ""
Write-Host "=== Route 53 Zone Setup ===" -ForegroundColor Cyan
Write-Host "Parent domain: $ParentDomain"
Write-Host "Region:        $AwsRegion"
Write-Host ""

# =========================================================================
# Step 1: Create (or find) Route 53 hosted zone
# =========================================================================
Write-Host "1. Creating Route 53 hosted zone for '$ParentDomain'..." -ForegroundColor Yellow

# Check if the hosted zone already exists
$existingZones = aws route53 list-hosted-zones-by-name `
    --dns-name "$ParentDomain." `
    --max-items 1 `
    --region $AwsRegion `
    --output json | ConvertFrom-Json

$hostedZoneId = $null
if ($existingZones.HostedZones.Count -gt 0) {
    $zone = $existingZones.HostedZones[0]
    # Exact match check (list-hosted-zones-by-name returns >= matches)
    if ($zone.Name -eq "$ParentDomain.") {
        $hostedZoneId = ($zone.Id -split '/')[-1]  # Extract ID from /hostedzone/ZXXXXX
        Write-Host "  Hosted zone already exists: $hostedZoneId" -ForegroundColor Green
    }
}

if (-not $hostedZoneId) {
    $callerRef = "setup-route53-$(Get-Date -Format yyyyMMddHHmmss)"
    $createResult = aws route53 create-hosted-zone `
        --name "$ParentDomain" `
        --caller-reference $callerRef `
        --output json | ConvertFrom-Json

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Failed to create hosted zone" -ForegroundColor Red
        exit 1
    }

    $hostedZoneId = ($createResult.HostedZone.Id -split '/')[-1]
    Write-Host "  Hosted zone created: $hostedZoneId" -ForegroundColor Green
}

# Get the NS records
$nsRecords = aws route53 get-hosted-zone `
    --id $hostedZoneId `
    --output json | ConvertFrom-Json

$nameServers = $nsRecords.DelegationSet.NameServers

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "  NS RECORDS - Send these to IT for DNS delegation:" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Ask IT to add these NS records for '$ParentDomain':" -ForegroundColor Yellow
Write-Host ""
foreach ($ns in $nameServers) {
    Write-Host "    $ParentDomain  NS  $ns" -ForegroundColor White
}
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ""

# =========================================================================
# Step 2: Request wildcard ACM certificate
# =========================================================================
$certificateArn = $null

if (-not $SkipCertificate) {
    Write-Host "2. Requesting wildcard ACM certificate for '*.$ParentDomain'..." -ForegroundColor Yellow

    # Check if a wildcard cert already exists
    $existingCerts = aws acm list-certificates `
        --region $AwsRegion `
        --query "CertificateSummaryList[?DomainName=='*.$ParentDomain']" `
        --output json | ConvertFrom-Json

    if ($existingCerts.Count -gt 0) {
        # Find one that is ISSUED or PENDING_VALIDATION (not EXPIRED/REVOKED)
        $usableCert = $existingCerts | Where-Object {
            $_.Status -eq "ISSUED" -or $_.Status -eq "PENDING_VALIDATION"
        } | Select-Object -First 1

        if ($usableCert) {
            # For PS5 compatibility: handle both property name styles
            $certificateArn = if ($usableCert.CertificateArn) { $usableCert.CertificateArn } else { $usableCert.certificateArn }
            $certStatus = if ($usableCert.Status) { $usableCert.Status } else { $usableCert.status }
            Write-Host "  Wildcard certificate already exists: $certificateArn (status: $certStatus)" -ForegroundColor Green
        }
    }

    if (-not $certificateArn) {
        $requestArgs = @(
            'acm', 'request-certificate',
            '--domain-name', "*.$ParentDomain",
            '--validation-method', 'DNS',
            '--region', $AwsRegion,
            '--query', 'CertificateArn',
            '--output', 'text'
        )
        if ($IncludeApex) {
            # Insert after --domain-name's value so the CLI groups it correctly.
            $requestArgs += @('--subject-alternative-names', $ParentDomain)
            Write-Host "  Including the zone apex '$ParentDomain' as a subject alternative name" -ForegroundColor Cyan
        }
        $certificateArn = aws @requestArgs

        if ($LASTEXITCODE -ne 0) {
            Write-Host "  Failed to request certificate" -ForegroundColor Red
            exit 1
        }
        Write-Host "  Certificate requested: $certificateArn" -ForegroundColor Green
    }

    # =========================================================================
    # Step 3: Create DNS validation record in Route 53
    # =========================================================================
    Write-Host "3. Creating DNS validation record..." -ForegroundColor Yellow

    # Poll ACM until every DomainValidationOptions entry has a populated
    # ResourceRecord. ACM does not always populate it immediately after
    # request-certificate returns; a fixed short sleep was tried here before
    # and was observed in production to be too short, silently leaving
    # ResourceRecord empty for every entry with no explanation. In practice
    # ACM populates it within a few seconds, so 2-second intervals for up to
    # 60 seconds (30 attempts) both catches the normal case quickly and gives
    # a genuinely slow response room, without hanging indefinitely on a
    # request that will never resolve.
    $acmPollIntervalSeconds = 2
    $acmPollMaxAttempts = 30  # 30 * 2s = 60 seconds
    $certDetails = $null

    for ($acmPollAttempt = 1; $acmPollAttempt -le $acmPollMaxAttempts; $acmPollAttempt++) {
        $certDetails = aws acm describe-certificate `
            --certificate-arn $certificateArn `
            --region $AwsRegion `
            --output json | ConvertFrom-Json

        $validationOptions = @($certDetails.Certificate.DomainValidationOptions)
        $allPopulated = ($validationOptions.Count -gt 0) -and `
            (-not ($validationOptions | Where-Object { -not $_.ResourceRecord }))

        if ($allPopulated) {
            break
        }

        if ($acmPollAttempt -lt $acmPollMaxAttempts) {
            Start-Sleep -Seconds $acmPollIntervalSeconds
        }
    }

    if (-not $allPopulated) {
        Write-Host ""
        Write-Host "  ERROR: ACM did not publish DNS validation records for certificate" -ForegroundColor Red
        Write-Host "  $certificateArn" -ForegroundColor Red
        Write-Host "  within $($acmPollMaxAttempts * $acmPollIntervalSeconds) seconds." -ForegroundColor Red
        Write-Host "  Re-running this script is safe: it will reuse this certificate instead of" -ForegroundColor Red
        Write-Host "  requesting a new one." -ForegroundColor Red
        exit 1
    }

    $pendingCount = 0

    foreach ($validationOption in @($certDetails.Certificate.DomainValidationOptions)) {
        if (-not $validationOption.ResourceRecord) {
            $pendingCount++
            continue
        }

        $validationName = $validationOption.ResourceRecord.Name
        $validationValue = $validationOption.ResourceRecord.Value

        Write-Host "  Validation record for $($validationOption.DomainName): $validationName -> $validationValue" -ForegroundColor Cyan

        $existingRecords = aws route53 list-resource-record-sets `
            --hosted-zone-id $hostedZoneId `
            --query "ResourceRecordSets[?Name=='$validationName' && Type=='CNAME']" `
            --output json | ConvertFrom-Json

        if ($existingRecords.Count -gt 0) {
            Write-Host "    Already exists in Route 53" -ForegroundColor Green
            continue
        }

        $changeBatch = @{
            Changes = @(@{
                Action = "UPSERT"
                ResourceRecordSet = @{
                    Name = $validationName
                    Type = "CNAME"
                    TTL = 300
                    ResourceRecords = @(@{ Value = $validationValue })
                }
            })
        } | ConvertTo-Json -Depth 5 -Compress

        $tempFile = [System.IO.Path]::GetTempFileName()
        $changeBatch | Set-Content $tempFile

        aws route53 change-resource-record-sets `
            --hosted-zone-id $hostedZoneId `
            --change-batch "file://$tempFile" | Out-Null

        Remove-Item $tempFile

        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Created in Route 53" -ForegroundColor Green
        } else {
            Write-Host "    WARNING: Could not create validation record" -ForegroundColor Yellow
        }
    }

    if ($pendingCount -gt 0) {
        Write-Host "  $pendingCount validation record(s) not yet available from ACM (they appear after NS delegation)" -ForegroundColor Yellow
    }

    # =========================================================================
    # Step 4: Wait for certificate issuance (optional)
    # =========================================================================
    $certStatus = $certDetails.Certificate.Status
    if ($certStatus -eq "ISSUED") {
        Write-Host "4. Certificate already issued" -ForegroundColor Green
    } elseif ($WaitForCertificate) {
        Write-Host "4. Waiting for certificate issuance..." -ForegroundColor Yellow
        Write-Host "   (This requires IT to have completed NS delegation." -ForegroundColor Yellow
        Write-Host "    Press Ctrl+C to stop waiting and come back later.)" -ForegroundColor Yellow

        $maxAttempts = 30  # 30 * 20s = 10 minutes
        $attempt = 0
        while ($attempt -lt $maxAttempts) {
            $attempt++
            $checkStatus = aws acm describe-certificate `
                --certificate-arn $certificateArn `
                --region $AwsRegion `
                --query 'Certificate.Status' `
                --output text

            if ($checkStatus -eq "ISSUED") {
                Write-Host "  Certificate issued!" -ForegroundColor Green
                break
            } elseif ($checkStatus -eq "FAILED") {
                Write-Host "  Certificate FAILED. Check ACM console for details." -ForegroundColor Red
                break
            }

            Write-Host "  Status: $checkStatus (attempt $attempt/$maxAttempts, retrying in 20s...)" -ForegroundColor Yellow
            Start-Sleep -Seconds 20
        }

        if ($checkStatus -ne "ISSUED") {
            Write-Host ""
            Write-Host "  Certificate not yet issued. This is expected if IT hasn't added the NS records yet." -ForegroundColor Yellow
            Write-Host "  After IT adds the NS records, the certificate will auto-validate." -ForegroundColor Yellow
            Write-Host "  Check status with:" -ForegroundColor Yellow
            Write-Host "    aws acm describe-certificate --certificate-arn $certificateArn --region $AwsRegion --query Certificate.Status --output text" -ForegroundColor White
        }
    } else {
        Write-Host "4. Skipping certificate wait (status: $certStatus)" -ForegroundColor Yellow
        Write-Host "   Check status later with:" -ForegroundColor Yellow
        Write-Host "   aws acm describe-certificate --certificate-arn $certificateArn --region $AwsRegion --query Certificate.Status --output text" -ForegroundColor White
    }
} else {
    Write-Host "2. Skipping certificate request (-SkipCertificate)" -ForegroundColor Yellow
}

# =========================================================================
# Step 5: Update ecs-config.json (if found)
# =========================================================================
Write-Host ""
Write-Host "5. Updating project configuration..." -ForegroundColor Yellow

if (-not $ConfigFile) {
    $ConfigFile = Join-Path $ProjectRoot "ecs-config.json"
}

if (Test-Path $ConfigFile) {
    $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $updated = $false

    if ($config.Route53HostedZoneId -ne $hostedZoneId) {
        $config | Add-Member -NotePropertyName "Route53HostedZoneId" -NotePropertyValue $hostedZoneId -Force
        $updated = $true
    }
    if ($config.ParentDomain -ne $ParentDomain) {
        $config | Add-Member -NotePropertyName "ParentDomain" -NotePropertyValue $ParentDomain -Force
        $updated = $true
    }
    if ($certificateArn -and $config.CertificateArn -ne $certificateArn) {
        $config | Add-Member -NotePropertyName "CertificateArn" -NotePropertyValue $certificateArn -Force
        $updated = $true
    }
    # Auto-set CustomDomainName if not already set
    if (-not $config.CustomDomainName -and $config.ProjectName) {
        $config | Add-Member -NotePropertyName "CustomDomainName" -NotePropertyValue "$($config.ProjectName).$ParentDomain" -Force
        $updated = $true
        Write-Host "  Auto-set CustomDomainName: $($config.ProjectName).$ParentDomain" -ForegroundColor Cyan
    }

    if ($updated) {
        $config | ConvertTo-Json -Depth 5 | Set-Content $ConfigFile
        Write-Host "  Updated: $ConfigFile" -ForegroundColor Green
    } else {
        Write-Host "  No changes needed in $ConfigFile" -ForegroundColor Green
    }
} else {
    Write-Host "  No ecs-config.json found at $ConfigFile" -ForegroundColor Yellow
}

# =========================================================================
# Summary
# =========================================================================
Write-Host ""
Write-Host "=== Setup Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Route 53 Hosted Zone ID: $hostedZoneId" -ForegroundColor Cyan
Write-Host "Parent Domain:           $ParentDomain" -ForegroundColor Cyan
if ($certificateArn) {
    Write-Host "Wildcard Certificate:    $certificateArn" -ForegroundColor Cyan
}
Write-Host ""
Write-Host "Add these values to each project's ecs-config.json:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  {" -ForegroundColor White
Write-Host "    `"Route53HostedZoneId`": `"$hostedZoneId`"," -ForegroundColor White
Write-Host "    `"ParentDomain`":        `"$ParentDomain`"," -ForegroundColor White
if ($certificateArn) {
    Write-Host "    `"CertificateArn`":      `"$certificateArn`"," -ForegroundColor White
}
Write-Host "    `"CustomDomainName`":    `"<project-name>.$ParentDomain`"" -ForegroundColor White
Write-Host "  }" -ForegroundColor White
Write-Host ""

if (-not $SkipCertificate) {
    Write-Host "IMPORTANT: The certificate will only be validated after IT adds the NS records." -ForegroundColor Yellow
    Write-Host "Send IT the NS records shown above." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Once IT completes NS delegation, for each new project run:" -ForegroundColor Yellow
Write-Host "  .\CCM\setup-aws-infrastructure.ps1    # Creates ALB + Route 53 CNAME automatically" -ForegroundColor White
Write-Host "  .\CCM\deploy-ecs.ps1                  # Deploys with HTTPS + correct CORS" -ForegroundColor White
Write-Host ""
