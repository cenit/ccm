# Prerequisites for the code building

## WSL

You must be running Windows 10 version 2004 and higher (Build 19041 and higher) or Windows 11 to use the commands below (run in a Powershell with Administrator privileges):

```pwsh
wsl --install
```

This will install Ubuntu and setup everything that might be required. Then follow the instructions for Ubuntu

## Ubuntu

1) Define a work folder, which we will call WORKSPACE in this tutorial: this could be a "Code" folder in our home, a "c++" folder on our desktop, whatever you want. Create it if you don't already have, using your favourite method (mkdir in bash, or from the graphical interface of your distribution). We will now define an environment variable to tell the system where our folder is. Please note down the full path of this folder, which will look like `/home/$(whoami)/code/`

2) Open a Bash terminal and type the following commands (replace `/full/path/to/my/folder` with the previous path noted down)

```bash
echo -e "\n export WORKSPACE=/full/path/to/my/folder \n" >> ~/.bashrc
sudo apt-get update
sudo apt-get dist-upgrade
sudo apt-get install -y g++ cmake make git dos2unix ninja-build
```

## macOS

1) If not already installed, install the XCode Command Line Tools, typing this command in a terminal:

```bash
xcode-select --install
```

2) If not already installed, install Homebrew following the [official guide](https://brew.sh/index_it.html)

3) Open the terminal and type these commands

```bash
brew update
brew upgrade
brew install cmake make git dos2unix ninja
```

4) Define a work folder, which we will call WORKSPACE in this tutorial: this could be a "Code" folder in our home, a "c++" folder on our desktop, whatever you want. Create it if you don't already have, using your favourite method (mkdir in bash, or from the graphical interface in Finder). We will now define an environment variable to tell the system where our folder is. Please note down the full path of this folder, which will look like `/home/$(whoami)/code/`

5) Open a Terminal and type the following command (replace `/full/path/to/my/folder` with the previous path noted down)

```bash
echo -e "\n export WORKSPACE=/full/path/to/my/folder \n" >> ~/.zshenv
```

## Windows

1) Install or update Visual Studio to the latest version, making sure to have it fully patched (run again the installer if not sure to automatically update to latest version). If you need to install from scratch, download VS from here:

   - [Visual Studio 2022 Community (free for non-commercial use)](https://visualstudio.microsoft.com/thank-you-downloading-visual-studio/?sku=Community&channel=Release&version=VS2022)
   - [Visual Studio 2022 Professional (requires license)](https://visualstudio.microsoft.com/thank-you-downloading-visual-studio/?sku=Professional&channel=Release&version=VS2022)
   - [Visual Studio 2022 Build Tools (free)](https://visualstudio.microsoft.com/thank-you-downloading-visual-studio/?sku=BuildTools&channel=Release&version=VS2022)

Please make sure that these workloads are selected:

   - Desktop Development with C++
   - Linux and Embedded Development with C++

2) Open your Powershell with Administrator privileges, type the following command and confirm it:

```pwsh
PS \>             Set-ExecutionPolicy unrestricted
```

3) If you are not sure about having them updated, or even installed, please install `git`, `cmake`, `ninja` and an updated `Powershell`. To do so, open your Powershell with Administrator privileges and type

```pwsh
PS \>             winget install Microsoft.PowerShell
PS \>             winget install Git.Git
PS \>             winget install Kitware.CMake
PS \>             winget install Ninja-build.Ninja
```

4) Create a work folder (wherever you want on your computer) and a bin folder into your user profile, and then let's create an environment variable dedicated to the first and add the latter to the PATH. To do so, open a Powershell (as a standard user) and type

```pwsh
PS \>             mkdir $env:USERPROFILE\bin
PS \>             mkdir $env:USERPROFILE\code  # or wherever you want
PS \>             rundll32 sysdm.cpl,EditEnvironmentVariables
```

In the upper part of the window that pops-up, select the PATH variable, click on Edit, click on New and add the following string:

```cmd
%USERPROFILE%\bin
```

Again in the upper part of the window that pops-up, create a new environment variables with name `WORKSPACE` and value the full path noted down before.

1) Create a softlink to the `ninja` executable in the bin folder. To do so, open a Powershell (as a standard user) and type

```pwsh
PS \>             cmd /c mklink $env:USERPROFILE\bin\ninja.exe "$env:USERPROFILE\AppData\Local\Microsoft\WinGet\Packages\Ninja-build.Ninja_Microsoft.Winget.Source_8wekyb3d8bbwe\ninja.exe"
```

6) In case a proxy is present, then the following environment variables might require to be set. If no proxy is present, then for sure setup is already over.

Set environment variables `http_proxy` and `https_proxy` to proxy address and port.

Set environment variable `no_proxy` to the domains that have not to be accessed through proxy.

As an example, let's check the variable values with a proxy address `companyproxy.net` on port `9443` and internal domain `company.com`:

```pwsh
PS \> $env:http_proxy
http://companyproxy.net:9443
PS \> $env:https_proxy
http://companyproxy.net:9443
PS \> $env:no_proxy
localhost,company.com
```

Note: in case of errors such as:

```pwsh
error: RPC failed; curl 56 Failure when receiving data from the peer
```

The following settings could resolve:

```PowerShell
PS \ > git config --global http.postBuffer 524288000
PS \ > git config --global http.sslbackend openssl
```

The second setting is probably the most effective as the error is likely related to `winssl`.
