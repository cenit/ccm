#!/usr/bin/env pwsh

<#

.SYNOPSIS
        deploy-linux-vm
        Created By: Stefano Sinigardi
        Created Date: May 26, 2022
        Last Modified Date: May 26, 2022

.DESCRIPTION
Deploy a VM on Azure

.PARAMETER DisableInteractive
Disable script interactivity (useful for CI runs)

.PARAMETER ResourceGroupName
Azure resource group to deploy into

.PARAMETER StorageAccountName
Azure storage account name (globally unique, lowercase)

.PARAMETER VNetName
Virtual network name

.PARAMETER SubnetName
Subnet name

.EXAMPLE
.\deploy-linux-vm -DisableInteractive -ResourceGroupName my-rg -StorageAccountName mystorageacct

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
  [string]$ResourceGroupName = "my-rg",
  [string]$StorageAccountName = "mystorageacct",
  [string]$VNetName = "my-vnet",
  [string]$SubnetName = "my-subnet"
)

$global:DisableInteractive = $DisableInteractive

$deploy_linux_vm_version = "0.0.2"

Import-Module -Name $PSScriptRoot/utils.psm1 -Force

$ccmLog = Initialize-CcmLogging
trap { Stop-CcmLogging $ccmLog; break }


Write-Host "Build script version ${deploy_linux_vm_version}, utils module version ${utils_psm1_version}"

Write-Host -NoNewLine "PowerShell version:"
$PSVersionTable.PSVersion

if ($IsWindowsPowerShell) {
  Write-Host "Running on Windows Powershell, please consider update and running on newer Powershell versions"
}

if ($PSVersionTable.PSVersion.Major -lt 5) {
  MyThrow("Your PowerShell version is too old, please update it.")
}

# Input Variables
$RGName = $ResourceGroupName
$SAName = $StorageAccountName.ToLower()
$SubnetRange = "10.0.0.0/24"
$VNetRange = "10.0.0.0/20"
$PublicIPName = "centos75-xilinx2019-ip"
$NSGName = "centos75-xilinx2019-nsg"
$NICName = "centos75-xilinx2019-nic"
$ComputerName = "centos75-xilinx2019-pc"
$VMName = "centos75-xilinx2019-vm"
$VMSize = "Standard_D2ads_v5"
$VMImage = "*/CentOS/Skus/7.5"
$VMOS = "Linux"
$Location = "West Europe"

# Create a new resource group
Write-Output -InputObject "Creating resource group"
New-AzResourceGroup -Name $RGName -Location $Location

## Create storage resources

# Create a new storage account
Write-Output -InputObject "Creating storage account"
$StorageAccount = New-AzStorageAccount -Location $Location -ResourceGroupName $RGName -Type "Standard_LRS" -Name $SAName

## Create network resources

# Create a subnet configuration
Write-Output -InputObject "Creating virtual network"
$SubnetConfig = New-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $SubnetRange

# Create a virtual network
$VirtualNetwork = New-AzVirtualNetwork -ResourceGroupName $RGName -Location $Location -Name $VNetName -AddressPrefix $VNetRange -Subnet $SubnetConfig

# Create a public IP address
Write-Output -InputObject "Creating public IP address"
$PublicIP = New-AzPublicIpAddress -ResourceGroupName $RGName -Location $Location -AllocationMethod "Dynamic" -Name $PublicIPName

# Create network security group rule (SSH or RDP)
Write-Output -InputObject "Creating SSH/RDP network security rule"
$SecurityGroupRule = switch ("-$VMOS") {
  "-Linux" {
    New-AzNetworkSecurityRuleConfig -Name "SSH-Rule" -Description "Allow SSH" -Access "Allow" -Protocol "TCP" -Direction "Inbound" -Priority 100 -DestinationPortRange 22 -SourceAddressPrefix "*" -SourcePortRange "*" -DestinationAddressPrefix "*"
  }
  "-Windows" {
    New-AzNetworkSecurityRuleConfig -Name "RDP-Rule" -Description "Allow RDP" -Access "Allow" -Protocol "TCP" -Direction "Inbound" -Priority 100 -DestinationPortRange 3389 -SourceAddressPrefix "*" -SourcePortRange "*" -DestinationAddressPrefix "*"
  }
}

# Create a network security group
Write-Output -InputObject "Creating network security group"
$NetworkSG = New-AzNetworkSecurityGroup -ResourceGroupName $RGName -Location $Location -Name $NSGName -SecurityRules $SecurityGroupRule

# Create a virtual network card and associate it with the public IP address and NSG
Write-Output -InputObject "Creating network interface card"
$NetworkInterface = New-AzNetworkInterface -Name $NICName -ResourceGroupName $RGName -Location $Location -SubnetId $VirtualNetwork.Subnets[0].Id -PublicIpAddressId $PublicIP.Id -NetworkSecurityGroupId $NetworkSG.Id

## Create the virtual machine

# Define a credential object to store the username and password for the virtual machine

$Username = Read-Host -Prompt 'Input username for VM to be created'
$Password = Read-Host -Prompt 'Input password for VM to be created' | ConvertTo-SecureString -Force -AsPlainText
$Credential = New-Object -TypeName PSCredential -ArgumentList ($Username, $Password)

# Create the virtual machine configuration object
$VirtualMachine = New-AzVMConfig -VMName $VMName -VMSize $VMSize

# Set the VM Size and Type
$VirtualMachine = Set-AzVMOperatingSystem -VM $VirtualMachine -Linux -ComputerName $ComputerName -Credential $Credential

# Enable the provisioning of the VM Agent
if ($VirtualMachine.OSProfile.WindowsConfiguration) {
  $VirtualMachine.OSProfile.WindowsConfiguration.ProvisionVMAgent = $true
}

# Get the VM Source Image
$Image = Get-AzVMImagePublisher -Location $Location | Get-AzVMImageOffer | Get-AzVMImageSku | Where-Object -FilterScript { $_.Id -like $VMImage }

# Set the VM Source Image
$VirtualMachine = Set-AzVMSourceImage -VM $VirtualMachine -PublisherName $Image.PublisherName -Offer $Image.Offer -Skus $Image.Skus -Version "latest"

# Add Network Interface Card
$VirtualMachine = Add-AzVMNetworkInterface -Id $NetworkInterface.Id -VM $VirtualMachine

# Set the OS Disk properties
$OSDiskName = "OsDisk"
$OSDiskUri = "{0}vhds/{1}-{2}.vhd" -f $StorageAccount.PrimaryEndpoints.Blob.ToString(), $VMName.ToLower(), $OSDiskName

# Applies the OS disk properties
$VirtualMachine = Set-AzVMOSDisk -VM $VirtualMachine -Name $OSDiskName -VhdUri $OSDiskUri -CreateOption "FromImage"

# Create the virtual machine.
Write-Output -InputObject "Creating virtual machine"
$NewVM = New-AzVM -ResourceGroupName $RGName -Location $Location -VM $VirtualMachine
$NewVM
Write-Output -InputObject "Virtual machine created successfully"

Stop-CcmLogging $ccmLog
