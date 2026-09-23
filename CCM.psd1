@{
    RootModule        = 'CCM.psm1'
    ModuleVersion     = '2.0.0'
    GUID              = '6b10cf41-295c-47f0-a3eb-d4e952c879c4'
    Author            = 'Stefano Sinigardi'
    CompanyName       = 'Stefano Sinigardi'
    Copyright         = '(c) Stefano Sinigardi. MIT License.'
    Description       = 'cenit CI/CD Modules (CCM): shared PowerShell utilities for build, deploy, and environment setup.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Get-ProgramFiles32Bit', 'Get-ProgramFiles64Bit', 'Write-CcmFatalError', 'Copy-TexFile', 'ConvertTo-UnixLineEnding', 'ConvertTo-WindowsLineEnding', 'Update-GitRepo', 'Install-CustomCaCert', 'Assert-AwsSsoSession', 'Install-RequirementsWithRetry', 'Enable-PythonVenv', 'Save-Ninja', 'Save-Aria2', 'Save-7Zip', 'Save-Licencpp', 'Get-VisualStudioPath', 'Get-VisualStudioVersion', 'Initialize-VisualStudioEnvironment', 'Initialize-PostgresEnvironment', 'Initialize-CcmLogging', 'Stop-CcmLogging', 'Test-IsContainerizedRepository', 'Add-IgnorePatternBlock', 'Write-CcmInfo', 'Write-CcmSuccess', 'Write-CcmWarning', 'Write-CcmError', 'Write-CcmStep', 'New-CcmEcsPreviewIdentity', 'Set-CcmEcsTaskDefinitionOverrides', 'Resolve-CcmContainerRuntime', 'Resolve-CcmEcsSecretArns', 'Get-CcmEcsLoadBalancerSpecs', 'Resolve-CcmEcsWebUiUrl', 'New-DynamoDbTaskPolicy', 'Get-CcmEcsDeployPolicyGaps', 'Get-CcmVenvBootstrapPackages', 'Get-CcmEcsTeardownPlan', 'ConvertFrom-CcmSkillRequirement', 'Test-CcmSkillDependencyGraph', 'New-CcmSkillNuspecContent', 'Get-CcmImageBuildArgs')
    AliasesToExport   = @(
        'activateVenv','getProgramFiles32bit','getProgramFiles64bit',
        'getLatestVisualStudioWithDesktopWorkloadPath',
        'getLatestVisualStudioWithDesktopWorkloadVersion',
        'setupVisualStudio','setupPostgres',
        'DownloadNinja','DownloadAria2','Download7Zip','DownloadLicencpp',
        'MyThrow','CopyTexFile','dos2unix','unix2dos','UpdateRepo'
    )
    VariablesToExport = @(
        'IsWindowsPowerShell', 'IsInGitSubmodule', '64bitPwsh', '64bitOS',
        'osArchitecture', 'vcpkgArchitecture', 'vsArchitecture',
        'ExecutableSuffix', 'utils_psm1_version',
        'cuda_version_full', 'cuda_version_short',
        'cuda_version_full_dashed', 'cuda_version_short_dashed'
    )
    CmdletsToExport   = @()
    FileList          = @('CCM.psm1', 'Public\Get-ProgramFiles32Bit.ps1', 'Public\Get-ProgramFiles64Bit.ps1', 'Public\Write-CcmFatalError.ps1', 'Public\Copy-TexFile.ps1', 'Public\ConvertTo-UnixLineEnding.ps1', 'Public\ConvertTo-WindowsLineEnding.ps1', 'Public\Update-GitRepo.ps1', 'Public\Install-CustomCaCert.ps1', 'Public\Assert-AwsSsoSession.ps1', 'Public\Install-RequirementsWithRetry.ps1', 'Public\Enable-PythonVenv.ps1', 'Public\Save-Ninja.ps1', 'Public\Save-Aria2.ps1', 'Public\Save-7Zip.ps1', 'Public\Save-Licencpp.ps1', 'Public\Get-VisualStudioPath.ps1', 'Public\Get-VisualStudioVersion.ps1', 'Public\Initialize-VisualStudioEnvironment.ps1', 'Public\Initialize-PostgresEnvironment.ps1', 'Public\Initialize-CcmLogging.ps1', 'Public\Stop-CcmLogging.ps1', 'Public\Test-IsContainerizedRepository.ps1', 'Public\Add-IgnorePatternBlock.ps1', 'Public\Write-CcmInfo.ps1', 'Public\Write-CcmSuccess.ps1', 'Public\Write-CcmWarning.ps1', 'Public\Write-CcmError.ps1', 'Public\Write-CcmStep.ps1', 'Public\New-CcmEcsPreviewIdentity.ps1', 'Public\Set-CcmEcsTaskDefinitionOverrides.ps1', 'Private\Set-LegacyAliases.ps1', 'Public\Resolve-CcmContainerRuntime.ps1', 'Public\Resolve-CcmEcsSecretArns.ps1', 'Public\Get-CcmEcsLoadBalancerSpecs.ps1', 'Public\Resolve-CcmEcsWebUiUrl.ps1', 'Public\New-DynamoDbTaskPolicy.ps1', 'Public\Get-CcmEcsDeployPolicyGaps.ps1', 'Public\Get-CcmVenvBootstrapPackages.ps1', 'Public\Get-CcmEcsTeardownPlan.ps1', 'Public\ConvertFrom-CcmSkillRequirement.ps1', 'Public\Test-CcmSkillDependencyGraph.ps1', 'Public\New-CcmSkillNuspecContent.ps1', 'Public\Get-CcmImageBuildArgs.ps1')
    PrivateData = @{
        PSData = @{
            Tags         = @('CCM', 'Build', 'DevOps', 'CMake', 'AWS')
            ProjectUri   = 'https://github.com/cenit/ccm'
            ReleaseNotes = 'See changelog.d/.'
        }
    }
}
