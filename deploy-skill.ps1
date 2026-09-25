#!/usr/bin/env pwsh

<#

.SYNOPSIS
        Deploy-Skill
        Created By: Stefano Sinigardi
        Created Date: February 21, 2026
        Last Modified Date: April 21, 2026

.DESCRIPTION
Deploy custom AI skills

.PARAMETER DisableInteractive
Disable script interactivity (useful for CI runs)

.PARAMETER DeployToAgents
Also deploy skills to ~/.agents/skills (disabled by default)

.EXAMPLE
.\Deploy-Skill -DisableInteractive

.EXAMPLE
.\Deploy-Skill -DeployToAgents

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

param (
  [switch]$DisableInteractive = $false,
  [switch]$DeployToAgents = $false
)

$global:DisableInteractive = $DisableInteractive

$deploy_skill_ps1_version = "1.1.0"

Import-Module -Name $PSScriptRoot/utils.psm1 -Force

$ccmLog = Initialize-CcmLogging
trap { Stop-CcmLogging $ccmLog; break }

Write-Host "Deploy-Skill script version ${deploy_skill_ps1_version}, utils module version ${utils_psm1_version}"

Write-Host -NoNewLine "PowerShell version:"
$PSVersionTable.PSVersion

if ($IsWindowsPowerShell) {
  Write-Host "Running on Windows Powershell, please consider update and running on newer Powershell versions"
}

if ($PSVersionTable.PSVersion.Major -lt 5) {
  MyThrow("Your PowerShell version is too old, please update it.")
}

$repoRoot = Resolve-Path "$PSScriptRoot/.."
$skillDirs = Get-ChildItem -Path $repoRoot -Directory | Where-Object {
  Test-Path (Join-Path $_.FullName "SKILL.md")
}

if ($skillDirs.Count -eq 0) {
  MyThrow("No skill directories found (folders containing SKILL.md).")
}

# Portability gate: the Agent Skills spec caps the frontmatter `description` at
# 1024 characters. Claude Code is lenient and loads longer descriptions anyway,
# but GitHub Copilot and OpenAI Codex enforce the limit and silently refuse to
# load any skill that exceeds it. Validate every skill here so an over-length
# description fails the deploy loudly instead of breaking only outside Claude.
$DescriptionMaxLength = 1024
Write-Host "Validating skill descriptions (<= ${DescriptionMaxLength} chars for Copilot/Codex portability)..." -ForegroundColor Cyan
$validationErrors = @()
foreach ($skillDir in $skillDirs) {
  $skillMd = Join-Path $skillDir.FullName "SKILL.md"
  $raw = Get-Content -Path $skillMd -Raw

  # Isolate the YAML frontmatter (content between the first two `---` fences).
  $fm = [regex]::Match($raw, '(?s)^﻿?---\s*\r?\n(.*?)\r?\n---\s*\r?\n')
  if (-not $fm.Success) {
    $validationErrors += "$($skillDir.Name): SKILL.md has no YAML frontmatter (--- ... --- block)"
    continue
  }
  $frontmatter = $fm.Groups[1].Value

  # Extract the description value. Supports a single-line plain, single- or
  # double-quoted scalar (the convention used across these skills).
  $descMatch = [regex]::Match($frontmatter, '(?m)^description:[ \t]*(?<v>.*?)[ \t]*$')
  if (-not $descMatch.Success) {
    $validationErrors += "$($skillDir.Name): SKILL.md frontmatter has no 'description' field"
    continue
  }
  $desc = $descMatch.Groups['v'].Value
  if (($desc.StartsWith('"') -and $desc.EndsWith('"')) -or ($desc.StartsWith("'") -and $desc.EndsWith("'"))) {
    $desc = $desc.Substring(1, $desc.Length - 2)
  }

  if (-not $descMatch.Success -or [string]::IsNullOrWhiteSpace($desc)) {
    $validationErrors += "$($skillDir.Name): empty skill description"
  }
  elseif ($desc.Length -gt $DescriptionMaxLength) {
    $over = $desc.Length - $DescriptionMaxLength
    $validationErrors += "$($skillDir.Name): description is $($desc.Length) chars ($over over the ${DescriptionMaxLength} limit) - will fail to load in Copilot/Codex"
  }
  else {
    Write-Host "  OK   $($skillDir.Name) ($($desc.Length) chars)" -ForegroundColor Green
  }
}

if ($validationErrors.Count -gt 0) {
  Write-Host "Skill validation failed:" -ForegroundColor Red
  foreach ($err in $validationErrors) {
    Write-Host "  X  $err" -ForegroundColor Red
  }
  MyThrow("$($validationErrors.Count) skill(s) failed portability validation. Fix the description(s) above and re-run.")
}

$skills_bases = @(
  "~/.claude/skills"
)

if ($DeployToAgents) {
  $skills_bases += "~/.agents/skills"
}

foreach ($skills_base in $skills_bases) {
  New-Item -ItemType Directory -Force -Path $skills_base | Out-Null
  Write-Host "Deploying skills to ${skills_base}..." -ForegroundColor Cyan

  foreach ($skillDir in $skillDirs) {
    $skillName = $skillDir.Name
    $skill_link = "${skills_base}/${skillName}"
    Write-Host "  Deploying skill: ${skillName}"
    if (-Not (Test-Path $skill_link)) {
      Write-Host "    Linking $($skillDir.FullName) to ${skill_link}"
      New-Item -ItemType SymbolicLink -Path $skill_link -Target $skillDir.FullName | Out-Null
    }
    else {
      Write-Host "    ${skill_link} already present"
    }
    Write-Host "    ${skillName} deployed!" -ForegroundColor Green
  }
}

# Configure Claude Code permissions so skills can read their own files without prompting
$claude_skills_base = "~/.claude/skills"
$claude_settings_path = "~/.claude/settings.json"
$resolved_skills_base = (Resolve-Path $claude_skills_base).Path
Write-Host "Configuring Claude Code permissions for skills directory..."
if (Test-Path $claude_settings_path) {
  $settings = Get-Content $claude_settings_path -Raw | ConvertFrom-Json
}
else {
  $settings = [PSCustomObject]@{}
}
if (-Not $settings.permissions) {
  $settings | Add-Member -NotePropertyName "permissions" -NotePropertyValue ([PSCustomObject]@{})
}
if (-Not $settings.permissions.additionalDirectories) {
  $settings.permissions | Add-Member -NotePropertyName "additionalDirectories" -NotePropertyValue @()
}
if (-Not $settings.permissions.allow) {
  $settings.permissions | Add-Member -NotePropertyName "allow" -NotePropertyValue @()
}

$dirty = $false

# Add additionalDirectories entry
$dirs = @($settings.permissions.additionalDirectories)
if ($dirs -notcontains $resolved_skills_base) {
  $dirs += $resolved_skills_base
  $settings.permissions.additionalDirectories = $dirs
  $dirty = $true
  Write-Host "  Added ${resolved_skills_base} to additionalDirectories" -ForegroundColor Green
}
else {
  Write-Host "  ${resolved_skills_base} already in additionalDirectories" -ForegroundColor Green
}

# Add Read allow rule so skills can read their references/assets without prompting
$readRule = "Read(~/.claude/skills/**)"
$allowRules = @($settings.permissions.allow)
if ($allowRules -notcontains $readRule) {
  $allowRules += $readRule
  $settings.permissions.allow = $allowRules
  $dirty = $true
  Write-Host "  Added Read permission for skills directory" -ForegroundColor Green
}
else {
  Write-Host "  Read permission already configured" -ForegroundColor Green
}

if ($dirty) {
  $settings | ConvertTo-Json -Depth 10 | Set-Content $claude_settings_path -Encoding UTF8
}

Write-Host "All skills deployed!" -ForegroundColor Green

Stop-CcmLogging $ccmLog
