<#PSScriptInfo

.VERSION 1.4

.GUID 2d719794-ce02-4a09-b9f4-8511b52358d4

.AUTHOR

.COMPANYNAME Tanium

.COPYRIGHT

.TAGS Tanium Provision

.LICENSEURI

.PROJECTURI

.ICONURI

.EXTERNALMODULEDEPENDENCIES

.REQUIREDSCRIPTS

.EXTERNALSCRIPTDEPENDENCIES

.RELEASENOTES
Version 1.0: Added -Architecture switch to generate only the specified architectures.
Version 1.1: Added some error catching/reporting and cleanup
Version 1.2: Added support for EFI_EX boot files to support the new "Windows UEFI CA 2023" secure boot CA
Version 1.3: Include the Provision tools version in the signed script
Version 1.4: Include -EnableDebugPrompt parameter to enable debugging helper when we can't find/mount the hard drive in PE mode
#>

#Requires -Modules Dism
#Requires -RunAsAdministrator

<#
.SYNOPSIS
Generates the ADK zip files needed for Tanium Provision.
.DESCRIPTION
This script uses the ADK files to generate Windows PE boot images, as well as gathers other needed ADK content that is used throughout the Tanium Provision deployment process.  The ADK (with the USMT component selected) must be installed on the computer running this script, along with the Windows PE add-on.
.PARAMETER Architecture
The list of architectures to generate.  The default is "amd64".  Supported values include "amd64", "x86", and "arm64".
.PARAMETER AlternateBootExWIM
If you need EFI_EX boot files to support the new "Windows UEFI CA 2023" secure boot CA, and your WinPE version does not include them, specify a Windows WIM that does include them to extract them from the WIM.
.PARAMETER AlternateBootExWIMIndex
Used with -AlternateBootExWIM.  Specify the image index of your target windows edition within the WIM file you specified with -AlternateBootExWIM.  Defaults to 3 for Enterprise in stock volume license business edition WIMs.
.PARAMETER EnableDebugPrompt
If bootstrap.ps1 in the WinPE image cannot find/mount the local drive containing the OS/Provision scripts, spawn a debug prompt to assist in troubleshooting the failure.  Without this parameter, an error message is displayed and the system will reboot after it is acknowledged.  With this parameter, the system will not reboot until the debug prompt is closed.
.EXAMPLE
.\ADKPrep.ps1
.EXAMPLE
.\ADKPrep.ps1 -Architecture amd64,x86,arm64
#>
[CmdletBinding()]
param(
    # The list of architectures to generate.  The default is "amd64".  Supported values include "amd64", "x86", and "arm64".
    [Parameter(Mandatory=$False,Position=0)]
    [ValidateSet('amd64','x86','arm64', ignorecase=$False)]
    [String[]]
    $Architecture = @("amd64"),
    # If you need EFI_EX boot files with a newer Secure Version Number, and your WinPE version does not include them, specify a Windows WIM that does include them to extract them from the Windows WIM.
    [Parameter(Mandatory=$False,Position=1)]
    [string]
    $AlternateBootExWIM = "",
    # Used with -AlternateBootExWIM.  Defaults to index 3, specify the image index of your target windows edition within the WIM file you specified with -AlternateBootExWIM.
    [Parameter(Mandatory=$False,Position=2)]
    [uint32]
    $AlternateBootExWIMIndex = 3,
    # Used to enable a debug command prompt when bootstrap.ps1 is unable to find the target system partition/provision-pe.ps1 script.
    [Parameter(Mandatory=$false,Position=3)]
    [switch]
    $EnableDebugPrompt
)

Write-Host "ADKPrep.ps1 10.9.71.0"

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
    Write-Error "ADK is not installed."
    return 1
}

# Find Windows PE
$peRoot = $kitsRoot + "Assessment and Deployment Kit\Windows Preinstallation Environment"
if (-not (Test-Path $peRoot)) {
    Write-Error "Windows PE is not installed."
    return 2
}

# Find USMT
$usmtRoot = $kitsRoot + "Assessment and Deployment Kit\User State Migration Tool"
if (-not (Test-Path $usmtRoot)) {
    Write-Error "USMT is not installed."
    return 3
}

# Test if alternate wim is provided, if it exists and has a valid index.
if ($PSBoundParameters.Keys.Contains("AlternateBootExWIM")) {
    if ( -not (Test-Path $AlternateBootExWIM)) {
        Write-Error "AlternateBootExWIM File '$($AlternateBootExWIM)' does not exist."
        return 5
    }
    $WIMInfo = Get-WindowsImage -ImagePath $AlternateBootExWIM
    if ( $WIMInfo.ImageIndex -notcontains $AlternateBootExWIMIndex ) {
        Write-Error "AlternateBootExWIM File '$($AlternateBootExWIM)' does not contain an image with index $($AlternateBootExWIMIndex)."
        return 6
    }
}

try {
    $ErrorActionPreference = "Stop" #Make sure errors are caught

    $architecture | ForEach-Object {

        $platform = $_

        # Copy the winpe.wim
        $peFile = "$peRoot\$platform\en-us\winpe.wim";
        if (-not (Test-Path $peFile)) {
            Write-Error "Windows PE file " + $peFile + " does not exist."
            return 4
        }
        $peNew = [Environment]::GetFolderPath("MyDocuments") + "\winpe_$platform.wim"
        Copy-Item -Path $peFile -Destination $peNew -Force

        # Mount the winpe.wim
        $peMount = "$($env:TEMP)\mount_$platform"
        if (-not (Test-Path $peMount)) {
            MkDir $peMount
        }
        Mount-WindowsImage -Path $peMount -ImagePath $peNew -Index 1

        # Add the needed components to it
        $packagePath = "$peRoot\$platform\WinPE_OCs"
        ("winpe-scripting", "winpe-wmi", "winpe-securestartup", "winpe-netfx", "winpe-powershell", "winpe-storagewmi", "winpe-dismcmdlets","winpe-securebootcmdlets") | ForEach-Object {
            Write-Host "Adding package $_"
            Add-WindowsPackage -Path $peMount -PackagePath "$packagePath\$($_).cab" | Out-Null
            if ( Test-Path -Path "$packagePath\en-us\$($_)_en-us.cab" ) {
                Add-WindowsPackage -Path $peMount -PackagePath "$packagePath\en-us\$($_)_en-us.cab" | Out-Null
            }
        }

        # Inject any needed drivers
        if (Test-Path ".\$platform\Drivers") {
            Write-Host "Injecting drivers from .\$platform\Drivers"
            Add-WindowsDriver -Path $peMount -Driver ".\$platform\Drivers" -Recurse
        }

        # Inject any needed update
        if (Test-Path ".\$platform\Updates") {
            Write-Host "Injecting updates from .\$platform\Updates"
            Get-ChildItem ".\$platform\Updates" | ForEach-Object { Add-WindowsPackage -Path $peMount -PackagePath ".\$platform\Updates\$_" }
        }

        # Inject any extra files
        if (Test-Path ".\$platform\Extras") {
            Write-Host "Injecting extra files from .\$platform\Extras"
            Copy-Item -Path ".\$platform\Extras\*" -Destination $peMount -Recurse -Force
        }

        # Remove the old background
        takeown /f "$peMount\Windows\system32\winpe.jpg"
        # grant everyone group (well-known SID S-1-1-0) permission to read the file
        icacls "$peMount\Windows\system32\winpe.jpg" /grant *S-1-1-0:f
        Remove-Item "$peMount\Windows\system32\winpe.jpg"

        # Add the extra files
        Copy-Item -Path "winpeshl.ini" -Destination "$peMount\windows\system32" -Force
        # customize unattend.xml based on configuration
        $bootstrapParams = @()
        if ($EnableDebugPrompt) {
            $bootstrapParams += "-EnableDebugPrompt"
        }
        $stringBootstrapParams = ""
        if ($bootstrapParams.count -ge 1) {
            $stringBootstrapParams = " " + ($bootstrapParams -join " ")
        }
        $unattendXML = Get-Content -Path "Unattend_PE_$($platform).xml"
        $outputUnattendXML = @()
        foreach ($line in $unattendXML) {
            $outLine = $line.Replace("%PARAMETERS%", $stringBootstrapParams)
            $outputUnattendXML += $outLine
        }
        $outputUnattendXML | Set-Content -Encoding utf8 -Path "$($peMount)\unattend.xml" -Force
        Copy-Item -Path "bootstrap.ps1" -Destination "$peMount\bootstrap.ps1" -Force
        Copy-Item -Path "winpe.jpg" -Destination "$peMount\Windows\system32\winpe.jpg" -Force

        # Copy bootex files from image if they are present
        if ((Test-Path "$peMount\Windows\Boot\EFI_EX") -and (-not $PSBoundParameters.Keys.Contains("AlternateBootExWIM"))) {
            Write-Host "Capturing bootEx files from WinPE image"
            $bootExSource = "$peMount\Windows\Boot\EFI_EX"
            $hash = Get-FileHash -Path "$($bootExSource)\bootmgfw_EX.efi" -Algorithm SHA256
            if ( $hash.hash -eq "832F68EF8935A232E4F152F49A1310687B45C7903701819AD4A9776EA6443BB2" ) {
                Write-Warning @"
Detected 10.1.26100.x (May/December 2024) ADK - This ADK has a bootloader (bootmgfw.efi) signed by the 'Windows UEFI CA 2023' Secure Boot signing key at Secure Version Number 2.

If you get the following error during deployment, a workaround is available by using the 'AlternateBootExWIM' parameter for this script to pull the bootloader files from a Windows WIM image updated as of August 2024 or more recently.
For example: '.\ADKPrep.ps1 -AlternateBootExwim C:\WIMs\en-us_windows_11_business_editions_version_23h2_updated_aug_2024_x64_dvd_4b6aa6b4.wim -AlternateBootExWIMIndex 3'

Example error:
========
Security Error: Secure boot version check failed.
Your system security may be compromised!

Current Version 2.0 - Minimum allowed version: 3.0
Visit https://aka.ms/secure-boot-version-violation for more information.

The system will shutdown in 10 seconds.
========

If you do not encounter the above error during deployment, no action is required.
"@
            }
            $bootExNew = [Environment]::GetFolderPath("MyDocuments") + "\bootEx_$platform.zip"
            if (Test-Path $bootExNew) {
                Remove-Item $bootExNew -Force
            }
            Compress-Archive -Path $bootExSource -DestinationPath $bootExNew -Force
            Write-Host "BootEx zip generated: $bootExNew"
        }

        # Unmount and commit
        Dismount-WindowsImage -Path $peMount -Save

        # Report completion
        Write-Host "Windows PE generated: $peNew"

        if ( $PSBoundParameters.Keys.Contains("AlternateBootExWIM") ) {
            Write-Host "Capturing bootEx files from windows WIM image '$($AlternateBootExWIM)', ImageIndex $($AlternateBootExWIMIndex)"
            Mount-WindowsImage -Path $peMount -ImagePath $AlternateBootExWIM -Index $AlternateBootExWIMIndex -ReadOnly
            $bootExSource = "$peMount\Windows\Boot\EFI_EX"
            $bootExNew = [Environment]::GetFolderPath("MyDocuments") + "\bootEx_$platform.zip"
            if (Test-Path $bootExNew) {
                Remove-Item $bootExNew -Force
            }
            Compress-Archive -Path $bootExSource -DestinationPath $bootExNew -Force
            Write-Host "BootEx zip generated: $bootExNew"
            Dismount-WindowsImage -Path $peMount -Discard
        }

        # Create the boot zip file
        $bootSource = @("$peRoot\$platform\Media\bootmgr*","$peRoot\$platform\Media\Boot", "$peRoot\$platform\Media\efi")
        $bootNew = [Environment]::GetFolderPath("MyDocuments") + "\boot_$platform.zip"
        if (Test-Path $bootNew) {
            Remove-Item $bootNew -Force
        }
        Compress-Archive -Path $bootSource -DestinationPath $bootNew -Force
        Write-Host "Boot zip generated: $bootNew"

        # Create the USMT zip file
        $usmtNew = [Environment]::GetFolderPath("MyDocuments") + "\usmt_$platform.zip"
        if (Test-Path $usmtNew) {
            Remove-Item $usmtNew
        }
        Compress-Archive -Path "$usmtRoot\$platform\*" -DestinationPath $usmtNew -Force
        Write-Host "USMT zip generated: $usmtNew"

        # Combine the files
        $adkSource = [Environment]::GetFolderPath("MyDocuments")
        $adkFiles = @("$adkSource\boot_$platform.zip", "$adkSource\usmt_$platform.zip", $peNew)
        if ( $bootExNew ) {
            $adkFiles = $adkFiles + $bootExNew
        }
        $adkNew = [Environment]::GetFolderPath("MyDocuments") + "\adk_$platform.zip"
        Compress-Archive -Path $adkFiles -DestinationPath $adkNew -Force
        Write-Host "Combined ADK zip generated: $adkNew"
    }
} catch {
    throw $_
} finally {
    if ( -not $PSCmdlet.MyInvocation.BoundParameters["Debug"].IsPresent ) {
        if ( ( $peMount ) -and ( Test-Path $peMount ) -and ( (Get-ChildItem $peMount).count -gt 0 ) ) {
            foreach ( $Image in (Get-WindowsImage -Mounted | Where-Object {$_.path -eq $pemount}) ) {
                Dismount-WindowsImage -Path $peMount -Discard
            }
            if ( (Get-ChildItem $peMount).count -gt 0 ) {
                Get-ChildItem $peMount | Remove-Item -Recurse -Force
            }
        }
    }
}
# SIG # Begin signature block
# MIInKwYJKoZIhvcNAQcCoIInHDCCJxgCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUIygazYTZKkfeBpu6EESzsqr6
# 2BeggiDNMIIFjTCCBHWgAwIBAgIQDpsYjvnQLefv21DiCEAYWjANBgkqhkiG9w0B
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
# CSqGSIb3DQEJBDEWBBQdZ9G6MakbC1RVkiAHFGZ8NaeKpTANBgkqhkiG9w0BAQEF
# AASCAYBfwesWS+CffiAAbdLTAUHvSYO2XfEc0J99bRuJodokcKqg+SFSGJ5smM9I
# RU6z8orUXnZEUI/CFjULPmAFgKyQcDVdZbejl+pSEI4g2/+lrmSHhN/fBI7B9yCr
# bs340BgnY00szIMf3u7Coi8Ig69nkgB0oTbxPO2ReU0u2ekGePdIbOgqbX8MxsWw
# ICZtIfJcfAsi9mUd1Tzz687+Nj9CFk7X7oZU+dBLWdNBXogklGaNRjdUtl3J+c2W
# iGYsH58FeecF5G6uB43aINcKsKGWtzlnH6HlE3Zxe3bQ0R3YnKZtsKiC9cK62e+I
# 2go6i1X0j7ZAbex5PC5LfW7ow1z4Tcguf+vzD8CLhRqgLeqZIBASfnOtQYUgGsOP
# RkB/Xe7qROLGS2u0zqNRJ3hmqK98FcgetOfLdoyTDEogrEP2dDgltLjBCm1lA3O9
# iLJqHGeH9lVbP/QyX2jTHprymoit8j496qYERGnCBlm6N8nSMzg7XpH4tIxRZchp
# OMnPDHGhggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBpMQswCQYDVQQG
# EwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0
# IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0Ex
# AhAKgO8YS43xBYLRxHanlXRoMA0GCWCGSAFlAwQCAQUAoGkwGAYJKoZIhvcNAQkD
# MQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYwNjAxMTgwODU5WjAvBgkq
# hkiG9w0BCQQxIgQgERz9G+la4ceI5JeBi2NtDKKThiXKTLMoVo1HWKGYl+EwDQYJ
# KoZIhvcNAQEBBQAEggIATHHO4Vwzh7QUvgLS0Vt6WXSsZoebQQZ6Kf4Z5WLFFv5g
# alCImwGVxVW62no5HwYaVPuTYY8NM/SyrhgpxaEiK++VwmV9cWPpQ+oTqHqEEXx9
# VncM22alMLolDJZRv+zJl8hFjYVxxgyjK5h7zVNr+GO04Nd24Pk75Tj7Jwjw2s6O
# TfOFwUIXWrTKX5kDdmqAeTghehKJzAbUAFCJtHE9qIfbrKA8ctQrCST4OiGGUym8
# 1kQ41hPYmZj16+90u8OlxNbvkqv5f38TOFYdDQyPVjhmpB8jqeFh9O/7IuVujiuU
# qTAjsKXpDKCf4EGOWdTOa6GFqzzDi3RIlRDKed+aDxR1sJLeP9AHSGIiYtL7MHW9
# H9nTdFogrbHUi3RDEOsNgbuDQVufa/IJIVLdf4aQKKsJBFYh3ZMFWamw9qeIqVs6
# urgvIB1g7zn8HlOZKnwwqE9TTsmuKPaxgAGltdfjo0WRSrJtWljeZYO45hAabfju
# aQMs2i06JWoVaIOVWTCLTLUKoZElR+e5HCTewTKNRpYKvomPhE6xU5XTd0EV6hMG
# 9RaOw++jfYBZeJiLQATIb43Y2pQSfi1F0Gl+UIylyhnyqSgwAU25CY+NrqZhKrge
# L9+4LQ1V2Ha9scbCMtyMz/4sKQBPhYvsQ8bcF73jMGEZtjoRVbryJDSxtA520uY=
# SIG # End signature block
