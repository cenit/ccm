# Cenit-CMake-Modules

These files collectively support the continuous integration and deployment processes, build automation, and environment setup for the project.

## build.ps1

This PowerShell script is used to build the project using CMake. It includes various parameters to customize the build process, such as enabling or disabling features like CUDA, OpenCV, OpenMP, and more. It also includes options to force specific versions of libraries and to disable automatic DLL deployment.

## build-doc.ps1

This PowerShell script is used to build documentation for the project. It provides functions to locate all necessary tools for the scope and has the possibility to handle automatic overlays to PDF files.

## utils.psm1

This PowerShell module contains utility functions used across the project. It includes functions to detect the system architecture, check if the project is in a Git submodule, and activate a Python virtual environment. The module also includes commands to handle Git operations and manage the script's execution environment.
