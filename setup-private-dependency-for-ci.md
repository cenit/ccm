# How to setup private repository dependency for CI compatibility

## Option A: Private Git Submodule in another repository

### 1) Make sure the pipeline identity can read repo B

Give the build service identity for project A read access to repo B:

- In **Project B → Repos → Repositories → (B) → Security**, add **`"Project A" Build Service (YourOrg)`** (or the collection-scoped build identity) with **Read**.  
- If your org uses **"Protect access to repositories in YAML pipelines"**, disable that protection (org/project setting).

### 2) Use the built-in checkout with token persistence and submodules enabled

```yaml
steps:
- checkout: self
  submodules: true       # or 'recursive' if you have nested submodules
  persistCredentials: true
  fetchDepth: 1          # optional, for speed
```

This tells the agent to keep the job access token in Git config and use it for submodules as well. [1](https://learn.microsoft.com/en-us/azure/devops/pipelines/yaml-schema/steps-checkout?view=azure-pipelines)

### 3) Point the submodule URL at Azure Repos using a *relative HTTPS path*

In your `.gitmodules`, prefer a relative URL so the same auth and host are reused:

```ini
[submodule "CCM"]
  path = CCM
  # If A and B are in the same Azure DevOps *project*:
  url = ../B

  # If they're in different projects within the same org (usually the case):
  url = ../../<ProjectB>/_git/<RepoB>
```

Azure Pipelines will automatically reuse the same credentials for relative private submodules hosted on the same service. (This is called out in the Pipelines "Checkout submodules" guidance and is a common fix.) [2](https://learn.microsoft.com/en-us/azure/devops/pipelines/repos/pipeline-options-for-git?view=azure-devops)

---

## Option B: Private library dependency in vcpkg registry

When using a private Azure DevOps repository through vcpkg (the registry itself, or a library in it, through `vcpkg-configuration.json`), vcpkg spawns its own git processes that don't inherit the checkout task's credentials. You need to explicitly inject the Azure Pipelines access token into git's global config.

### 1) Make sure the pipeline identity can read the private registry repo

Same as Option A step 1:

- In **Project B → Repos → Repositories → (PrivateRegistry) → Security**, add **`"Project A" Build Service (YourOrg)`** with **Read**.

### 2) Use the built-in checkout with token persistence

Same as Option A step 2:

```yaml
steps:
- checkout: self
  submodules: recursive
  persistCredentials: true
  fetchDepth: 1
```

### 3) Configure global git credentials for vcpkg

Add a PowerShell step **after checkout** to inject the `System.AccessToken` into git's global config so vcpkg can authenticate:

```yaml
- task: PowerShell@2
  displayName: 'Configure Git credentials for Vcpkg/Azure DevOps'
  inputs:
    targetType: 'inline'
    script: |
      # Configure git to authenticate with Azure DevOps for vcpkg git-fetch operations
      $pat = "$(System.AccessToken)"
      $basicAuth = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("PAT:$pat"))
      
      # Set the extraheader GLOBALLY so vcpkg's git invocations can use it
      git config --global http.https://dev.azure.com/.extraheader "AUTHORIZATION: basic $basicAuth"
      
      # Also set for the specific org URL pattern (replace my-org with your org)
      git config --global http.https://dev.azure.com/my-org/.extraheader "AUTHORIZATION: basic $basicAuth"
      
      # Force git to use full path for credentials (helps with registry/submodule auth)
      git config --global credential.useHttpPath true
      
      Write-Host "Git credentials configured globally for vcpkg operations"
```

### 4) Clean up credentials at the end of the pipeline

Since we modified the global git config, add a cleanup step at the end to remove credentials (important for self-hosted agents):

```yaml
- task: PowerShell@2
  displayName: 'Cleanup: Remove global git credentials'
  condition: always()
  inputs:
    targetType: 'inline'
    script: |
      # Remove the extraheader credentials we added for vcpkg
      Write-Host "Cleaning up global git config..."
      & git config --global --unset-all http.https://dev.azure.com/.extraheader 2>$null; $null
      & git config --global --unset-all http.https://dev.azure.com/my-org/.extraheader 2>$null; $null
      & git config --global --unset credential.useHttpPath 2>$null; $null
      Write-Host "Global git credentials removed"
      exit 0
```

### 5) (Optional) Pre-checkout cleanup for stale credentials

If a previous pipeline run failed before cleanup, stale credentials may interfere with the checkout task. Add a cleanup step **before** checkout:

```yaml
- task: PowerShell@2
  displayName: 'Pre-checkout: Clean stale git credentials'
  inputs:
    targetType: 'inline'
    script: |
      Write-Host "Cleaning any stale global git extraheader config..."
      & git config --global --unset-all http.extraheader 2>$null; $null
      & git config --global --unset-all http.https://dev.azure.com/.extraheader 2>$null; $null
      & git config --global --unset-all http.https://dev.azure.com/my-org/.extraheader 2>$null; $null
      & git config --global --unset-all http.https://my-org@dev.azure.com/.extraheader 2>$null; $null
      & git config --global --unset credential.useHttpPath 2>$null; $null
      
      $remaining = & git config --global --get-regexp ".*extraheader" 2>$null
      if ($remaining) {
        Write-Host "WARNING: Some extraheader entries remain:"
        Write-Host $remaining
      } else {
        Write-Host "Global git config is clean"
      }
      exit 0
- checkout: self
  # ... rest of checkout config
```

### vcpkg-configuration.json example

Your `vcpkg-configuration.json` should use the HTTPS URL format:

```json
{
  "registries": [
    {
      "kind": "git",
      "repository": "https://dev.azure.com/my-org/ProjectName/_git/RepoName",
      "baseline": "abc123...",
      "packages": ["your-private-package"]
    }
  ]
}
```

> **Note:** SSH URLs (`git@ssh.dev.azure.com:...`) won't work with HTTP extraheader authentication. Use HTTPS URLs.

---

## Troubleshooting

### "Git config still contains extraheader keys" warning at checkout

The global git config has stale entries from a previous run. Either:

- Add the pre-checkout cleanup step (Option B, step 5)
- Manually clean the agent: `git config --global --unset-all http.extraheader`

### vcpkg git-fetch fails with "terminal prompts disabled"

The credentials aren't reaching vcpkg's git invocations. Ensure:

- You're using `--global` (not `--local`) for the git config
- The URL patterns match your Azure DevOps org
- The step runs **after** checkout but **before** the build step that triggers vcpkg
