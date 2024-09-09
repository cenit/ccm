#!/usr/bin/env pwsh

<#

.SYNOPSIS
        build-doc
        Created By: Stefano Sinigardi
        Created Date: February 18, 2019
        Last Modified Date: August 22, 2024

.DESCRIPTION
Build documentation with pandoc and latex

.PARAMETER DisableInteractive
Disable script interactivity (useful for CI runs)

.PARAMETER DoNotUpdateTOOL
Do not update the tool before running the build (valid only if tool is git-enabled)

.PARAMETER CleanBeforeBuild
Run cleaning script before starting building

.PARAMETER DisablePandoc
Disable creation of PDF files from Markdown files

.PARAMETER CreateOverlay
Add an overlay to the generated PDFs, using default header and footer if not specified

.PARAMETER OverlayOnTop
Put the overlay on top of the original PDF

.PARAMETER OverlayClass
Style for the overlay that will be printed on top of produced PDFs

.PARAMETER OverlayTitle
Header string that will be printed on the overlay if enabled

.PARAMETER OverlayAuthor
Footer string that will be printed on the overlay if enabled

.PARAMETER DisablePdftk
Disable merging of PDF files if they match the same radix basename (single token before first underscore)

.PARAMETER DisableRSVGConvert
Disable tool necessary to convert badges and/or any SVG into format latex-compatible (automatically invoked by pandoc if necessary when converting markdown into pdf)

.PARAMETER LookAllSubfolders
Look into all subfolders for documents to convert, and not just typical ones (wiki, md, doc)

.PARAMETER CreateIntermediateTexFiles
Create also intermediate TeX files from markdown files

.PARAMETER DoNotBuildPDFFromTexFiles
Do not convert TeX files to final PDF files

.PARAMETER DisableMermaidFilter
Disable tool necessary to convert mermaid code into diagrams inside markdown documents

.PARAMETER DisableTeX
Disable creation of PDF files from TeX files

.PARAMETER SkipMatching
Skip files matching with provided string (also partially matching)

.PARAMETER RefreshGitSubmodules
Update git submodules if necessary

.EXAMPLE
.\build-doc -DisableInteractive -DisablePandoc

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
  [switch]$DoNotUpdateTOOL = $false,
  [switch]$CleanBeforeBuild = $false,
  [switch]$DisablePandoc = $false,
  [switch]$CreateOverlay = $false,
  [switch]$OverlayOnTop = $false,
  [string]$OverlayClass = "",
  [string]$OverlayTitle = "",
  [string]$OverlayAuthor = "",
  [switch]$DisablePdftk = $false,
  [switch]$DisableRSVGConvert = $false,
  [switch]$DisableMermaidFilter = $false,
  [switch]$DisableTeX = $false,
  [switch]$CreateDocx = $false,
  [switch]$EnableSphinx = $false,
  [switch]$LookAllSubfolders = $false,
  [switch]$CreateIntermediateTexFiles = $false,
  [switch]$DoNotBuildPDFFromTexFiles = $false,
  [string]$SkipMatching = "",
  [switch]$RefreshGitSubmodules = $false
)

$global:DisableInteractive = $DisableInteractive

$build_doc_ps1_version = "3.1.0"
$script_name = $MyInvocation.MyCommand.Name
if (Test-Path $PSScriptRoot/utils.psm1) {
  Import-Module -Name $PSScriptRoot/utils.psm1 -Force
  $utils_psm1_avail = $true
}
elseif (Test-Path $PSScriptRoot/cmake/utils.psm1) {
  Import-Module -Name $PSScriptRoot/cmake/utils.psm1 -Force
  $utils_psm1_avail = $true
  $IsInGitSubmodule = $false
}
elseif (Test-Path $PSScriptRoot/ci/utils.psm1) {
  Import-Module -Name $PSScriptRoot/ci/utils.psm1 -Force
  $utils_psm1_avail = $true
  $IsInGitSubmodule = $false
}
elseif (Test-Path $PSScriptRoot/ccm/utils.psm1) {
  Import-Module -Name $PSScriptRoot/ccm/utils.psm1 -Force
  $utils_psm1_avail = $true
  $IsInGitSubmodule = $false
}
elseif (Test-Path $PSScriptRoot/scripts/utils.psm1) {
  Import-Module -Name $PSScriptRoot/scripts/utils.psm1 -Force
  $utils_psm1_avail = $true
  $IsInGitSubmodule = $false
}
else {
  $utils_psm1_version = "unavail"
  $IsWindowsPowerShell = $false
  $IsInGitSubmodule = $false
}

$ErrorActionPreference = "SilentlyContinue"
Stop-Transcript | out-null
$ErrorActionPreference = "Continue"
if($IsInGitSubmodule) {
  $PSCustomScriptRoot = Split-Path $PSScriptRoot -Parent
}
else {
  $PSCustomScriptRoot = $PSScriptRoot
}
$BuildDocLogPath = "$PSCustomScriptRoot/build-doc.log"
Start-Transcript -Path $BuildDocLogPath

Write-Host "Build doc script version ${build_doc_ps1_version}, utils module version ${utils_psm1_version}"
Write-Host "Working directory: $PSCustomScriptRoot, log file: $BuildDocLogPath, $script_name is in submodule: $IsInGitSubmodule"

Write-Host -NoNewLine "PowerShell version:"
$PSVersionTable.PSVersion

if ($IsWindowsPowerShell) {
  Write-Host "Running on Windows Powershell, please consider update and running on newer Powershell versions"
}

if ($PSVersionTable.PSVersion.Major -lt 5) {
  MyThrow("Your PowerShell version is too old, please update it.")
}

Push-Location $PSCustomScriptRoot

if ($IsWindowsPowerShell -or $IsWindows) {
  $texlive_path = "E:\texlive\2024\bin\windows"
  if (Test-Path $texlive_path) {
    Write-Host "Added $texlive_path to PATH"
    $env:PATH += ";$texlive_path"
  }
  $texlive_path = "C:\texlive\2024\bin\windows"
  if (Test-Path $texlive_path) {
    Write-Host "Added $texlive_path to PATH"
    $env:PATH += ";$texlive_path"
  }
  $texlive_path = "C:\texlive\2023\bin\windows"
  if (Test-Path $texlive_path) {
    Write-Host "Added $texlive_path to PATH"
    $env:PATH += ";$texlive_path"
  }
  $texlive_path = "C:\texlive\2022\bin\win32"
  if (Test-Path $texlive_path) {
    Write-Host "Added $texlive_path to PATH"
    $env:PATH += ";$texlive_path"
  }
  $texlive_path = "C:\texlive\2021\bin\win32"
  if (Test-Path $texlive_path) {
    Write-Host "Added $texlive_path to PATH"
    $env:PATH += ";$texlive_path"
  }
  $texlive_path = "C:\texlive\2020\bin\win32"
  if (Test-Path $texlive_path) {
    Write-Host "Added $texlive_path to PATH"
    $env:PATH += ";$texlive_path"
  }
  $texlive_path = "C:\texlive\2019\bin\win32"
  if (Test-Path $texlive_path) {
    Write-Host "Added $texlive_path to PATH"
    $env:PATH += ";$texlive_path"
  }
  $texlive_path = "C:\texlive\2018\bin\win32"
  if (Test-Path $texlive_path) {
    Write-Host "Added $texlive_path to PATH"
    $env:PATH += ";$texlive_path"
  }
}

$GIT_EXE = Get-Command "git" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
if (-Not $GIT_EXE) {
  MyThrow("Could not find git, please install it")
}
else {
  Write-Host "Using git from ${GIT_EXE}"
}

$gitModulesPath = Join-Path -Path (Get-Location) -ChildPath ".gitmodules"
if (-Not (Test-Path $gitModulesPath)) {
    Write-Output "No .gitmodules file found. The repository may not contain submodules."
    exit
}
$gitModulesContent = Get-Content $gitModulesPath

if ($RefreshGitSubmodules) {
  Write-Host "This tool will download git submodules now"
  $proc = Start-Process -NoNewWindow -PassThru -FilePath $GIT_EXE -ArgumentList " submodule update --init --recursive"
  $handle = $proc.Handle
  $proc.WaitForExit()
  $exitCode = $proc.ExitCode
  if (-Not ($exitCode -eq 0)) {
    MyThrow("Downloading git submodules failed! Exited with error code $exitCode.")
  }
}

if ($CreateDocx -and $DisablePandoc) {
  Write-Host "Unable to create docx with pandoc disabled! Disabling docx creation" -ForegroundColor Red
  $CreateDocx = $false
}

$CreateSphinxPDF = $true
if ($EnableSphinx -and $DisableTeX) {
  Write-Host "Unable to create sphinx pdf documentation with TeX disabled, only html will be produced" -ForegroundColor Red
  $CreateSphinxPDF = $false
}

$LATEXMK_EXE = Get-Command "latexmk" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
if (-Not $LATEXMK_EXE -And -Not $DisableTeX) {
  MyThrow("Could not find latexmk, please install it")
}
else {
  Write-Host "Using latexmk from $LATEXMK_EXE"
}

$PDFLATEX_EXE = Get-Command "pdflatex" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
if (-Not $PDFLATEX_EXE -And -Not $DisableTeX) {
  MyThrow("Could not find pdflatex, please install it")
}
else {
  Write-Host "Using pdflatex from $PDFLATEX_EXE"
}

$MAKEINDEX_EXE = Get-Command "makeindex" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
if (-Not $MAKEINDEX_EXE -And -Not $DisableTeX) {
  MyThrow("Could not find makeindex, please install it")
}
else {
  Write-Host "Using makeindex from $MAKEINDEX_EXE"
}

$PANDOC_EXE = Get-Command "pandoc" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
if (-Not $PANDOC_EXE -And -Not $DisablePandoc) {
  MyThrow("Could not find pandoc, please install it")
}
else {
  Write-Host "Using pandoc from $PANDOC_EXE"
}

$PDFTK_EXE = Get-Command "pdftk" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
if (-Not $PDFTK_EXE -And -Not $DisablePdftk) {
  MyThrow("Could not find pdftk, please install it")
}
else {
  Write-Host "Using pdftk from $PDFTK_EXE"
}

$SPHINXBUILD_EXE = Get-Command "sphinx-build" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
if (-Not $SPHINXBUILD_EXE -And $EnableSphinx) {
  MyThrow("Could not find sphinx-build, please install it")
}
elseif($SPHINXBUILD_EXE -And $EnableSphinx) {
  Write-Host "Using sphinx-build from $SPHINXBUILD_EXE"
}

$RSVGCONVERT_EXE = Get-Command "rsvg-convert" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
if (-Not $RSVGCONVERT_EXE -And -Not $DisableRSVGConvert -And -Not $DisablePandoc) {
  MyThrow("Could not find rsvg-convert, please install it")
}
else {
  Write-Host "Using rsvg-convert from $RSVGCONVERT_EXE"
}

if ($IsWindowsPowerShell -or $IsWindows) {
  $MERMAIDFILTER_CMD = Get-Command "mermaid-filter.cmd" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
}
else {
  $MERMAIDFILTER_CMD = Get-Command "mermaid-filter" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Definition
}
if (-Not $MERMAIDFILTER_CMD -And -Not $DisableMermaidFilter -And -Not $DisablePandoc) {
  MyThrow("Could not find mermaid-filter, please install it (npm install -g mermaid-filter)")
}
else {
  Write-Host "Using mermaid-filter from $MERMAIDFILTER_CMD"
  if ($IsWindowsPowerShell -or $IsWindows) {
    $mermaidfilter_pandoc = " -F mermaid-filter.cmd "
  }
  else {
    $mermaidfilter_pandoc = " -F mermaid-filter "
  }
}

if ($CreateOverlay -And $DisablePandoc) {
  Write-Host "Unable to create overlay with pandoc disabled!" -ForegroundColor Red
  $CreateOverlay = $false
}

if ($CreateOverlay -And $DisablePdftk) {
  Write-Host "Unable to add overlay to documents with pdftk disabled!" -ForegroundColor Red
  $CreateOverlay = $false
}

$GitRepoPath = Resolve-Path "$PSCustomScriptRoot/.git" -ErrorAction SilentlyContinue
$GitModulesPath = Resolve-Path "$PSCustomScriptRoot/.gitmodules" -ErrorAction SilentlyContinue
if (Test-Path "$GitRepoPath") {
  Write-Host "This tool has been cloned with git and supports self-updating mechanism"
  if ($DoNotUpdateTOOL) {
    Write-Host "This tool will not self-update sources" -ForegroundColor Yellow
  }
  else {
    Write-Host "This tool will self-update sources, please pass -DoNotUpdateTOOL to the script to disable"
    Set-Location "$PSCustomScriptRoot"
    $proc = Start-Process -NoNewWindow -PassThru -FilePath $GIT_EXE -ArgumentList "pull"
    $handle = $proc.Handle
    $proc.WaitForExit()
    $exitCode = $proc.ExitCode
    if (-Not ($exitCode -eq 0)) {
      MyThrow("Updating this tool sources failed! Exited with error code $exitCode.")
    }
    if (Test-Path "$GitModulesPath") {
      $proc = Start-Process -NoNewWindow -PassThru -FilePath $GIT_EXE -ArgumentList "submodule update --init --recursive"
      $handle = $proc.Handle
      $proc.WaitForExit()
      $exitCode = $proc.ExitCode
      if (-Not ($exitCode -eq 0)) {
        MyThrow("Updating this tool submodule sources failed! Exited with error code $exitCode.")
      }
    }
    Set-Location "$PSCustomScriptRoot"
  }
}

if ($CleanBeforeBuild) {
  if (Test-Path $PSScriptRoot/clean-doc.ps1) {
    & $PSScriptRoot/clean-doc.ps1
  }
  else {
    Write-Host "clean-doc.ps1 is not available" -ForegroundColor Yellow
  }
}

if ($CreateOverlay) {
  $OverlayPathMD = "$PSCustomScriptRoot/Overlay.md"
  $OverlayPathPDF = "$PSCustomScriptRoot/Overlay.pdf"
  if ($OverlayTitle -eq "") {
    $OverlayTitle = ${env:computername}
    $OverlayTitle += " - "
    $OverlayTitle += Get-Date
  }
  if ($OverlayAuthor -eq "") {
    $OverlayAuthor = "Stefano Sinigardi"
  }
  if ($OverlayClass -eq "") {
    $OverlayClass = "hfnotes"
  }
  $Overlay = "---
documentclass: $OverlayClass
title: `"${OverlayTitle}`"
author: `"${OverlayAuthor}`"
---"
  Out-File -FilePath $OverlayPathMD -InputObject $OverLay -Encoding ASCII
}

if (-Not $DisablePandoc) {
  if ($LookAllSubfolders) {
    $mditems = @(Get-ChildItem -Recurse -Filter *.md)
  }
  else {
    $mditems = @(Get-ChildItem -Filter *.md)
    if (Test-Path -Path "./wiki") {
      $mditems += @(Get-ChildItem "./wiki" -Filter *.md)
    }
    if (Test-Path -Path "./doc") {
      $mditems += @(Get-ChildItem "./doc" -Filter *.md)
    }
    if (Test-Path -Path "./man") {
      $mditems += @(Get-ChildItem "./man" -Filter *.md)
    }
    if (Test-Path -Path "./md") {
      $mditems += @(Get-ChildItem "./md" -Filter *.md)
    }
  }
  $mditems | Foreach-Object {
    $file_basename = $_.BaseName
    $file_basename_first_token = $file_basename.Split("_")
    $file_basename_first_token = $file_basename_first_token[0]
    $file_directory = $_.Directory
    $file_fullname = $_.FullName
    $folderPath = $_.DirectoryName.Replace((Get-Location).Path + "\", "")
    $submoduleEntry = $gitModulesContent -match "path = $folderPath"
    if ($submoduleEntry) {
        Write-Host "Skipping file in a git submodule: $($_.FullName)"
        return
    }

    if ($SkipMatching -ne "" -and $file_basename -match $SkipMatching) {
      Write-Host "Skipping $file_fullname"
      return
    }
    if (Test-Path -Path "${file_directory}/${file_basename}.yml") {
      $yaml_file = "${file_directory}/${file_basename}.yml"
      Write-Host "Using ${file_directory}/${file_basename}.yml"
    }
    else {
      $yaml_file = ""
    }
    if ($PDFTK_EXE -And -Not $DisablePdftk) {
      if (Test-Path -Path "${file_directory}/attachments") {
        Write-Host "Searching for attachment with this base token: $file_basename_first_token"
        $attachitems = @(Get-ChildItem "${file_directory}/attachments" -Filter "${file_basename_first_token}_*.pdf").FullName
        if ($attachitems) {
          Write-Host "Adding $attachitems to ${file_basename}.pdf to create ${file_basename}_full.pdf"
        }
        else {
          Write-Host "No attachment found"
        }
      }
    }
    Push-Location $file_directory
    $i = 0
    $new_pdf = "${file_basename}_old.pdf"
    while (Test-Path -Path "${new_pdf}") {
      $i++
      $new_pdf = "${file_basename}_old_$i.pdf"
    }
    if (Test-Path -Path "${file_basename}.pdf") {
      Write-Host "Renaming ${file_basename}.pdf to $new_pdf"
      Rename-Item -Path "${file_basename}.pdf" -NewName "$new_pdf"
    }
    if (-Not $DoNotBuildPDFFromTexFiles) {
      Write-Host "Building $file_basename.pdf"
      if ($yaml_file -ne "") {
        $pandoc_args = " $mermaidfilter_pandoc `"$yaml_file`" `"${file_directory}/${file_basename}.md`" --pdf-engine=xelatex --resource-path=wiki/ --resource-path=figures/ -o `"${file_basename}.pdf`""
      }
      else {
        $pandoc_args = " $mermaidfilter_pandoc `"${file_directory}/${file_basename}.md`" --pdf-engine=xelatex --resource-path=wiki/ --resource-path=figures/ -o `"${file_basename}.pdf`""
      }
      $proc = Start-Process -NoNewWindow -PassThru -FilePath $PANDOC_EXE -ArgumentList $pandoc_args
      $handle = $proc.Handle
      $proc.WaitForExit()
      $exitCode = $proc.ExitCode
      if (-Not ($exitCode -eq 0)) {
        MyThrow("Build failed! Exited with error code $exitCode.")
      }
    }
    if ($CreateIntermediateTexFiles) {
      Write-Host "Building $file_basename.tex"
      if ($yaml_file -ne "") {
        $pandoc_args = " $mermaidfilter_pandoc `"$yaml_file`" `"${file_directory}/${file_basename}.md`" --standalone --pdf-engine=xelatex --resource-path=wiki/ --resource-path=figures/ -o `"${file_basename}.tex`""
      }
      else {
        $pandoc_args = " $mermaidfilter_pandoc `"${file_directory}/${file_basename}.md`" --standalone --pdf-engine=xelatex --resource-path=wiki/ --resource-path=figures/ -o `"${file_basename}.tex`""
      }
      $proc = Start-Process -NoNewWindow -PassThru -FilePath $PANDOC_EXE -ArgumentList $pandoc_args
      $handle = $proc.Handle
      $proc.WaitForExit()
      $exitCode = $proc.ExitCode
      if (-Not ($exitCode -eq 0)) {
        MyThrow("Build failed! Exited with error code $exitCode.")
      }
    }
    if ($PDFTK_EXE -And $attachitems -And -Not $DisablePdftk) {
      $pdftk_args = " ${file_basename}.pdf $attachitems cat output ${file_basename}_full.pdf"
      $proc = Start-Process -NoNewWindow -PassThru -FilePath $PDFTK_EXE -ArgumentList $pdftk_args
      $handle = $proc.Handle
      $proc.WaitForExit()
      $exitCode = $proc.ExitCode
      if (-Not ($exitCode -eq 0)) {
        MyThrow("Merge failed! Exited with error code $exitCode.")
      }
    }
    if ($CreateDocx) {
      Write-Host "Building $file_basename.docx"
      $pandoc_args = " $mermaidfilter_pandoc $yaml_file ${file_directory}/${file_basename}.md --resource-path=wiki/ --resource-path=figures/ -o ${file_basename}.docx"
      $proc = Start-Process -NoNewWindow -PassThru -FilePath $PANDOC_EXE -ArgumentList $pandoc_args
      $handle = $proc.Handle
      $proc.WaitForExit()
      $exitCode = $proc.ExitCode
      if (-Not ($exitCode -eq 0)) {
        MyThrow("Build failed! Exited with error code $exitCode.")
      }
    }
    Pop-Location
  }
}

if (Test-Path -Path "./doc/README_extended.tex") {
  ## special document composed by tex+md files
  Write-Host "Building README_full"
  $pandoc_args = " ./README.yml ./README.md ./doc/README_extended.tex --resource-path=wiki/ --pdf-engine=xelatex -o README_full.pdf"
  $proc = Start-Process -NoNewWindow -PassThru -FilePath $PANDOC_EXE -ArgumentList $pandoc_args
  $handle = $proc.Handle
  $proc.WaitForExit()
  $exitCode = $proc.ExitCode
  if (-Not ($exitCode -eq 0)) {
    MyThrow("Build failed! Exited with error code $exitCode.")
  }
}

if (-Not $DisableTeX) {
  $texitems = @(Get-ChildItem "." -Filter *.tex)
  if (Test-Path -Path "./doc") {
    $texitems += @(Get-ChildItem "./doc" -Filter *.tex)
  }
  if (Test-Path -Path "./man") {
    $texitems += @(Get-ChildItem "./man" -Filter *.tex)
  }
  $texitems | Foreach-Object {
    $file_basename = $_.BaseName
    $file_directory = $_.Directory
    $file_fullname = $_.FullName
    if ($SkipMatching -ne "" -and $file_basename -match $SkipMatching) {
      Write-Host "Skipping $file_fullname"
      return
    }
    Write-Host "Building $file_fullname"
    Push-Location $file_directory
    $latexmk_args = " -synctex=1 -bibtex -pdf -interaction=nonstopmode -file-line-error ${file_directory}/${file_basename}.tex"
    $proc = Start-Process -NoNewWindow -PassThru -FilePath $LATEXMK_EXE -ArgumentList $latexmk_args
    $handle = $proc.Handle
    $proc.WaitForExit()
    $exitCode = $proc.ExitCode
    Pop-Location
    if (-Not ($exitCode -eq 0)) {
      MyThrow("Build failed! Exited with error code $exitCode.")
    }
  }
}

if($EnableSphinx) {
  Write-Host "Building Sphinx documentation"
  if (Test-Path -Path "./doc") {
    if (-Not(Test-Path -Path "./doc/_static")) {
      Write-Host "Creating _static directory"
      New-Item -ItemType Directory -Path "./doc/_static" | Out-Null
    }
    $sphinxbuild_args = " -M html ./doc ./doc_output "
    $proc = Start-Process -NoNewWindow -PassThru -FilePath $SPHINXBUILD_EXE -ArgumentList $sphinxbuild_args
    $handle = $proc.Handle
    $proc.WaitForExit()
    $exitCode = $proc.ExitCode
    if (-Not ($exitCode -eq 0)) {
      MyThrow("Build failed! Exited with error code $exitCode.")
    }
    if ($CreateSphinxPDF) {
      $sphinxbuild_args = " -M latex ./doc ./doc_output "
      $proc = Start-Process -NoNewWindow -PassThru -FilePath $SPHINXBUILD_EXE -ArgumentList $sphinxbuild_args
      $handle = $proc.Handle
      $proc.WaitForExit()
      $exitCode = $proc.ExitCode
      if (-Not ($exitCode -eq 0)) {
        MyThrow("Build failed! Exited with error code $exitCode.")
      }
      Push-Location "./doc_output/latex"
      $texitems = @(Get-ChildItem "." -Filter *.tex)
      $texitems | Foreach-Object {
        $file_basename = $_.BaseName
        Write-Host "Building $file_basename.tex"
        $pdflatex_args = " $file_basename.tex"
        #1st pass
        $proc = Start-Process -NoNewWindow -PassThru -FilePath $PDFLATEX_EXE -ArgumentList $pdflatex_args
        $handle = $proc.Handle
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
        if (-Not ($exitCode -eq 0)) {
          MyThrow("Build failed! Exited with error code $exitCode.")
        }
        #2nd pass
        $proc = Start-Process -NoNewWindow -PassThru -FilePath $PDFLATEX_EXE -ArgumentList $pdflatex_args
        $handle = $proc.Handle
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
        if (-Not ($exitCode -eq 0)) {
          MyThrow("Build failed! Exited with error code $exitCode.")
        }
        #3rd pass
        $proc = Start-Process -NoNewWindow -PassThru -FilePath $PDFLATEX_EXE -ArgumentList $pdflatex_args
        $handle = $proc.Handle
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
        if (-Not ($exitCode -eq 0)) {
          MyThrow("Build failed! Exited with error code $exitCode.")
        }
        #makeindex pass (suppress exit code as done in the sphinx build makefile)
        $makeindex_args = " -s python.ist '$file_basename.idx'"
        $proc = Start-Process -NoNewWindow -PassThru -FilePath $MAKEINDEX_EXE -ArgumentList $makeindex_args
        $handle = $proc.Handle
        $proc.WaitForExit()
        #4th pass
        $proc = Start-Process -NoNewWindow -PassThru -FilePath $PDFLATEX_EXE -ArgumentList $pdflatex_args
        $handle = $proc.Handle
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
        if (-Not ($exitCode -eq 0)) {
          MyThrow("Build failed! Exited with error code $exitCode.")
        }
        #5th pass
        $proc = Start-Process -NoNewWindow -PassThru -FilePath $PDFLATEX_EXE -ArgumentList $pdflatex_args
        $handle = $proc.Handle
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
        if (-Not ($exitCode -eq 0)) {
          MyThrow("Build failed! Exited with error code $exitCode.")
        }
        ##latexmk pass would be better but somehow it does not work and is not used by sphinx internally, so it's here for reference
        #$latexmk_args = " -f -synctex=1 -bibtex -pdf -interaction=nonstopmode -file-line-error ./$file_basename.tex"
        #$proc = Start-Process -NoNewWindow -PassThru -FilePath $LATEXMK_EXE -ArgumentList $latexmk_args
        #$handle = $proc.Handle
        #$proc.WaitForExit()
        #$exitCode = $proc.ExitCode
        #Pop-Location
        #if (-Not ($exitCode -eq 0)) {
        #  MyThrow("Build failed! Exited with error code $exitCode.")
        #}
      }
      Pop-Location
    }
  }
  else {
    Write-Host "No doc directory found, skipping Sphinx build" -ForegroundColor Yellow
  }
}

if ($CreateOverlay) {
  if ($OverlayOnTop) {
    $OverlayOperation = "stamp"
  }
  else {
    $OverlayOperation = "background"
  }
  $pdfitems = @(Get-ChildItem "." -Filter *.pdf)
  if (Test-Path -Path "./doc") {
    $pdfitems += @(Get-ChildItem "./doc" -Filter *.pdf)
  }
  if (Test-Path -Path "./man") {
    $pdfitems += @(Get-ChildItem "./man" -Filter *.pdf)
  }
  if (Test-Path -Path "./wiki") {
    $pdfitems += @(Get-ChildItem "./wiki" -Filter *.pdf)
  }
  if (Test-Path -Path "./doc_output/latex") {
    $pdfitems += @(Get-ChildItem "./doc_output/latex" -Filter *.pdf)
  }
  $pdfitems = @($pdfitems | Where-Object { $_ -notmatch "Overlay.pdf" })
  $OverlayPathPDF = Resolve-Path $OverlayPathPDF
  $pdfitems | Foreach-Object {
    $file_basename = $_.BaseName
    $file_directory = $_.Directory
    Push-Location $file_directory
    Write-Host "Adding overlay to $file_basename"
    $pdftk_args = " ${file_basename}.pdf $OverlayOperation $OverlayPathPDF output ${file_basename}_overlay.pdf"
    $proc = Start-Process -NoNewWindow -PassThru -FilePath $PDFTK_EXE -ArgumentList $pdftk_args
    $handle = $proc.Handle
    $proc.WaitForExit()
    $exitCode = $proc.ExitCode
    if (-Not ($exitCode -eq 0)) {
      MyThrow("Adding overlay failed! Exited with error code $exitCode.")
    }
    Pop-Location
  }
}

Write-Host "Build complete!" -ForegroundColor Green
Pop-Location

$ErrorActionPreference = "SilentlyContinue"
Stop-Transcript | out-null
$ErrorActionPreference = "Continue"
