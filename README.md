# cenit CI/CD Modules (CCM)

A comprehensive collection of build automation, continuous integration and development environment setup tools. This repository provides cross-platform build scripts, CMake modules and deployment automation for various development environments.

## Documentation

- **[`setup_eng.md`](setup_eng.md)** - Cross-platform environment setup guide (Windows/WSL2/Ubuntu/macOS)
- **[`setup_vcpkg.md`](setup_vcpkg.md)** - vcpkg package manager setup and NuGet binary caching

## Build Automation Scripts

### Core Build Scripts

- **`build.ps1`** - Main CMake build automation script with extensive feature toggles (CUDA, CUDNN, OpenCV, OpenMP, VTK, PCL, Qt, testing). Handles vcpkg integration, compiler setup (Visual Studio/Clang), Ninja build system, and installer creation
- **`build-doc.ps1`** - Documentation generation using Pandoc and LaTeX with PDF overlay support and mermaid diagram conversion
- **`build-ort.ps1`** - OSS Review Toolkit report generation for license assessment with Licencpp analysis and vcpkg integration
- **`build-tc.ps1`** - TwinCAT specific build processes automation

### Clean-up Scripts

- **`clean.ps1`** - General project cleanup
- **`clean-doc.ps1`** - Documentation build artifacts cleanup

## Development Environment Setup

### Cross-Platform Setup

- **`setup_ros.sh`** - ROS Foxy environment setup for Ubuntu 20.04 with Orocos KDL (requires root privileges)
- **`setup-venv.ps1`** - Python virtual environment automation supporting requirements.txt and pyproject.toml with retry logic for network resilience

### Profile Scripts

- **`Microsoft.PowerShell_profile.ps1`** - PowerShell profile customization with terminal setup, aliases, and optional oh-my-posh styling
- **`Microsoft.VSCode_profile.ps1`** - VS Code PowerShell profile customization

## Deployment & DevOps

### Deployment Scripts

- **`deploy-templates.ps1`** - Project template deployment automation

### Security & Network

- **`open-fw-exe.ps1`** / **`close-fw-rule.ps1`** - Windows Firewall management for executables (requires Administrator)
- **`enable-administrative-shares.ps1`** / **`disable-administrative-shares.ps1`** - Windows administrative shares (C$, D$, etc.) toggle
- **`enable-iis.ps1`** / **`disable-iis.ps1`** - IIS service management with optional directory browsing configuration (requires Administrator)

## Specialized Industrial Software Integration

### Machine Vision & Industrial Automation

- **`minting-labview.ps1`** - LabVIEW environment setup and uninstall management for multiple versions (IDE and Runtime) with NI Package Manager integration

### Testing

- **`verify-test-log.ps1`** - Test log verification utility

## CMake Modules & Functions

### Find Modules (`Modules/`)

#### Scientific Computing & Mathematics

- **`FindFFTW.cmake`** - Fast Fourier Transform library detection
- **`FindMKL.cmake`** - Intel Math Kernel Library integration
- **`FindMEEP.cmake`** - MIT Electromagnetic Equation Propagation package

#### Computer Vision & Graphics

- **`FindAravis.cmake`** - Real-time video acquisition library for industrial cameras

#### Networking & Communication

- **`FindCURLpp.cmake`** - C++ wrapper for libcurl
- **`FindLibSSH.cmake`** - SSH protocol library
- **`FindUriParser.cmake`** - URI parsing library

#### Data Processing & Formats

- **`FindKML.cmake`** - Keyhole Markup Language support
- **`FindLibXmlpp.cmake`** - C++ XML processing library
- **`FindMiniZip.cmake`** - ZIP archive manipulation
- **`Findsqlite3.cmake`** - SQLite database engine
- **`FindShapelib.cmake`** - ESRI Shapefile format library

#### Geospatial & Mapping

- **`FindGRASS.cmake`** - Geographic Resources Analysis Support System

#### System Libraries & Performance

- **`FindATL.cmake`** - Active Template Library (Windows)
- **`FindTBB.cmake`** - Intel Threading Building Blocks
- **`FindNuma.cmake`** - Non-Uniform Memory Access optimization
- **`FindLibRt.cmake`** - Real-time extensions library

#### Scientific & Engineering Libraries

- **`FindLibgraflib.cmake`** - Graphics library component
- **`FindLibgrafX11.cmake`** - X11 graphics library component
- **`FindLibkernlib.cmake`** - Kernel library component
- **`FindLibmathlib.cmake`** - Mathematical library component
- **`FindLibpacklib.cmake`** - Package library component
- **`FindLibphtools.cmake`** - Physics tools library component

#### Platform-Specific Modules (`msys2/`)

- **`FindMPI.cmake`** - Message Passing Interface for MSYS2 environment

### CMake Functions (`Functions/`)

#### Build & Deployment Automation

- **`DeployQTAtBuild.cmake`** - Qt framework deployment automation during build process
- **`FixDriverProj.cmake`** - Driver project configuration and fixes

### Additional Modules

#### Extra Find Modules (`Extras/`)

- **`FindSDL2.cmake`** - Simple DirectMedia Layer 2.0 for multimedia applications

#### Deprecated Modules (`Deprecated/`)

- **`FindCUDNN.cmake`** - NVIDIA CUDA Deep Neural Network library (deprecated)
- **`FindFLTK.cmake`** - Fast Light Toolkit GUI library (deprecated)
- **`FindLibLZMA.cmake`** - LZMA compression library (deprecated)
- **`FindPThreads4W.cmake`** - POSIX Threads for Windows (deprecated)
- **`FindStb.cmake`** - STB single-file public domain libraries (deprecated)

## Utility Modules

### Core Utilities

- **`utils.psm1`** - Core PowerShell utility module providing:
  - System detection (Windows PowerShell vs Core, 32/64-bit architecture)
  - Visual Studio discovery and environment setup
  - PostgreSQL installation detection and setup
  - Python virtual environment activation
  - Pip installation with retry logic (handles proxy throttling)
  - Utility functions for downloading tools (Ninja, Aria2, licencpp, 7-Zip)
  - Line ending conversion (dos2unix/unix2dos)
  - Repository management and git submodule operations

### Configuration Files

- **`ort-config.yml`** - OSS Review Toolkit configuration for license assessment

