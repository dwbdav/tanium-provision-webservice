<#PSScriptInfo

.VERSION 2.7

.GUID 1e96ce54-37d3-4fbd-bedf-eab77120f940

.AUTHOR Tanium

.COMPANYNAME Tanium

.COPYRIGHT Copyright (c) Tanium

.TAGS

.LICENSEURI

.PROJECTURI

.ICONURI

.EXTERNALMODULEDEPENDENCIES

.REQUIREDSCRIPTS

.EXTERNALSCRIPTDEPENDENCIES

.RELEASENOTES
Version 0.9: Initial version, supports UEFI booting only
Version 1.0: Changed to use Tanium PXE server
Version 1.1: Added ISO support
Version 1.2: Updated error handling logic
Version 1.3: Added settings logic, moved grub.cfg file to server (downloaded)
Version 2.0: When using a removable drive, partition it to hold content
Version 2.1: Add BitLocker encryption option for USB media
Version 2.2: Added logic to deal with USB keys larger than 32GB
Version 2.3: Add WIM output and input modes
Version 2.4: Add support for the boot image in Provision tools 10.4
Version 2.5: Add support for boot image lockdown options in Provision tools 10.4
Version 2.6: Support download changes in Provision PXE Service
Version 2.7: Include the Provision tools version in the signed script

.PRIVATEDATA

#>

<#

.DESCRIPTION
Create USB boot or ISO media for Tanium Provision.  The specified TPXEHost and port will be used to
download the needed content, as well as when booting from the resulting media.  If you want to use a
different host when booting (e.g. for internet-facing scenarios, or when you want the media to be
used at a different location), you can specify a different AnchorHost and AnchorPort value.
.PARAMETER TPXEHost
The Tanium PXE Host server that should be used, typically specified by IP address or host name.
.PARAMETER DiskImage
The previously-created WIM file contianing a Tanium Provision Disk image
.PARAMETER Destination
The ISO or WIM file to create, or the USB drive (e.g. "G:") to be populated. If specifying a USB key, it will be reformatted, destroying the current contents.  The colon should always be included.
.PARAMETER TPXEPort
The port number that Tanium PXE is using for HTTPS/TLS connections, default 17530.
.PARAMETER AnchorHost
The host name to be used when booting from the USB key.  If not specified, the specified Tanium PXE server (-TPXEHost) will be used.
.PARAMETER AnchorPort
The port number that should be used, with the AnchorHost, when booting from the USB key, default 443.
.PARAMETER Architecture
The USB key architecture, typically "x64" (also the default).  "arm64" could also be specified (not yet supported).
.PARAMETER Bundles
An array of bundle IDs to include on the bootable media.  This media can be used without contacting a Tanium PXE server.
.PARAMETER BitLockerPassword
The password that should be used to unlock the data volume.  This only applies to USB media.
.PARAMETER Used
Switch to specify to only encrypt used space.

.EXAMPLE
.\USBKey.ps1 -TPXEHost 192.0.2.10 -Destination D:

Gets the boot content from the Tanium PXE server at the specified IP address, and write to the USB key at D:.  (The port defaults to 17530.)
.EXAMPLE
.\USBKey.ps1 -TPXEHost 192.0.2.10 -Destination C:\Media.iso

Gets the boot content from the Tanium PXE server at the specified IP address, and write to the ISO at C:\Media.iso.  (The port defaults to 17530.)
.EXAMPLE
.\USBKey.ps1 -TPXEHost 192.0.2.10 -AnchorHost 192.0.2.20 -Destination D:

Gets the USB content from the Tanium PXE server at the specified TPXEHost IP address, but configure the USB key to pull content from an alternate location when booting by specifying the AnchorHost value.
.EXAMPLE
.\USBKey.ps1 -TPXEHost 192.0.2.10 -Destination D: -Bundles 78,79,80

Creates a bootable USB key, partitioning into two volumes: one for booting and the other to hold the content for the specified bundles.  This media will show only those bundles, since other bundles would not have the needed content.
#>
param(
    [Parameter(Mandatory=$true)]
	[Alias("DiskImage")]
    [string] $TPXEHost,
	[Parameter(Mandatory=$true)][string] $Destination,
    [Parameter(Mandatory=$false)][string] $TPXEPort = "17530",
    [Parameter(Mandatory=$false)][string] $AnchorHost = "",
    [Parameter(Mandatory=$false)][string] $AnchorPort = "17530",
    [Parameter(Mandatory=$false)][string] $Architecture = "x64",
    [Parameter(Mandatory=$false)][string] $TaniumSettings = "{}",
    [Parameter(Mandatory=$false)][int[]] $Bundles = $null,
    [Parameter(Mandatory=$false)][SecureString] $BitLockerPassword = $null,
    [Parameter(Mandatory=$false)][switch] $Used,
    [Parameter(Mandatory=$false)][switch] $Force
)

Write-Host "USBKey.ps1 10.9.71.0"

# Constants
$Label = "PROVISION"
$DataLabel = "PROV-DATA"

# Stop on errors
$ErrorActionPreference = "stop"

#Set up some state variables
$InputMode = "TPXE"
$BundlesIncluded = $PSBoundParameters.ContainsKey("Bundles")

try {
    [pscustomobject]$TaniumSettings = ConvertFrom-Json $TaniumSettings
} catch {
    throw "Invalid JSON in -TaniumSettings: $_"
}

#Handle DiskImage parameter, without breaking default prompt for TPXEHost/Destination
if ($MyInvocation.Line -match "(\s-diskimage\s)") {
    $DiskImage = $TPXEHost
    $TPXEHost = ""
    $InputMode = "DiskImage"
    $Image = Get-WindowsImage -ImagePath $DiskImage
    if ( $image.ImageName -contains $DataLabel ) {
        $BundlesIncluded = $true
    }
}

function Merge-Object
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [System.Management.Automation.PSObject]$Target,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSObject]$Source
    )

    $Source.PSObject.Properties | ForEach-Object {
        if ( Get-Member -InputObject $Target -name $_.Name -Membertype Properties ) {
            if( $_.TypeNameOfValue -eq 'System.Management.Automation.PSCustomObject' ) {
                Merge-Object -Target $target."$($_.Name)" -Source $_.Value
            } else {
                $Target."$($_.Name)" = $_.Value
            }
        } else {
            $Target | Add-Member -MemberType $_.MemberType -Name $_.Name -Value $_.Value -Force
        }
    }

    return $Target
}

function Get-TaniumSettings {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $cmdLine
    )

    $SettingsMarker = "TaniumSettings="

    $idx = $cmdLine.IndexOf($SettingsMarker, [System.StringComparison]::InvariantCultureIgnoreCase)
    if ( $idx -ge 1 ) {
        $taniumSettings = $cmdline.Substring($idx + $SettingsMarker.Length)
        $tmpSettings = $taniumSettings.trim("`"")
        if ( $tmpSettings -eq '$settings$' ) {
            return "{}"
        }

        return $tmpSettings
    }
    return "{}"
}

function Replace-TaniumSettings {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $cmdLine,
        [Parameter(Mandatory=$true)]
        [string]
        $TaniumSettings
    )

    $SettingsMarker = "TaniumSettings="

    $idx = $cmdLine.IndexOf($SettingsMarker, [System.StringComparison]::InvariantCultureIgnoreCase)
    if ( $idx -ge 1 ) {
        $cmdLine = $cmdLine.Substring(0, $idx + $SettingsMarker.Length)
        $cmdLine += "`"$TaniumSettings`""
    }

    return $cmdLine
}


# Determine USB vs. ISO vs. WIM
try {
    $outputMode = "usb"
    $kitsRoot = ""
    if ($Destination.ToLower().EndsWith(".iso")) {
        $outputMode = "iso"
    } elseif ($Destination.ToLower().EndsWith(".wim")) {
        $outputMode = "wim"
    }

    if ( ( $inputmode -eq "DiskImage" ) -and ( $outputMode -ne "USB" ) ) {
        throw "When providing a WIM DiskImage, the destination must be a Removable Drive"
    }

    if ($outputMode -eq "iso") {
        # Create a temporary folder to hold the ISO content
        $parent = [System.IO.Path]::GetTempPath()
        [string] $name = [System.Guid]::NewGuid()
        $contentDir = (Join-Path $parent $name)
        $dataDir = $contentDir
        New-Item -ItemType Directory -Path $contentDir | Out-Null

        # Find the ADK
        try
        {
            if (Test-Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots") {
                $kitsRoot = Get-ItemPropertyValue -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows Kits\Installed Roots" -Name KitsRoot10
            }
            else {
                $kitsRoot = Get-ItemPropertyValue -Path "HKLM:\Software\Microsoft\Windows Kits\Installed Roots" -Name KitsRoot10
            }
        }
        catch
        {
            throw "ADK is not installed."
        }
    } elseif ( $outputMode -eq "wim" ) {
        $parent = [System.IO.Path]::GetTempPath()
        [string] $name = [System.Guid]::NewGuid()
        $basedir = (Join-Path $parent $name)
        $contentDir = (Join-Path $basedir "boot")
        $dataDir = $contentDir
        New-Item -ItemType Directory -Path $contentDir | Out-Null

        # If bundles are specified, we need two separate directories
        if ($BundlesIncluded) {
            $dataDir = (Join-Path $basedir "data")
            New-Item -ItemType Directory -Path $dataDir | Out-Null
        }
    } elseif ( $outputMode -eq "usb" ) {
        # For USB, make sure the volume is removable
        $drive = Get-Volume -DriveLetter $Destination.Substring(0, 1)
        if ($drive.DriveType -ne 'Removable') {
            throw "You must specify a removable drive"
        }
        if ($drive.Size -eq 0) {
            Write-Warning "Removable drive size cannot be determined."
        } elseif ($drive.Size -lt 1000MB) {
            throw "Specified volume $($Destination.Substring(0, 1)) may be too small, minimum 1GB is recommended."
        }

        # Find the disk corresponding to the drive letter specified
        $disk = $drive | Get-Partition | Get-Disk | Select-Object -Unique
        if ($null -eq $disk) {
            throw "Unable to find the disk corresponding to the specified drive letter"
        }

        # If bundles are specified, we'll take over the whole drive
        if ( $BundlesIncluded ) {
            # Make sure we can load the BitLocker module if we need to encrypt.  It is installed
            # by default on Windows 10/11, but not on Windows Server.  It can be installed using:
            #   Install-WindowsFeature BitLocker -IncludeAllSubFeature -IncludeManagementTools -Restart
            # And yes, the restart is necessary.
            if ($null -ne $BitLockerPassword) {
                $module = Import-Module BitLocker -Passthru -DisableNameChecking -ErrorAction SilentlyContinue
                if ($null -eq $module) {
                    throw "BitLocker module is not available, may need to be installed as an optional feature."
                }
            }

            # If we're debugging, we won't reformat/repartition the disk
            if ($PSCmdlet.MyInvocation.BoundParameters["Debug"].IsPresent) {
                # Note that this assumes both volumes have drive letters assigned.
                $vols = $disk | Get-Partition | Get-Volume
                $bootVolume = $vols | Where-Object { $_.FileSystemLabel -eq $Label }
                $dataVolume = $vols | Where-Object { $_.FileSystemLabel -eq $DataLabel }
            } else {
                # Partition it
                Clear-Disk -Number $disk.Number -RemoveData -RemoveOEM
                Initialize-Disk -Number $disk.Number -PartitionStyle GPT -ErrorAction SilentlyContinue
                $bootPart = New-Partition -DiskNumber $disk.Number -AssignDriveLetter -Size 2GB
                $dataPart = New-Partition -DiskNumber $disk.Number -AssignDriveLetter -UseMaximumSize
                $bootVolume = Format-Volume -DriveLetter $bootPart.DriveLetter -FileSystem FAT32 -NewFileSystemLabel $Label -Force
                $dataVolume = Format-Volume -DriveLetter $dataPart.DriveLetter -FileSystem NTFS -NewFileSystemLabel $DataLabel -Force
                if ($null -ne $BitLockerPassword) {
                    if ($used) {
                        $v = Enable-BitLocker -MountPoint "$($dataPart.DriveLetter):\" -PasswordProtector -Password $BitLockerPassword -SkipHardwareTest -UsedSpaceOnly
                    } else {
                        $v = Enable-BitLocker -MountPoint "$($dataPart.DriveLetter):\" -PasswordProtector -Password $BitLockerPassword -SkipHardwareTest
                    }
                    do {
                        Write-Host "Waiting for BitLocker encryption to complete, $($v.EncryptionPercentage)% complete."
                        Start-Sleep -Seconds 2
                        $v = Get-BitLockerVolume -MountPoint "$($dataPart.DriveLetter):\"
                    } while ($v.VolumeStatus -ne "FullyEncrypted")
                }
            }
        } else {
            # Format the USB key as FAT32 and set the label
            if ($disk.Size -ge 32GB) {
                # Re-partition disk with a 32GB partition
                Clear-Disk -Number $disk.Number -RemoveData -RemoveOEM
                Initialize-Disk -Number $disk.Number -PartitionStyle GPT -ErrorAction SilentlyContinue
                $bootPart = New-Partition -DiskNumber $disk.Number -AssignDriveLetter -Size 32GB
                $bootVolume = Format-Volume -DriveLetter $bootPart.DriveLetter -FileSystem FAT32 -NewFileSystemLabel $Label -Force
            } else {
                try {
                    $bootVolume = Format-Volume -DriveLetter $Destination.Substring(0, 1) -FileSystem FAT32 -NewFileSystemLabel $Label
                } catch {
                    throw "Format failed.  This can be caused by the drive being too large.`nIf this is the case, manually create a volume on the drive using Disk Management that is a maximum of 32GB in size."
                }
            }
            $dataVolume = $bootVolume
        }
        $contentDir = "$($bootVolume.DriveLetter):"
        $dataDir = "$($dataVolume.DriveLetter):"
    }
    Write-Host "Using content directory: $contentDir"
    if ( $BundlesIncluded ) {
        Write-Host "Using data directory: $dataDir"
    }

    # Logic to trust all certs (ignore TLS errors from Tanium PXE)
    class TrustAllCertsPolicy : System.Net.ICertificatePolicy {
        [bool]CheckValidationResult([system.net.ServicePoint]$srvPoint, [X509Certificate]$certificate, [System.Net.WebRequest]$request, [int]$CertificateProblem){
            return $true
        }
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

    if ($InputMode -eq "TPXE") {
        # Download the needed boot files
        Write-Host "Downloading boot files."
        if (-not (Test-Path "$contentDir\LiveOS")) {
            MkDir "$contentDir\LiveOS" | Out-Null
        }
        $webClient = New-Object System.Net.WebClient
        @("$Architecture/initrd.img","$Architecture/squashfs.img","$Architecture/vmlinuz","$Architecture/efiboot.zip","$Architecture/iso.img","grub-media.cfg") | ForEach-Object {
            $url = "https://$($TPXEHost):$TPXEPort/cache/default/$_"
            $d = "$contentDir\$(Split-Path -Leaf $_)"
            if ($_ -eq "$Architecture/squashfs.img") {
                $d = "$contentDir\LiveOS\$(Split-Path -Leaf $_)"
            }
            Write-Host "Downloading: $url to $d"
            $webClient.DownloadFile($url, $d)
            if ($_ -eq "$Architecture/efiboot.zip") {
                Expand-Archive -Path "$contentDir\$(Split-Path -Leaf $_)" -DestinationPath "$contentDir\" -Force
                Remove-Item "$contentDir\$(Split-Path -Leaf $_)" -Force
            }
        }

        # Get the template grub.cfg and edit the variables
        if ($AnchorHost -eq "") {
            # If no anchor host was specified, we'll use the TPXEHost and Port values
            $AnchorHost = $TPXEHost
            $AnchorPort = $TPXEPort
        }
        $originalContent = Get-Content "$contentDir\grub-media.cfg"
        $anchorHostAndPort = "https://${AnchorHost}:${AnchorPort}"

        # This replaces everything after taniumosd= till the next whitespace with anchorHostAndPort
		$originalContent = $originalContent -replace "(taniumosd=)[^\s]+", "`$1$anchorHostAndPort"
        $originalContent = $originalContent.Replace("`$label$", $Label)
        $content = @()
        foreach ( $line in $originalContent ) {
            if ( $line -match "^\s+linux" ) {
                $originalSettings = "{}" | ConvertFrom-Json
                $newSettings = $originalSettings
                try {
                    $OriginalSettings = [uri]::UnescapeDataString((Get-TaniumSettings -cmdLine $line)) | ConvertFrom-Json
                } catch {
                    Write-Warning "Could not parse settings from grub-media.cfg from JSON: $_".
                }
                try {
                    $newSettings = Merge-Object -Source $TaniumSettings -Target $originalSettings
                } catch {
                    Write-Warning "Could not merge -TaniumSettings to the settings from grub-media.cfg: $_".
                }

                $encodedSettings = [uri]::EscapeDataString(($newSettings | ConvertTo-Json -Compress -Depth 5))
                $content += Replace-TaniumSettings -cmdLine $line -TaniumSettings $encodedSettings
            } else {
                $content += $line
            }
        }

        # Write out the file and remove the template
        $grubCfgFile = "$contentDir\EFI\Boot\grub.cfg"
        $content | Out-File -FilePath $grubCfgFile -Force -Encoding ascii
        Remove-Item "$contentDir\grub-media.cfg"
        $grubDir = mkdir "$contentDir\boot\grub"
        Copy-Item -Path $grubCfgFile -Destination "$($grubDir.FullName)\grub.cfg"

        # Download any bundles that were specified and add them to the data volume
        if ($BundlesIncluded) {

            Write-Host "Downloading cache files for the specified bundles."

            # Create the cache folder
            $cache = "$dataDir\cache"
            if (-not (Test-Path $cache))
            {
                MkDir $cache | Out-Null
            }
            # Create the cache\default folder
            $cacheDefault = "$dataDir\cache\default"
            if (-not (Test-Path $cacheDefault))
            {
                MkDir $cacheDefault | Out-Null
            }

            # Get the manifest
            $manifestUrl = "https://$($TPXEHost):$TPXEPort/cache/manifest.json"
            $manifest = Invoke-RestMethod -Uri $manifestUrl

            # Make sure all the bundles are valid
            $bundlesToInclude = @($manifest.bundles | Where-Object { $Bundles -contains $_.id })
            if ($Bundles.Count -ne $bundlesToInclude.Count) {
                $Bundles | ForEach-Object {
                    $currentID = $_
                    $found = $bundlesToInclude | Where-Object { $_.id -eq $currentID}
                    if ($null -eq $found) {
                        Write-Host "Bundle not found on Tanium PXE server: $currentID"
                    }
                }
                throw "One or more of the specified bundles does not exist on the specified Tanium PXE server."
            }

            # Process all the bundles
            $bundlesToInclude | ForEach-Object {
                if (-not $force) {
                    $_.kv | ForEach-Object {
                        if ($_.key -ieq "AdminPassword" -or $_.key -ieq "ODJService") {
                            throw "Bundle requires network connectivity to a Tanium PXE server.  Specify -Force to generate the media anyway."
                        }
                    }
                }
                Write-Host "Including files for bundle $($_.id): $($_.name)"
                $_.files | ForEach-Object {
                    $source = "https://$($TPXEHost):$TPXEPort/cache/$($_.meta.sha256)"
                    $dest = "$cache\$($_.meta.sha256)"
                    if (Test-Path $dest) {
                        Write-Host "Skipping $source because it has already been downloaded."
                    } else {
                        Write-Host "Downloading $source to $dest"
                        $webClient.DownloadFile($source, $dest)
                    }
                }
            }

            # Write the filtered manifest
            $newBundles = @()
            $manifest.bundles | Where-Object { $Bundles -contains $_.id } | ForEach-Object {
                $newBundles += $_
            }
            $manifest.bundles = $newBundles
            ConvertTo-Json $manifest -Depth 99 | Out-File -FilePath "$cache\manifest.json" -Encoding ascii

            # Download the scripts.zip
            $source = "https://$($TPXEHost):$TPXEPort/cache/default/scripts.zip"
            $dest = "$cacheDefault\scripts.zip"
            Write-Host "Downloading $source to $dest"
            $webClient.DownloadFile($source, $dest)
        }
    } elseif ( $InputMode -eq "DiskImage" ) {
        if ( $Image.ImageName -contains $label ) {
            $null = Expand-WindowsImage -ImagePath $DiskImage -Index 1 -ApplyPath $contentDir
            if ($image.ImageName -contains $DataLabel ) {
                $null = Expand-WindowsImage -ImagePath $DiskImage -Index 2 -ApplyPath $dataDir
                Get-Acl "$($env:SystemDrive)\" | Set-Acl "$($dataDir)\"
            }
        }
    }

    # Create the ISO if specified
    if ($outputMode -eq "iso") {
        Push-Location -Path "$($kitsRoot)Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg"
        & .\oscdimg.exe '-m' "-l$Label" '-o' '-u1' '-udfver102' "-bootdata:1#pEF,e,b$contentDir\iso.img" "$contentDir" "$Destination" | Out-Host
        Pop-Location
        Remove-Item $contentDir -Recurse -Force
    } elseif ($outputMode -eq "wim" ) {
        $null = New-WindowsImage -CapturePath $contentDir -ImagePath $Destination -Description "Tanium Provision Boot" -Name $label -CompressionType Fast
        Remove-Item $contentDir -Recurse -Force
        if ($BundlesIncluded) {
            $null = Add-WindowsImage -CapturePath $dataDir -ImagePath $Destination -Description "Tanium Provision Data" -name $DataLabel
            Remove-Item $dataDir -Recurse -Force
        }
    }

    Write-Host "Media creation completed."

} catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
}
# SIG # Begin signature block
# MIInKwYJKoZIhvcNAQcCoIInHDCCJxgCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUPhTaifh7z0zVofiwrXemHaAX
# +IiggiDNMIIFjTCCBHWgAwIBAgIQDpsYjvnQLefv21DiCEAYWjANBgkqhkiG9w0B
# AQwFADBlMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYD
# VQQLExB3d3cuZGlnaWNlcnQuY29tMSQwIgYDVQQDExtEaWdpQ2VydCBBc3N1cmVk
# IElEIFJvb3QgQ0EwHhcNMjIwODAxMDAwMDAwWhcNMzExMTA5MjM1OTU5WjBiMQsw
# CQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cu
# ZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC/5pBzaN675F1KPDAiMGkz
# 7MKnJS7JIT3yithZwuEppz1Yq3aaza57G4QNxDAf8xukOBbrVsaXbR2rsnnyyhHS
# 5F/WBTxSD1Ifxp4VpX6+n6lXFllVcq9ok3DCsrp1mWpzMpTREEQQLt+C8weE5nQ7
# bXHiLQwb7iDVySAdYyktzuxeTsiT+CFhmzTrBcZe7FsavOvJz82sNEBfsXpm7nfI
# SKhmV1efVFiODCu3T6cw2Vbuyntd463JT17lNecxy9qTXtyOj4DatpGYQJB5w3jH
# trHEtWoYOAMQjdjUN6QuBX2I9YI+EJFwq1WCQTLX2wRzKm6RAXwhTNS8rhsDdV14
# Ztk6MUSaM0C/CNdaSaTC5qmgZ92kJ7yhTzm1EVgX9yRcRo9k98FpiHaYdj1ZXUJ2
# h4mXaXpI8OCiEhtmmnTK3kse5w5jrubU75KSOp493ADkRSWJtppEGSt+wJS00mFt
# 6zPZxd9LBADMfRyVw4/3IbKyEbe7f/LVjHAsQWCqsWMYRJUadmJ+9oCw++hkpjPR
# iQfhvbfmQ6QYuKZ3AeEPlAwhHbJUKSWJbOUOUlFHdL4mrLZBdd56rF+NP8m800ER
# ElvlEFDrMcXKchYiCd98THU/Y+whX8QgUWtvsauGi0/C1kVfnSD8oR7FwI+isX4K
# Jpn15GkvmB0t9dmpsh3lGwIDAQABo4IBOjCCATYwDwYDVR0TAQH/BAUwAwEB/zAd
# BgNVHQ4EFgQU7NfjgtJxXWRM3y5nP+e6mK4cD08wHwYDVR0jBBgwFoAUReuir/SS
# y4IxLVGLp6chnfNtyA8wDgYDVR0PAQH/BAQDAgGGMHkGCCsGAQUFBwEBBG0wazAk
# BggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEMGCCsGAQUFBzAC
# hjdodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURS
# b290Q0EuY3J0MEUGA1UdHwQ+MDwwOqA4oDaGNGh0dHA6Ly9jcmwzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcmwwEQYDVR0gBAowCDAGBgRV
# HSAAMA0GCSqGSIb3DQEBDAUAA4IBAQBwoL9DXFXnOF+go3QbPbYW1/e/Vwe9mqyh
# hyzshV6pGrsi+IcaaVQi7aSId229GhT0E0p6Ly23OO/0/4C5+KH38nLeJLxSA8hO
# 0Cre+i1Wz/n096wwepqLsl7Uz9FDRJtDIeuWcqFItJnLnU+nBgMTdydE1Od/6Fmo
# 8L8vC6bp8jQ87PcDx4eo0kxAGTVGamlUsLihVo7spNU96LHc/RzY9HdaXFSMb++h
# UD38dglohJ9vytsgjTVgHAIDyyCwrFigDkBjxZgiwbJZ9VVrzyerbHbObyMt9H5x
# aiNrIv8SuFQtJ37YOtnwtoeW/VvRXKwYw02fc7cBqZ9Xql4o4rmUMIIGsDCCBJig
# AwIBAgIQCK1AsmDSnEyfXs2pvZOu2TANBgkqhkiG9w0BAQwFADBiMQswCQYDVQQG
# EwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNl
# cnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQwHhcNMjEw
# NDI5MDAwMDAwWhcNMzYwNDI4MjM1OTU5WjBpMQswCQYDVQQGEwJVUzEXMBUGA1UE
# ChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQg
# Q29kZSBTaWduaW5nIFJTQTQwOTYgU0hBMzg0IDIwMjEgQ0ExMIICIjANBgkqhkiG
# 9w0BAQEFAAOCAg8AMIICCgKCAgEA1bQvQtAorXi3XdU5WRuxiEL1M4zrPYGXcMW7
# xIUmMJ+kjmjYXPXrNCQH4UtP03hD9BfXHtr50tVnGlJPDqFX/IiZwZHMgQM+TXAk
# ZLON4gh9NH1MgFcSa0OamfLFOx/y78tHWhOmTLMBICXzENOLsvsI8IrgnQnAZaf6
# mIBJNYc9URnokCF4RS6hnyzhGMIazMXuk0lwQjKP+8bqHPNlaJGiTUyCEUhSaN4Q
# vRRXXegYE2XFf7JPhSxIpFaENdb5LpyqABXRN/4aBpTCfMjqGzLmysL0p6MDDnSl
# rzm2q2AS4+jWufcx4dyt5Big2MEjR0ezoQ9uo6ttmAaDG7dqZy3SvUQakhCBj7A7
# CdfHmzJawv9qYFSLScGT7eG0XOBv6yb5jNWy+TgQ5urOkfW+0/tvk2E0XLyTRSiD
# NipmKF+wc86LJiUGsoPUXPYVGUztYuBeM/Lo6OwKp7ADK5GyNnm+960IHnWmZcy7
# 40hQ83eRGv7bUKJGyGFYmPV8AhY8gyitOYbs1LcNU9D4R+Z1MI3sMJN2FKZbS110
# YU0/EpF23r9Yy3IQKUHw1cVtJnZoEUETWJrcJisB9IlNWdt4z4FKPkBHX8mBUHOF
# ECMhWWCKZFTBzCEa6DgZfGYczXg4RTCZT/9jT0y7qg0IU0F8WD1Hs/q27IwyCQLM
# bDwMVhECAwEAAaOCAVkwggFVMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0OBBYE
# FGg34Ou2O/hfEYb7/mF7CIhl9E5CMB8GA1UdIwQYMBaAFOzX44LScV1kTN8uZz/n
# upiuHA9PMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDAzB3Bggr
# BgEFBQcBAQRrMGkwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNv
# bTBBBggrBgEFBQcwAoY1aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lD
# ZXJ0VHJ1c3RlZFJvb3RHNC5jcnQwQwYDVR0fBDwwOjA4oDagNIYyaHR0cDovL2Ny
# bDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcmwwHAYDVR0g
# BBUwEzAHBgVngQwBAzAIBgZngQwBBAEwDQYJKoZIhvcNAQEMBQADggIBADojRD2N
# CHbuj7w6mdNW4AIapfhINPMstuZ0ZveUcrEAyq9sMCcTEp6QRJ9L/Z6jfCbVN7w6
# XUhtldU/SfQnuxaBRVD9nL22heB2fjdxyyL3WqqQz/WTauPrINHVUHmImoqKwba9
# oUgYftzYgBoRGRjNYZmBVvbJ43bnxOQbX0P4PpT/djk9ntSZz0rdKOtfJqGVWEjV
# Gv7XJz/9kNF2ht0csGBc8w2o7uCJob054ThO2m67Np375SFTWsPK6Wrxoj7bQ7gz
# yE84FJKZ9d3OVG3ZXQIUH0AzfAPilbLCIXVzUstG2MQ0HKKlS43Nb3Y3LIU/Gs4m
# 6Ri+kAewQ3+ViCCCcPDMyu/9KTVcH4k4Vfc3iosJocsL6TEa/y4ZXDlx4b6cpwoG
# 1iZnt5LmTl/eeqxJzy6kdJKt2zyknIYf48FWGysj/4+16oh7cGvmoLr9Oj9FpsTo
# FpFSi0HASIRLlk2rREDjjfAVKM7t8RhWByovEMQMCGQ8M4+uKIw8y4+ICw2/O/TO
# HnuO77Xry7fwdxPm5yg/rBKupS8ibEH5glwVZsxsDsrFhsP2JjMMB0ug0wcCampA
# MEhLNKhRILutG4UI4lkNbcoFUCvqShyepf2gpx8GdOfy1lKQ/a+FSCH5Vzu0nAPt
# hkX0tGFuv2jiJmCG6sivqf6UHedjGzqGVnhOMIIGtDCCBJygAwIBAgIQDcesVwX/
# IZkuQEMiDDpJhjANBgkqhkiG9w0BAQsFADBiMQswCQYDVQQGEwJVUzEVMBMGA1UE
# ChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSEwHwYD
# VQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQwHhcNMjUwNTA3MDAwMDAwWhcN
# MzgwMTE0MjM1OTU5WjBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQs
# IEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5n
# IFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0ExMIICIjANBgkqhkiG9w0BAQEFAAOCAg8A
# MIICCgKCAgEAtHgx0wqYQXK+PEbAHKx126NGaHS0URedTa2NDZS1mZaDLFTtQ2oR
# jzUXMmxCqvkbsDpz4aH+qbxeLho8I6jY3xL1IusLopuW2qftJYJaDNs1+JH7Z+Qd
# SKWM06qchUP+AbdJgMQB3h2DZ0Mal5kYp77jYMVQXSZH++0trj6Ao+xh/AS7sQRu
# QL37QXbDhAktVJMQbzIBHYJBYgzWIjk8eDrYhXDEpKk7RdoX0M980EpLtlrNyHw0
# Xm+nt5pnYJU3Gmq6bNMI1I7Gb5IBZK4ivbVCiZv7PNBYqHEpNVWC2ZQ8BbfnFRQV
# ESYOszFI2Wv82wnJRfN20VRS3hpLgIR4hjzL0hpoYGk81coWJ+KdPvMvaB0WkE/2
# qHxJ0ucS638ZxqU14lDnki7CcoKCz6eum5A19WZQHkqUJfdkDjHkccpL6uoG8pbF
# 0LJAQQZxst7VvwDDjAmSFTUms+wV/FbWBqi7fTJnjq3hj0XbQcd8hjj/q8d6ylgx
# CZSKi17yVp2NL+cnT6Toy+rN+nM8M7LnLqCrO2JP3oW//1sfuZDKiDEb1AQ8es9X
# r/u6bDTnYCTKIsDq1BtmXUqEG1NqzJKS4kOmxkYp2WyODi7vQTCBZtVFJfVZ3j7O
# gWmnhFr4yUozZtqgPrHRVHhGNKlYzyjlroPxul+bgIspzOwbtmsgY1MCAwEAAaOC
# AV0wggFZMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0OBBYEFO9vU0rp5AZ8esri
# kFb2L9RJ7MtOMB8GA1UdIwQYMBaAFOzX44LScV1kTN8uZz/nupiuHA9PMA4GA1Ud
# DwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDCDB3BggrBgEFBQcBAQRrMGkw
# JAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBBBggrBgEFBQcw
# AoY1aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJv
# b3RHNC5jcnQwQwYDVR0fBDwwOjA4oDagNIYyaHR0cDovL2NybDMuZGlnaWNlcnQu
# Y29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcmwwIAYDVR0gBBkwFzAIBgZngQwB
# BAIwCwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQAXzvsWgBz+Bz0RdnEw
# vb4LyLU0pn/N0IfFiBowf0/Dm1wGc/Do7oVMY2mhXZXjDNJQa8j00DNqhCT3t+s8
# G0iP5kvN2n7Jd2E4/iEIUBO41P5F448rSYJ59Ib61eoalhnd6ywFLerycvZTAz40
# y8S4F3/a+Z1jEMK/DMm/axFSgoR8n6c3nuZB9BfBwAQYK9FHaoq2e26MHvVY9gCD
# A/JYsq7pGdogP8HRtrYfctSLANEBfHU16r3J05qX3kId+ZOczgj5kjatVB+NdADV
# ZKON/gnZruMvNYY2o1f4MXRJDMdTSlOLh0HCn2cQLwQCqjFbqrXuvTPSegOOzr4E
# Wj7PtspIHBldNE2K9i697cvaiIo2p61Ed2p8xMJb82Yosn0z4y25xUbI7GIN/TpV
# fHIqQ6Ku/qjTY6hc3hsXMrS+U0yy+GWqAXam4ToWd2UQ1KYT70kZjE4YtL8Pbzg0
# c1ugMZyZZd/BdHLiRu7hAWE6bTEm4XYRkA6Tl4KSFLFk43esaUeqGkH/wyW4N7Oi
# gizwJWeukcyIPbAvjSabnf7+Pu0VrFgoiovRDiyx3zEdmcif/sYQsfch28bZeUz2
# rtY/9TCA6TD8dC3JE3rYkrhLULy7Dc90G6e8BlqmyIjlgp2+VqsS9/wQD7yFylIz
# 0scmbKvFoW2jNrbM1pD2T7m3XDCCBtswggTDoAMCAQICEAUwhNZw/55T4+Nt43m5
# Gd8wDQYJKoZIhvcNAQELBQAwaTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lD
# ZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IENvZGUgU2ln
# bmluZyBSU0E0MDk2IFNIQTM4NCAyMDIxIENBMTAeFw0yNDAyMjIwMDAwMDBaFw0y
# NzAzMTEyMzU5NTlaMGMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpDYWxpZm9ybmlh
# MRMwEQYDVQQHEwpFbWVyeXZpbGxlMRQwEgYDVQQKEwtUYW5pdW0gSW5jLjEUMBIG
# A1UEAxMLVGFuaXVtIEluYy4wggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIB
# gQC7lrJUu0AkZzeIMeE2vehNweY9dkuA5POlXmazZak5YGF0MPKAE8UbUX2H/SYX
# u5wD+QtlA/wH37DCdEpz9bZuzsW2NrUI5IDOMTMTeMD+lVOiD04cvwOuIS9khhwH
# IeUf29YIQXf+CHr8txE1RnEe2gw+B8jO0DvVSi2lFW1c+v92CI4/IviD3BSCWZ1B
# w38QhCZljJJX07r6AhfNFbk1loLfxzpWMaAZNO0Kdgptlb6nnnvJOFT3dJynimfa
# xJmg7vVST/xqovV5hzL7r8aOj9HSAhi7+e6x8h1UOdJOXmu4X1yNk5k6kv5AHAZW
# GM5qHqppxRl/9URXpbBeLFQF9fLaeWI2CoOYPB0LL17wJGZdWU8PoTLZj62D8xTo
# fqcZVtEntcz31NvatniuUMmAH6BpyDlLYZ4Mob03foeHO5HIothJjW5Akqq4iii2
# p8buVOwJ9rRNrAE3fMkMbwRTchy4xrU1xUSa/fVzKFDDbvHjLLgTQJmJH8nJSkc4
# U9kCAwEAAaOCAgMwggH/MB8GA1UdIwQYMBaAFGg34Ou2O/hfEYb7/mF7CIhl9E5C
# MB0GA1UdDgQWBBQ1+haN5PV3bclXvkWYzpvWS/+uSDA+BgNVHSAENzA1MDMGBmeB
# DAEEATApMCcGCCsGAQUFBwIBFhtodHRwOi8vd3d3LmRpZ2ljZXJ0LmNvbS9DUFMw
# DgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMIG1BgNVHR8Ega0w
# gaowU6BRoE+GTWh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0
# ZWRHNENvZGVTaWduaW5nUlNBNDA5NlNIQTM4NDIwMjFDQTEuY3JsMFOgUaBPhk1o
# dHRwOi8vY3JsNC5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRDb2RlU2ln
# bmluZ1JTQTQwOTZTSEEzODQyMDIxQ0ExLmNybDCBlAYIKwYBBQUHAQEEgYcwgYQw
# JAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBcBggrBgEFBQcw
# AoZQaHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZEc0
# Q29kZVNpZ25pbmdSU0E0MDk2U0hBMzg0MjAyMUNBMS5jcnQwCQYDVR0TBAIwADAN
# BgkqhkiG9w0BAQsFAAOCAgEAY5ze5QM40W2mZGsqXNRYyRfSXstetr9wL6agmfTT
# E7n9cXHQalEQlDcDisEfz9dvm+jqIF1qbWPeusnR/bEbQiPo/cVl9Snd67y5/IE8
# vuZnvys/5ZDuuMBWwuxxMCfhcnbKGG+ocCjOnu+FV0CmN81uwmKFi+RzbU22fgF7
# /rQ9PB8FbrZocXsVOvHVTfq0c85p+OTduXvoVGINlTcZu+b7SDQlNI8tkqbqQBAN
# 32EMUD1fXvkbHAF/Q+Cig7GXngqP5Z738XtZuP6bbp12JvIMgo3eh/2jJ53cJiYt
# h/u9N1LsX4UOHTn/yDGMLQsm8lCyFXpWNJpzS6Gu71qHji73wXIjljeV+ZjYomtK
# oWYOAJw5G/wbpWJqbOFadqx45BIb+tNklGK2hMZq5WshzBRSTGPfXeArJn21ZOoG
# gQUJqencM3cWMTHk+XD4mBcHSMVdLJ64tXbDkmMY+w66WNIJT0TG+SEG30A+8k0M
# YOKpmoOrZTrm33sc/w/e30wsu+U+D69G3V0yBCmaI80EsmFkw2PSc0iGkHrfK4w0
# 9mz+osKV9+IKiaCArXK5qWYiivBHvtbDdjuZodFXTNzpBYs4IGxNf0b3d1baWH0N
# mpAgFgyA9OXeLUf/sV2fuR1HC+PKWjuHosuUT3KDLGzWLAsV3fbSYwhBfeiGcwwE
# b7QwggbtMIIE1aADAgECAhAKgO8YS43xBYLRxHanlXRoMA0GCSqGSIb3DQEBCwUA
# MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UE
# AxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEy
# NTYgMjAyNSBDQTEwHhcNMjUwNjA0MDAwMDAwWhcNMzYwOTAzMjM1OTU5WjBjMQsw
# CQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRp
# Z2lDZXJ0IFNIQTI1NiBSU0E0MDk2IFRpbWVzdGFtcCBSZXNwb25kZXIgMjAyNSAx
# MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA0EasLRLGntDqrmBWsytX
# um9R/4ZwCgHfyjfMGUIwYzKomd8U1nH7C8Dr0cVMF3BsfAFI54um8+dnxk36+jx0
# Tb+k+87H9WPxNyFPJIDZHhAqlUPt281mHrBbZHqRK71Em3/hCGC5KyyneqiZ7syv
# FXJ9A72wzHpkBaMUNg7MOLxI6E9RaUueHTQKWXymOtRwJXcrcTTPPT2V1D/+cFll
# ESviH8YjoPFvZSjKs3SKO1QNUdFd2adw44wDcKgH+JRJE5Qg0NP3yiSyi5MxgU6c
# ehGHr7zou1znOM8odbkqoK+lJ25LCHBSai25CFyD23DZgPfDrJJJK77epTwMP6eK
# A0kWa3osAe8fcpK40uhktzUd/Yk0xUvhDU6lvJukx7jphx40DQt82yepyekl4i0r
# 8OEps/FNO4ahfvAk12hE5FVs9HVVWcO5J4dVmVzix4A77p3awLbr89A90/nWGjXM
# Gn7FQhmSlIUDy9Z2hSgctaepZTd0ILIUbWuhKuAeNIeWrzHKYueMJtItnj2Q+aTy
# LLKLM0MheP/9w6CtjuuVHJOVoIJ/DtpJRE7Ce7vMRHoRon4CWIvuiNN1Lk9Y+xZ6
# 6lazs2kKFSTnnkrT3pXWETTJkhd76CIDBbTRofOsNyEhzZtCGmnQigpFHti58CSm
# vEyJcAlDVcKacJ+A9/z7eacCAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQCMAAwHQYD
# VR0OBBYEFOQ7/PIx7f391/ORcWMZUEPPYYzoMB8GA1UdIwQYMBaAFO9vU0rp5AZ8
# esrikFb2L9RJ7MtOMA4GA1UdDwEB/wQEAwIHgDAWBgNVHSUBAf8EDDAKBggrBgEF
# BQcDCDCBlQYIKwYBBQUHAQEEgYgwgYUwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3Nw
# LmRpZ2ljZXJ0LmNvbTBdBggrBgEFBQcwAoZRaHR0cDovL2NhY2VydHMuZGlnaWNl
# cnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1
# NjIwMjVDQTEuY3J0MF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly9jcmwzLmRpZ2lj
# ZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEy
# NTYyMDI1Q0ExLmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEw
# DQYJKoZIhvcNAQELBQADggIBAGUqrfEcJwS5rmBB7NEIRJ5jQHIh+OT2Ik/bNYul
# CrVvhREafBYF0RkP2AGr181o2YWPoSHz9iZEN/FPsLSTwVQWo2H62yGBvg7ouCOD
# wrx6ULj6hYKqdT8wv2UV+Kbz/3ImZlJ7YXwBD9R0oU62PtgxOao872bOySCILdBg
# hQ/ZLcdC8cbUUO75ZSpbh1oipOhcUT8lD8QAGB9lctZTTOJM3pHfKBAEcxQFoHlt
# 2s9sXoxFizTeHihsQyfFg5fxUFEp7W42fNBVN4ueLaceRf9Cq9ec1v5iQMWTFQa0
# xNqItH3CPFTG7aEQJmmrJTV3Qhtfparz+BW60OiMEgV5GWoBy4RVPRwqxv7Mk0Sy
# 4QHs7v9y69NBqycz0BZwhB9WOfOu/CIJnzkQTwtSSpGGhLdjnQ4eBpjtP+XB3pQC
# tv4E5UCSDag6+iX8MmB10nfldPF9SVD7weCC3yXZi/uuhqdwkgVxuiMFzGVFwYbQ
# siGnoa9F5AaAyBjFBtXVLcKtapnMG3VH3EmAp/jsJ3FVF3+d1SVDTmjFjLbNFZUW
# MXuZyvgLfgyPehwJVxwC+UpX2MSey2ueIu9THFVkT+um1vshETaWyQo8gmBto/m3
# acaP9QsuLj3FNwFlTxq25+T4QwX9xa6ILs84ZPvmpovq90K8eWyG2N01c4IhSOxq
# t81nMYIFyDCCBcQCAQEwfTBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNl
# cnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgQ29kZSBTaWdu
# aW5nIFJTQTQwOTYgU0hBMzg0IDIwMjEgQ0ExAhAFMITWcP+eU+PjbeN5uRnfMAkG
# BSsOAwIaBQCgeDAYBgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJ
# AzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMCMG
# CSqGSIb3DQEJBDEWBBRnjv+NUpZk2eILDvD8kCs+Unrg+DANBgkqhkiG9w0BAQEF
# AASCAYAXlgFTJ+zYpr5mX2sQ6g56BmahH0jdqfnMMXlLeabQPQB9+RrI/f624Ze4
# mAlGx/v+8JkBiUkeif+oQ4FS7vRx/maVOSqgNsmmt34KaZDdcbapFua4/q7jFO5P
# s0UdiZyr8mnaPcHVP0dt45tx1jMYYXP0E5qK9FoCHImjU660BocE6XV+GeTVryKS
# oW2WISdTPp149mGC67bu5ZJACysxpcATJ07G0ljjWbh6LPnKBFwTPUSL11L2vYLs
# orH7Wqf2LGE5YcNu4qIn0mvbXUaP2R6kZFt+i67d7/NbH2rzWJdA/8d8BjAFPLF3
# FoVhfc8Bu261mWct7Ii2P6RRYw8563x33+2oPWBebp1F9M1yhtmLiaba7K2KAPTP
# h41FXhQz3NMDwulPS8WYmWz2/abi57kNUUV0qmZnlSpd2XbcqJCWIlodZO+A3Hnm
# 99gwAz2xmayjgATyLauMz/U50Mo5OQuplZcKu/IY8r7eVwZBjAJ6FAXaa+tg/HMw
# ackMD/6hggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBpMQswCQYDVQQG
# EwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0
# IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0Ex
# AhAKgO8YS43xBYLRxHanlXRoMA0GCWCGSAFlAwQCAQUAoGkwGAYJKoZIhvcNAQkD
# MQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYwNjAxMTgwOTEwWjAvBgkq
# hkiG9w0BCQQxIgQggAvTym+lQd/sFkugAxw4/PxW1z4qaVRYCOgypJvsNDkwDQYJ
# KoZIhvcNAQEBBQAEggIAKOLb7DjpugYfVAsSzkuxULveFsdcULpkwzK4IPnOlLSy
# Z28UGzIPknA1i42yjH3uTCQipV6s4mFl8O3pDDGYA7cn7DK2OF90TfmeV6Z3F6Jc
# 608Vx9PV5qmzj06WWM88d8T+9zaSoQetpSN9xtrRRhB79fiKcA3BWnzhpv/Ta2B8
# 1fdeNZvNLVNGUKuSYi8HXZ2a0t0J6v9QDq+SFZ9stwj5dfgyjKQPta1wmq6+jKtO
# 6FAFEk2/e8k+XbiliCnTUShlUml7DjRsTXfmq9lwURTQ/FJR0BTXP88IMHqoEeum
# Eyyw5JuiWDL885iO59GSR655811259qhRsInZ6mmnjrmp1huyBlugUVPOruzCyBY
# tUmc6FA0VtFp9KoOoJjtQ4PJC+An5j5JyysbK8BmS5tjnwksps8sN2pgA2vSLLVr
# 220xisNhokSuUvxrBAsqdu4cJDRUyEiZwPkIL8+X6W6URwzICp2CaynfheS9ZEQ/
# EVvK8KDA8F/IqMXoe5hhh2rWTEHJIYgd+WDjeuFB6tT3sFedFEQnOUvK44o3tPYQ
# PHA7fXNlPbLKxMhrmPoUinxuU/5+yM7diBnMdbBlUxyryLsopZJN+YxDIlT99Plh
# hezZU7UTPvrUabS1DIhG9JWW1q0K5v/xCUbXv8gMay4Isxr6F6u4SnRaKz74qg0=
# SIG # End signature block
