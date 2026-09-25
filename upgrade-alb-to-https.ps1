#! /usr/bin/env pwsh

<#

.SYNOPSIS
    upgrade-alb-to-https
    Created By: Stefano Sinigardi
    Created Date: March 13, 2026

.DESCRIPTION
    Upgrades an existing HTTP-only ALB to HTTPS.

    This script:
      1. Reads infrastructure-config.json for ALB and target group details
      2. Validates the ACM certificate
      3. Deletes the existing HTTP listener
      4. Creates an HTTPS listener with the certificate
      5. Creates an HTTP->HTTPS redirect listener
      6. Updates the ALB security group to allow port 443 (if not already open)
      7. If an NLB is present in front of the ALB (NlbArn in
         infrastructure-config.json), creates a new NLB port-443 target group,
         registers the ALB in it, and adds a TCP:443 listener on the NLB. The
         pre-existing port-80 NLB target group is kept and its role changes to
         HTTP->HTTPS redirect routing (NLB TCP:80 -> ALB:80 redirect listener).
      8. If Route53HostedZoneId and ParentDomain are set in ecs-config.json,
         creates/updates a Route 53 CNAME (CustomDomainName -> NLB DNS if NLB
         is present, else ALB DNS). Skipped when the Route 53 keys are absent.
      9. Updates infrastructure-config.json with the new listener protocol and,
         when applicable, the new NLB target group ARNs and DNS metadata.

    Prerequisites:
      - AWS CLI configured with admin credentials
      - An ACM certificate (validated and issued) for the ALB domain
      - Existing infrastructure created by setup-aws-infrastructure.ps1

.PARAMETER CertificateArn
    ACM certificate ARN for HTTPS on ALB (required)
    Example: "arn:aws:acm:eu-central-1:123456789012:certificate/xxx"

.PARAMETER AwsRegion
    AWS region. Default: read from infrastructure-config.json or "eu-central-1"

.PARAMETER DeployDir
    Directory containing ecs/infrastructure-config.json
    Default: auto-detected as ../deploy from script location

.PARAMETER ConfigFile
    Path to ecs-config.json project configuration file.
    Default: auto-detected as ecs-config.json in the project root (parent of CCM/).

.PARAMETER SkipHttpRedirect
    Skip creating the HTTP->HTTPS redirect listener.
    By default, port 80 is reconfigured to redirect to HTTPS.

.EXAMPLE
    .\CCM\upgrade-alb-to-https.ps1 -CertificateArn "arn:aws:acm:eu-central-1:123456789012:certificate/xxx"
    Upgrade the ALB from HTTP to HTTPS using the given certificate

.EXAMPLE
    .\CCM\upgrade-alb-to-https.ps1 -CertificateArn "arn:aws:acm:eu-central-1:123456789012:certificate/xxx" -SkipHttpRedirect
    Upgrade to HTTPS without creating an HTTP redirect listener

.NOTES
    This is a one-time migration script. After running it, subsequent deployments
    via deploy-ecs.ps1 will automatically detect the HTTPS configuration from
    infrastructure-config.json.

    The script is idempotent: if HTTPS is already configured, it will report
    the current state and exit without making changes.

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
    [string]$CertificateArn,

    [Parameter(Mandatory = $false)]
    [string]$AwsRegion,

    [Parameter(Mandatory = $false)]
    [string]$DeployDir,

    [Parameter(Mandatory = $false)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [switch]$SkipHttpRedirect
)

$ErrorActionPreference = "Stop"

# Auto-detect script directory and project root
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

# Import shared utilities
if (Test-Path $ScriptDir/utils.psm1) {
    Import-Module -Name $ScriptDir/utils.psm1 -Force
}

# ---------------------------------------------------------------------------
# Load project config file (ecs-config.json) for defaults
# ---------------------------------------------------------------------------
if (-not $ConfigFile) {
    $ConfigFile = Join-Path $ProjectRoot "ecs-config.json"
}

$Route53HostedZoneId = $null
$ParentDomain = $null
$CustomDomainName = $null

if (Test-Path $ConfigFile) {
    $fileConfig = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    if (-not $PSBoundParameters.ContainsKey('AwsRegion') -and $fileConfig.AwsRegion) { $AwsRegion = $fileConfig.AwsRegion }
    if (-not $PSBoundParameters.ContainsKey('DeployDir') -and $fileConfig.DeployDir) { $DeployDir = $fileConfig.DeployDir }
    if ($fileConfig.Route53HostedZoneId) { $Route53HostedZoneId = $fileConfig.Route53HostedZoneId }
    if ($fileConfig.ParentDomain)        { $ParentDomain        = $fileConfig.ParentDomain }
    if ($fileConfig.CustomDomainName)    { $CustomDomainName    = $fileConfig.CustomDomainName }
}

if (-not $AwsRegion) { $AwsRegion = "eu-central-1" }
if (-not $DeployDir) { $DeployDir = Join-Path $ProjectRoot "deploy" }

# Load infrastructure config
$infraConfigPath = Join-Path $DeployDir "ecs/infrastructure-config.json"
if (-not (Test-Path $infraConfigPath)) {
    Write-Host "" -ForegroundColor Red
    Write-Host "Infrastructure config not found: $infraConfigPath" -ForegroundColor Red
    Write-Host "Run setup-aws-infrastructure.ps1 first." -ForegroundColor Red
    exit 1
}

$infra = Get-Content $infraConfigPath -Raw | ConvertFrom-Json
$albArn = $infra.AlbArn
$tgArn = $infra.TargetGroupArn
$albSgId = $infra.AlbSecurityGroup
$albDns = $infra.AlbDns

if (-not $albArn -or -not $tgArn) {
    Write-Host "Missing AlbArn or TargetGroupArn in infrastructure config" -ForegroundColor Red
    exit 1
}

# Validate AWS credentials
Assert-AwsSsoSession -AwsRegion $AwsRegion

Write-Host ""
Write-Host "=== ALB HTTP -> HTTPS Upgrade ===" -ForegroundColor Cyan
Write-Host "ALB:         $albDns"
Write-Host "ALB ARN:     $albArn"
Write-Host "Target Group: $tgArn"
Write-Host "Certificate: $CertificateArn"
Write-Host "Region:      $AwsRegion"
Write-Host ""

# Step 1: Validate the ACM certificate
Write-Host "1. Validating ACM certificate..." -ForegroundColor Yellow
$certStatus = aws acm describe-certificate `
    --certificate-arn $CertificateArn `
    --region $AwsRegion `
    --query 'Certificate.Status' `
    --output text 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "  Certificate not found: $CertificateArn" -ForegroundColor Red
    Write-Host "  Error: $certStatus" -ForegroundColor Red
    exit 1
}

if ($certStatus -ne "ISSUED") {
    Write-Host "  Certificate status is '$certStatus' (expected: ISSUED)" -ForegroundColor Red
    Write-Host "  Complete certificate validation first (e.g., DNS validation in ACM console)." -ForegroundColor Yellow
    exit 1
}

$certDomain = aws acm describe-certificate `
    --certificate-arn $CertificateArn `
    --region $AwsRegion `
    --query 'Certificate.DomainName' `
    --output text
Write-Host "  Certificate valid: $certDomain (status: ISSUED)" -ForegroundColor Green

# Step 2: Check current listeners
Write-Host "2. Checking current ALB listeners..." -ForegroundColor Yellow
$listenersJson = aws elbv2 describe-listeners `
    --load-balancer-arn $albArn `
    --region $AwsRegion `
    --output json | ConvertFrom-Json

$listeners = $listenersJson.Listeners
Write-Host "  Found $($listeners.Count) listener(s):" -ForegroundColor Cyan
foreach ($l in $listeners) {
    $actionType = $l.DefaultActions[0].Type
    Write-Host "    - $($l.Protocol):$($l.Port) -> $actionType (ARN: $($l.ListenerArn))" -ForegroundColor Cyan
}

# Check if ALB is already HTTPS. If it is AND the NLB (when present) already has a TCP:443
# listener, nothing to do. Otherwise fall through to run the NLB upgrade only.
$httpsListener = $listeners | Where-Object { $_.Protocol -eq "HTTPS" -and $_.Port -eq 443 }
$albAlreadyHttps = [bool]$httpsListener

if ($albAlreadyHttps) {
    Write-Host ""
    Write-Host "  HTTPS listener already exists on port 443 — ALB already configured for HTTPS." -ForegroundColor Green

    $nlbNeedsUpgrade = $false
    if ($infra.NlbArn) {
        $nlbListenersCheck = aws elbv2 describe-listeners `
            --load-balancer-arn $infra.NlbArn `
            --region $AwsRegion `
            --output json 2>$null | ConvertFrom-Json
        if (-not ($nlbListenersCheck.Listeners | Where-Object { $_.Port -eq 443 })) {
            $nlbNeedsUpgrade = $true
            Write-Host "  However, NLB is missing a TCP:443 listener — will finish the NLB side." -ForegroundColor Yellow
        }
    }

    if (-not $nlbNeedsUpgrade) {
        # Still update infra config if needed
        if ($infra.ListenerProtocol -ne "HTTPS") {
            $infra | Add-Member -NotePropertyName "ListenerProtocol" -NotePropertyValue "HTTPS" -Force
            $infra | Add-Member -NotePropertyName "CertificateArn" -NotePropertyValue $CertificateArn -Force
            $infra | ConvertTo-Json -Depth 10 | Set-Content $infraConfigPath
            Write-Host "  Updated infrastructure-config.json with HTTPS metadata." -ForegroundColor Cyan
        }
        Write-Host ""
        Write-Host "No changes needed." -ForegroundColor Green
        exit 0
    }
}

if ($albAlreadyHttps) {
    Write-Host "3-6. Skipping ALB-side upgrade steps — ALB is already HTTPS." -ForegroundColor Yellow
}
else {

# Step 3: Ensure ALB security group allows port 443
Write-Host "3. Checking ALB security group for port 443..." -ForegroundColor Yellow
if ($albSgId) {
    $existingHttpsRule = aws ec2 describe-security-group-rules `
        --filters "Name=group-id,Values=$albSgId" `
        --region $AwsRegion `
        --query "SecurityGroupRules[?FromPort==``443`` && ToPort==``443`` && IsEgress==``false``]" `
        --output json | ConvertFrom-Json

    if ($existingHttpsRule.Count -eq 0) {
        # Determine the CIDR from existing HTTP rule
        $httpRules = aws ec2 describe-security-group-rules `
            --filters "Name=group-id,Values=$albSgId" `
            --region $AwsRegion `
            --query "SecurityGroupRules[?FromPort==``80`` && ToPort==``80`` && IsEgress==``false``]" `
            --output json | ConvertFrom-Json

        $vpnCidr = "10.0.0.0/8"  # Default
        if ($httpRules.Count -gt 0 -and $httpRules[0].CidrIpv4) {
            $vpnCidr = $httpRules[0].CidrIpv4
        }

        aws ec2 authorize-security-group-ingress `
            --group-id $albSgId `
            --protocol tcp `
            --port 443 `
            --cidr $vpnCidr `
            --region $AwsRegion
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Added HTTPS ingress rule (port 443, CIDR: $vpnCidr)" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: Could not add port 443 rule (may already exist)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Port 443 already open on ALB security group" -ForegroundColor Green
    }
} else {
    Write-Host "  WARNING: No ALB security group in infrastructure config, skipping" -ForegroundColor Yellow
}

# Step 4: Create the HTTPS listener FIRST (before touching the HTTP:80 one).
# This ordering matters when an NLB is registered against ALB:80 — AWS refuses to delete
# an ALB listener while an NLB target-type=alb target group references it. Creating the
# HTTPS listener up-front also means step 6b can register NLB targets on the new 443
# listener without a gap. Idempotent: if HTTPS:443 already exists, we skip creation.
Write-Host "4. Creating HTTPS listener on port 443..." -ForegroundColor Yellow
$existingHttpsListener = $listeners | Where-Object { $_.Protocol -eq "HTTPS" -and $_.Port -eq 443 }
if ($existingHttpsListener) {
    Write-Host "  HTTPS listener already exists on port 443 — skipping creation" -ForegroundColor Green
} else {
    aws elbv2 create-listener `
        --load-balancer-arn $albArn `
        --protocol HTTPS `
        --port 443 `
        --certificates "CertificateArn=$CertificateArn" `
        --default-actions "Type=forward,TargetGroupArn=$tgArn" `
        --region $AwsRegion | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Failed to create HTTPS listener" -ForegroundColor Red
        exit 1
    }
    Write-Host "  HTTPS listener created" -ForegroundColor Green
}

# Step 5: Convert the existing HTTP:80 forward listener in place.
# Prefer modify-listener (forward -> redirect) over delete+create: the listener stays
# alive throughout, so any NLB target registrations referencing ALB:80 remain valid.
# delete+create would fail with ResourceInUse on NLB-fronted deployments.
Write-Host "5. Converting HTTP:80 listener..." -ForegroundColor Yellow
$httpForwardListener = $listeners | Where-Object {
    $_.Protocol -eq "HTTP" -and $_.Port -eq 80 -and $_.DefaultActions[0].Type -eq "forward"
}

if ($httpForwardListener) {
    if ($SkipHttpRedirect -and -not $infra.NlbArn) {
        # No NLB, caller wants port 80 gone entirely. Safe to delete.
        Write-Host "  -SkipHttpRedirect set and no NLB — deleting HTTP:80 listener..." -ForegroundColor Yellow
        aws elbv2 delete-listener `
            --listener-arn $httpForwardListener.ListenerArn `
            --region $AwsRegion | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  Failed to delete HTTP listener" -ForegroundColor Red
            exit 1
        }
        Write-Host "  HTTP:80 listener removed" -ForegroundColor Green
    } else {
        if ($SkipHttpRedirect) {
            Write-Host "  -SkipHttpRedirect requested but NLB is present; port 80 must remain (NLB references it). Converting to redirect anyway." -ForegroundColor Yellow
        }
        aws elbv2 modify-listener `
            --listener-arn $httpForwardListener.ListenerArn `
            --default-actions "Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}" `
            --region $AwsRegion | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  Failed to convert HTTP:80 listener to redirect" -ForegroundColor Red
            exit 1
        }
        Write-Host "  HTTP:80 listener converted to HTTP->HTTPS redirect (301)" -ForegroundColor Green
    }
} else {
    # Might already be a redirect listener from a prior partial run, or deleted.
    $httpRedirectListener = $listeners | Where-Object {
        $_.Protocol -eq "HTTP" -and $_.Port -eq 80 -and $_.DefaultActions[0].Type -eq "redirect"
    }
    if ($httpRedirectListener) {
        Write-Host "  HTTP:80 is already a redirect listener — nothing to do" -ForegroundColor Green
    } elseif (-not $SkipHttpRedirect) {
        # No HTTP:80 listener at all. Create a redirect one for completeness.
        Write-Host "  No HTTP:80 listener found — creating a redirect listener..." -ForegroundColor Yellow
        aws elbv2 create-listener `
            --load-balancer-arn $albArn `
            --protocol HTTP `
            --port 80 `
            --default-actions "Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}" `
            --region $AwsRegion | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  HTTP -> HTTPS redirect listener created" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: Could not create redirect listener (non-fatal)" -ForegroundColor Yellow
        }
    }
}

}  # end: else branch of "if ($albAlreadyHttps)"

# Step 6b: Upgrade NLB listeners for HTTPS (only if NLB is present in front of ALB)
# An NLB in front of the ALB operates as a transparent TCP proxy (target-type=alb).
# Before this upgrade: NLB TCP:80 -> NLB TG (port 80) -> ALB HTTP listener.
# After this upgrade:  NLB TCP:443 -> new NLB TG (port 443) -> ALB HTTPS listener.
#                      NLB TCP:80  -> existing NLB TG (port 80) -> ALB HTTP->HTTPS redirect.
# Projects without an NLB (no NlbArn in infra-config) skip this entire block.
if ($infra.NlbArn) {
    Write-Host "6b. Detected NLB in front of ALB — upgrading NLB listeners for HTTPS..." -ForegroundColor Yellow
    $nlbArn = $infra.NlbArn
    $existingNlbTgArn = $infra.NlbTargetGroupArn  # port 80 TG (will be relabeled as the HTTP redirect TG)

    $projectName = $infra.ProjectName
    if (-not $projectName) {
        Write-Host "  ProjectName missing from infrastructure-config.json — cannot derive NLB target group name" -ForegroundColor Red
        exit 1
    }
    $vpcId = $infra.VpcId
    if (-not $vpcId) {
        Write-Host "  VpcId missing from infrastructure-config.json — cannot create NLB target group" -ForegroundColor Red
        exit 1
    }

    # The existing port-80 TG (named "$projectName-nlb-tg") stays as-is; TG ports are immutable.
    # The new port-443 TG gets a distinct name to avoid collision with the existing primary.
    $nlbHttpsTgName = "$projectName-nlb-https-tg"

    # Idempotency: if NLB TCP:443 listener already exists, skip.
    $existingNlbListeners = aws elbv2 describe-listeners `
        --load-balancer-arn $nlbArn `
        --region $AwsRegion `
        --output json | ConvertFrom-Json
    $nlbHttpsListener = $existingNlbListeners.Listeners | Where-Object { $_.Port -eq 443 }

    if ($nlbHttpsListener) {
        Write-Host "  NLB already has a TCP:443 listener — skipping NLB upgrade." -ForegroundColor Green
    }
    else {
        # 6b.a Create port-443 target group (type=alb) — or reuse if it already exists
        $nlbHttpsTgArn = aws elbv2 describe-target-groups `
            --names $nlbHttpsTgName `
            --region $AwsRegion `
            --query 'TargetGroups[0].TargetGroupArn' `
            --output text 2>$null

        if (-not $nlbHttpsTgArn -or $nlbHttpsTgArn -eq "None") {
            $nlbHttpsTgArn = aws elbv2 create-target-group `
                --name $nlbHttpsTgName `
                --protocol TCP `
                --port 443 `
                --vpc-id $vpcId `
                --target-type alb `
                --health-check-enabled `
                --region $AwsRegion `
                --query 'TargetGroups[0].TargetGroupArn' `
                --output text
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  Failed to create NLB HTTPS target group" -ForegroundColor Red
                exit 1
            }
            Write-Host "  Created NLB HTTPS target group (port 443): $nlbHttpsTgArn" -ForegroundColor Green
        }
        else {
            Write-Host "  NLB HTTPS target group exists: $nlbHttpsTgArn" -ForegroundColor Green
        }

        # 6b.b Register ALB as target in the new TG
        $existingTargets = aws elbv2 describe-target-health `
            --target-group-arn $nlbHttpsTgArn `
            --region $AwsRegion `
            --query 'TargetHealthDescriptions[0].Target.Id' `
            --output text 2>$null

        if (-not $existingTargets -or $existingTargets -eq "None") {
            aws elbv2 register-targets `
                --target-group-arn $nlbHttpsTgArn `
                --targets "Id=$albArn" `
                --region $AwsRegion
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  Failed to register ALB in NLB HTTPS target group" -ForegroundColor Red
                exit 1
            }
            Write-Host "  ALB registered in NLB HTTPS target group" -ForegroundColor Green
        }
        else {
            Write-Host "  ALB already registered in NLB HTTPS target group" -ForegroundColor Green
        }

        # 6b.c Create NLB TCP:443 listener -> new TG
        aws elbv2 create-listener `
            --load-balancer-arn $nlbArn `
            --protocol TCP `
            --port 443 `
            --default-actions "Type=forward,TargetGroupArn=$nlbHttpsTgArn" `
            --region $AwsRegion | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  Failed to create NLB TCP:443 listener" -ForegroundColor Red
            exit 1
        }
        Write-Host "  NLB TCP:443 listener created -> ALB HTTPS" -ForegroundColor Green

        # Relabel in infra-config to match fresh-install semantics:
        #   NlbTargetGroupArn     = primary (HTTPS / port 443)
        #   NlbHttpTargetGroupArn = redirect (HTTP / port 80)
        if ($existingNlbTgArn) {
            $infra | Add-Member -NotePropertyName "NlbHttpTargetGroupArn" -NotePropertyValue $existingNlbTgArn -Force
        }
        $infra.NlbTargetGroupArn = $nlbHttpsTgArn
        Write-Host "  NLB upgrade complete. Existing TCP:80 listener continues to serve the HTTP->HTTPS redirect." -ForegroundColor Green
    }
}

# Step 6c: Create/update Route 53 CNAME (optional — requires Route53HostedZoneId + ParentDomain in ecs-config.json)
# When the project is NLB-fronted the CNAME points at the NLB; otherwise it points at the ALB.
# Projects without the Route 53 keys skip this block entirely (backwards compat).
if ($Route53HostedZoneId -and $ParentDomain) {
    Write-Host "6c. Creating/updating Route 53 CNAME..." -ForegroundColor Yellow

    $projectNameForDns = $infra.ProjectName
    if (-not $CustomDomainName) {
        if ($projectNameForDns) {
            $CustomDomainName = "$projectNameForDns.$ParentDomain"
            Write-Host "  Auto-derived CustomDomainName: $CustomDomainName" -ForegroundColor Cyan
        } else {
            Write-Host "  Cannot derive CustomDomainName (ProjectName missing, CustomDomainName not set) — skipping DNS" -ForegroundColor Yellow
        }
    }

    if ($CustomDomainName) {
        # Prefer NLB DNS when present (NLB is the public-facing LB in NLB-fronted deployments)
        $dnsTarget = if ($infra.NlbDns) { $infra.NlbDns } else { $albDns }

        $existingRecord = aws route53 list-resource-record-sets `
            --hosted-zone-id $Route53HostedZoneId `
            --query "ResourceRecordSets[?Name=='${CustomDomainName}.' && Type=='CNAME']" `
            --output json 2>$null | ConvertFrom-Json

        $needsWrite = $true
        $action = "CREATE"
        if ($existingRecord -and $existingRecord.Count -gt 0) {
            $currentValue = $existingRecord[0].ResourceRecords[0].Value
            if ($currentValue -eq "$dnsTarget." -or $currentValue -eq $dnsTarget) {
                Write-Host "  Route 53 CNAME already correct: $CustomDomainName -> $dnsTarget" -ForegroundColor Green
                $needsWrite = $false
            } else {
                Write-Host "  Route 53 CNAME exists but points to '$currentValue', updating to '$dnsTarget'..." -ForegroundColor Yellow
                $action = "UPSERT"
            }
        } else {
            Write-Host "  Creating Route 53 CNAME: $CustomDomainName -> $dnsTarget" -ForegroundColor Yellow
        }

        if ($needsWrite) {
            $changeBatch = @{
                Changes = @(@{
                    Action = $action
                    ResourceRecordSet = @{
                        Name = $CustomDomainName
                        Type = "CNAME"
                        TTL = 300
                        ResourceRecords = @(@{ Value = $dnsTarget })
                    }
                })
            } | ConvertTo-Json -Depth 5 -Compress

            $tempDns = [System.IO.Path]::GetTempFileName()
            $changeBatch | Set-Content $tempDns
            aws route53 change-resource-record-sets `
                --hosted-zone-id $Route53HostedZoneId `
                --change-batch "file://$tempDns" | Out-Null
            $r53Exit = $LASTEXITCODE
            Remove-Item $tempDns -ErrorAction SilentlyContinue
            if ($r53Exit -eq 0) {
                Write-Host "  Route 53 CNAME written: $CustomDomainName -> $dnsTarget" -ForegroundColor Green
            } else {
                Write-Host "  WARNING: Could not write Route 53 CNAME (non-fatal)" -ForegroundColor Yellow
            }
        }

        # Persist the DNS keys to infra-config for downstream tools (matches setup-aws-infrastructure.ps1 behavior)
        $infra | Add-Member -NotePropertyName "Route53HostedZoneId" -NotePropertyValue $Route53HostedZoneId -Force
        $infra | Add-Member -NotePropertyName "ParentDomain"        -NotePropertyValue $ParentDomain        -Force
        $infra | Add-Member -NotePropertyName "CustomDomainName"    -NotePropertyValue $CustomDomainName    -Force
    }
}

# Step 7: Update infrastructure-config.json
Write-Host "7. Updating infrastructure-config.json..." -ForegroundColor Yellow
$infra | Add-Member -NotePropertyName "CertificateArn" -NotePropertyValue $CertificateArn -Force
$infra | Add-Member -NotePropertyName "ListenerProtocol" -NotePropertyValue "HTTPS" -Force
$infra | ConvertTo-Json -Depth 10 | Set-Content $infraConfigPath
Write-Host "  Updated: $infraConfigPath" -ForegroundColor Green

# Step 8: Verify
Write-Host ""
Write-Host "8. Verifying new listeners..." -ForegroundColor Yellow
Write-Host "  ALB listeners:" -ForegroundColor Cyan
$newListeners = aws elbv2 describe-listeners `
    --load-balancer-arn $albArn `
    --region $AwsRegion `
    --output json | ConvertFrom-Json

foreach ($l in $newListeners.Listeners) {
    $actionType = $l.DefaultActions[0].Type
    Write-Host "    $($l.Protocol):$($l.Port) -> $actionType" -ForegroundColor Cyan
}

if ($infra.NlbArn) {
    Write-Host "  NLB listeners:" -ForegroundColor Cyan
    $newNlbListeners = aws elbv2 describe-listeners `
        --load-balancer-arn $infra.NlbArn `
        --region $AwsRegion `
        --output json 2>$null | ConvertFrom-Json
    foreach ($l in $newNlbListeners.Listeners) {
        $actionType = $l.DefaultActions[0].Type
        Write-Host "    $($l.Protocol):$($l.Port) -> $actionType" -ForegroundColor Cyan
    }
}

Write-Host ""
Write-Host "=== Upgrade Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Your ALB is now serving HTTPS." -ForegroundColor Green
$fallbackHost = if ($infra.NlbDns) { $infra.NlbDns } else { $albDns }
$displayHost = if ($infra.CustomDomainName) { $infra.CustomDomainName } else { $fallbackHost }
Write-Host "URL: https://$displayHost" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Redeploy to update CORS_ALLOWED_ORIGINS to https://:" -ForegroundColor White
Write-Host "     .\CCM\deploy-ecs.ps1" -ForegroundColor Cyan
Write-Host "  2. If using SSO, update the Entra ID redirect URI to https://" -ForegroundColor White
Write-Host "  3. If using SSO, update the Secrets Manager redirect_uri value" -ForegroundColor White
Write-Host ""
