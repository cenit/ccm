# cenit CI/CD Modules (CCM)

A comprehensive collection of build automation, continuous integration and development environment setup tools. This repository provides cross-platform build scripts, CMake modules and deployment automation for various development environments.

## Build Automation Scripts

### Core Build Scripts

- **`build.ps1`** - Main CMake build automation script with extensive feature toggles (CUDA, OpenCV, OpenMP, VTK, etc.)
- **`build-doc.ps1`** - Documentation generation with PDF overlay support
- **`build-ort.ps1`** - OSS Review Toolkit build script automation
- **`build-tc.ps1`** - TwinCAT specific build processes

### Clean-up Scripts

- **`clean.ps1`** - General project cleanup
- **`clean-doc.ps1`** - Documentation build artifacts cleanup

## Development Environment Setup

### Cross-Platform Setup

- **`setup_eng.md`** - Comprehensive environment setup guide (Windows/WSL/Ubuntu/macOS)
- **`setup_vcpkg.md`** - vcpkg package manager setup instructions
- **`setup_ros.sh`** - ROS (Robot Operating System) environment setup
- **`setup-venv.ps1`** - Python virtual environment automation

### Profile Scripts

- **`Microsoft.PowerShell_profile.ps1`** - PowerShell profile customization
- **`Microsoft.VSCode_profile.ps1`** - VS Code PowerShell profile

## Deployment & DevOps

### Deployment Scripts

- **`deploy-templates.ps1`** - Project template deployment

### Security & Network

- **`open-fw-exe.ps1`** / **`close-fw-rule.ps1`** - Windows Firewall management
- **`enable-administrative-shares.ps1`** / **`disable-administrative-shares.ps1`** - Windows administrative shares toggle
- **`enable-iis.ps1`** / **`disable-iis.ps1`** - IIS service management

## Specialized Industrial Software Integration

### Machine Vision & Imaging

- **`minting-labview.ps1`** - LabVIEW environment setup

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

- **`utils.psm1`** - PowerShell utility module with system detection, Git operations, and environment management
- **`ort-config.yml`** - OSS Review Toolkit configuration

## Prerequisites

Refer to `setup_eng.md` for detailed environment setup instructions covering:

- Windows 10/11 with WSL2
- Ubuntu/Debian Linux distributions  
- macOS development environments
- Required toolchains and dependencies
