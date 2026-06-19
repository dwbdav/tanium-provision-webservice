# -----------------------------------------------------------------------------
# UEFI PowerShell Module v2
# Author: Michael Niehaus
# Description:
#   A sample module to show how to interact with UEFI variables using
#   PowerShell.  Provided as-is with no support.  See https://oofhours.com
#   for related information.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# One-time initialization
# -----------------------------------------------------------------------------

$definition = @'
 using System;
 using System.Runtime.InteropServices;
 using System.Text;
  
 public class UEFINative
 {
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern UInt32 GetFirmwareEnvironmentVariableA(string lpName, string lpGuid, [Out] Byte[] lpBuffer, UInt32 nSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern UInt32 SetFirmwareEnvironmentVariableA(string lpName, string lpGuid, Byte[] lpBuffer, UInt32 nSize);

        [DllImport("ntdll.dll", SetLastError = true)]
        public static extern UInt32 NtEnumerateSystemEnvironmentValuesEx(UInt32 function, [Out] Byte[] lpBuffer, ref UInt32 nSize);
 }
'@

$uefiNative = Add-Type $definition -PassThru

# Global constants
$global:UEFIGlobal = "{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}"
$global:UEFIWindows = "{77FA9ABD-0359-4D32-BD60-28F4E78F784B}"
$global:UEFISurface = "{D2E0B9C9-9860-42CF-B360-F906D5E0077A}"
$global:UEFITesting = "{1801FBE3-AEF7-42A8-B1CD-FC4AFAE14716}"
$global:UEFISecurityDatabase = "{d719b2cb-3d3a-4596-a3bc-dad00e67656f}"


# -----------------------------------------------------------------------------
# Get-UEFIVariable
# -----------------------------------------------------------------------------

function Get-UEFIVariable
{
<#
.SYNOPSIS
    Gets the value of the specified UEFI firmware variable.

.DESCRIPTION
    Gets the value of the specified UEFI firmware variable.  This must be executed in an elevated process (requires admin rights).

.PARAMETER All
    Get the namespace and variable names for all available UEFI variables.

.PARAMETER Namespace
    A GUID string that specifies the specific UEFI namespace for the specified variable.  Some predefined namespace global variables
    are defined in this module.  If not specified, the UEFI global namespace ($UEFIGlobal) will be used.

.PARAMETER VariableName
    The name of the variable to be retrieved.  This parameter is mandatory.  An error will be returned if the variable does not exist.

.PARAMETER AsByteArray
    Switch to specify that the value of the specified UEFI variable should be returned as a byte array instead of as a string.

.EXAMPLE
    Get-UEFIVariable -All

.EXAMPLE
    Get-UEFIVariable -VariableName PlatformLang

.EXAMPLE
    Get-UEFIVariable -VariableName BootOrder -AsByteArray

.EXAMPLE
    Get-UEFIVariable -VariableName Blah -Namespace $UEFITesting

.OUTPUTS
    A string or byte array containing the current value of the specified UEFI variable.

.LINK
    https://oofhours.com/2019/09/02/geeking-out-with-uefi/

    
    https://docs.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getfirmwareenvironmentvariablea

#Requires -Version 2.0
#>

    [cmdletbinding()]  
    Param(
        [Parameter(ParameterSetName='All', Mandatory = $true)]
        [Switch]$All,

        [Parameter(ParameterSetName='Single', Mandatory=$false, ValueFromPipelineByPropertyName=$true)]
        [String]$Namespace = $global:UEFIGlobal,

        [Parameter(ParameterSetName='Single', Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
        [String]$VariableName,

        [Parameter(ParameterSetName='Single', Mandatory=$false)]
        [Switch]$AsByteArray = $false
    )

    BEGIN {
        $rc = Set-LHSTokenPrivilege -Privilege SeSystemEnvironmentPrivilege
    }
    PROCESS {
        if ($All) {
            # Get the full variable list
            $VARIABLE_INFORMATION_NAMES = 1
            $size = 1024 * 1024
            $result = New-Object Byte[]($size)
            $rc = $uefiNative[0]::NtEnumerateSystemEnvironmentValuesEx($VARIABLE_INFORMATION_NAMES, $result, [ref] $size)
            $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            if ($rc -eq 0)
            {
                $currentPos = 0
                while ($true)
                {
                    # Get the offset to the next entry
                    $nextOffset = [System.BitConverter]::ToUInt32($result, $currentPos)
                    if ($nextOffset -eq 0)
                    {
                        break
                    }
    
                    # Get the vendor GUID for the current entry
                    $guidBytes = $result[($currentPos + 4)..($currentPos + 4 + 15)]
                    [Guid] $vendor = [Byte[]]$guidBytes
                    
                    # Get the name of the current entry
                    $name = [System.Text.Encoding]::Unicode.GetString($result[($currentPos + 20)..($currentPos + $nextOffset - 1)])
    
                    # Return a new object to the pipeline
                    New-Object PSObject -Property @{Namespace = $vendor.ToString('B'); VariableName = $name.Replace("`0","") }
    
                    # Advance to the next entry
                    $currentPos = $currentPos + $nextOffset
                }
            }
            else
            {
                Write-Error "Unable to retrieve list of UEFI variables, last error = $lastError."
            }
        }
        else {
            # Get a single variable value
            $size = 1024
            $result = New-Object Byte[]($size)
            $rc = $uefiNative[0]::GetFirmwareEnvironmentVariableA($VariableName, $Namespace, $result, $size)
            $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            if ($lastError -eq 122)
            {
                # Data area passed wasn't big enough, try larger.  Doing 32K all the time is slow, so this speeds it up.
                $size = 32*1024
                $result = New-Object Byte[]($size)
                $rc = $uefiNative[0]::GetFirmwareEnvironmentVariableA($VariableName, $Namespace, $result, $size)
                $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()    
            }
            if ($rc -eq 0)
            {
                Write-Error "Unable to retrieve variable $VariableName from namespace $Namespace, last error = $lastError."
                return ""
            }
            else
            {
                Write-Verbose "Variable $VariableName retrieved with $rc bytes"
                [System.Array]::Resize([ref] $result, $rc)
                if ($AsByteArray)
                {
                    return $result
                }
                else
                {
                    $enc = [System.Text.Encoding]::ASCII
                    return $enc.GetString($result)
                }
            }
        }

    }
    END {
        $rc = Set-LHSTokenPrivilege -Privilege SeSystemEnvironmentPrivilege -Disable
    }
}

# -----------------------------------------------------------------------------
# Set-UEFIVariable
# -----------------------------------------------------------------------------

function Set-UEFIVariable
{
<#
.SYNOPSIS
    Sets the value of the specified UEFI firmware variable.

.DESCRIPTION
    Sets the value of the specified UEFI firmware variable.  This must be executed in an elevated process (requires admin rights).

.PARAMETER Namespace
    A GUID string that specifies the specific UEFI namespace for the specified variable.  Some predefined namespace global variables
    are defined in this module.  If not specified, the UEFI global namespace ($UEFIGlobal) will be used.

.PARAMETER VariableName
    The name of the variable to be set.  This parameter is mandatory.  An error will be retrieved if trying to define a new variable
    in the UEFI global namespace (as per the UEFI design).

.PARAMETER Value
    The string value that should be used to set the variable value.

.PARAMETER ByteArray
    The byte array that should be used to set the variable value.

.EXAMPLE
    Set-UEFIVariable -VariableName Blah -Namespace $UEFITesting -Value Blah

.EXAMPLE
    $bytes = New-Object Byte[](8)
    Set-UEFIVariable -VariableName BlahBytes -Namespace $UEFITesting -ByteArray $bytes

.LINK
    https://oofhours.com/2019/09/02/geeking-out-with-uefi/

    https://docs.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setfirmwareenvironmentvariablea

#Requires -Version 2.0
#>

    [cmdletbinding()]  
    Param(
        [Parameter()]
        [String]$Namespace = "{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}",

        [Parameter(Mandatory=$true)]
        [String]$VariableName,

        [Parameter()]
        [String]$Value = "",

        [Parameter()]
        [Byte[]]$ByteArray = $null
    )

    BEGIN {
        $rc = Set-LHSTokenPrivilege -Privilege SeSystemEnvironmentPrivilege
    }
    PROCESS {
        if ($Value -ne "")
        {
            $enc = [System.Text.Encoding]::ASCII
            $bytes = $enc.GetBytes($Value)
            Write-Verbose "Setting variable $VariableName to a string value with $($bytes.Length) characters"
            $rc = $uefiNative[0]::SetFirmwareEnvironmentVariableA($VariableName, $Namespace, $bytes, $bytes.Length)
        }
        else
        {
            Write-Verbose "Setting variable $VariableName to a byte array with $($ByteArray.Length) bytes"
            $rc = $uefiNative[0]::SetFirmwareEnvironmentVariableA($VariableName, $Namespace, $ByteArray, $ByteArray.Length)
        }
        $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($rc -eq 0)
        {
            Write-Error "Unable to set variable $VariableName from namespace $Namespace, last error = $lastError"
        }
    }
    END {
        $rc = Set-LHSTokenPrivilege -Privilege SeSystemEnvironmentPrivilege -Disable
    }

}

function Get-UEFISecureBootCerts {
<#
.SYNOPSIS
    Gets details about the UEFI Secure Boot-related variables.

.DESCRIPTION
    Gets details about the UEFI Secure Boot-related variables (db, dbx, kek, pk).

.PARAMETER Variable
    The UEFI variable to retrieve (defaults to db)

.EXAMPLE
    Get-UEFISecureBootCerts

.EXAMPLE
    Get-UEFISecureBootCerts -db

.EXAMPLE
    Get-UEFISecureBootCerts -dbx

.LINK
    https://oofhours.com/2021/01/19/uefi-secure-boot-who-controls-what-can-run/

#Requires -Version 2.0
#>        
    [cmdletbinding()]
    Param (
        [Parameter()]
        [String]$Variable = "db"
    )
    BEGIN {
        $EFI_CERT_X509_GUID = [guid]"a5c059a1-94e4-4aa7-87b5-ab155c2bf072"
        $EFI_CERT_SHA256_GUID = [guid]"c1c41626-504c-4092-aca9-41f936934328"
    }
    PROCESS {
        $db = (Get-SecureBootUEFI -Name $variable).Bytes

        $o = 0

        while ($o -lt $db.Length)
        {
            $guidBytes = $db[$o..($o + 15)]
            [Guid] $guid = [Byte[]]$guidBytes
            $signatureListSize = [BitConverter]::ToUInt32($db, $o + 16)
            $signatureHeaderSize = [BitConverter]::ToUInt32($db, $o + 20)
            $signatureSize = [BitConverter]::ToUInt32($db, $o + 24)
            $signatureCount = ($signatureListSize - 28) / $signatureSize 
            # Write-Host "GUID: $guid"
            # Write-Host "SignatureListSize: $signatureListSize"
            # Write-Host "SignatureHeaderSize: $signatureHeaderSize"
            # Write-Host "SignatureSize: $signatureSize"
            # Write-Host "SignatureCount: $signatureCount"

            $so = $o + 28
            1..$signatureCount | % {

                $ownerBytes = $db[$so..($so+15)]
                [Guid] $signatureOwner = [Byte[]]$ownerBytes
                # Write-Host "SignatureOwner: $signatureOwner"

                if ($guid -eq $EFI_CERT_X509_GUID) {
                    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
                    $certBytes = $db[($so+16)..($so+16+$signatureSize-1)]
                    $cert.Import([Byte[]]$certBytes)
                    [PSCustomObject] @{
                        SignatureOwner = $signatureOwner
                        SignatureSubject = $cert.Subject
                        Signature = $cert
                        SignatureType = $guid
                    }
                }
                elseif ($guid -eq $EFI_CERT_SHA256_GUID) {
                    $sha256hash = ([Byte[]] $db[($so+16)..($so+48-1)] | % {$_.ToString('X2')} ) -join ''
                    [PSCustomObject] @{
                        SignatureOwner = $signatureOwner
                        Signature = $sha256Hash
                        SignatureType = $guid
                    }
                }
                else {
                    Write-Warning "Unable to decode EFI signature type: $guid"
                }

                $so = $so + $signatureSize
            }

            $o = $o + $signatureListSize
        }

    }
}

function Get-UEFIBootEntry {
<#
.SYNOPSIS
    Gets the specified UEFI boot entry, or all boot entries if no ID is specified.

.DESCRIPTION
     Gets the specified UEFI boot entry, or all boot entries if no ID is specified.  Items are returned in the order they occur in the boot order.  This must be executed in an elevated process (requires admin rights).

.PARAMETER ID
    Specifies the boot entry to display (e.g. Boot0001).

.PARAMETER Hidden
    Switch to specify that hidden boot entries should be shown (only used when ID is not specified).

.PARAMETER FilePaths
    Switch to specify that the file path details should be returned with each boot entry.

.EXAMPLE
    Get-UEFIBootEntry

.EXAMPLE
    Get-UEFIBootEntry -Hidden

.EXAMPLE
    Get-UEFIBootEntry -ID Boot0001

.EXAMPLE
    Get-UEFIBootEntry -ID Boot0001 -FilePaths

.OUTPUTS
    A set of objects representing the boot entries.

.LINK
    https://oofhours.com/2019/09/02/geeking-out-with-uefi/

#Requires -Version 2.0
#>

    [cmdletbinding()]  
    Param(
        [Parameter(ParameterSetName='ID', Mandatory = $false)]
        [String]$ID = "",
        [switch]$Hidden = $false,
        [switch]$FilePaths = $false
    )

    PROCESS {
        # Get the list of boot entries
        $bootEntries = @()
        if ($ID -eq "") {
            $bootOrder = Get-UEFIVariable -VariableName BootOrder -AsByteArray
            for ($i = 0; $i -lt $bootOrder.Length; $i = $i + 2) {
                $entry = [System.BitConverter]::ToInt16($bootOrder, $i)
                $bootEntries += "Boot" + ([System.Convert]::ToString($entry, 16)).PadLeft(4, '0').ToUpper()
            }
        } else {
            $bootEntries += $ID
        }

        # Process the list
        $bootEntries | % {
            $bytes = Get-UEFIVariable -VariableName $_ -AsByteArray
            # First four bytes are the attributes, next two are the length of the file path list
            $attrib = [System.BitConverter]::ToInt32($bytes, 0)
            $filePathListLength = [System.BitConverter]::ToInt16($bytes, 4)
            # See if this is a hidden entry
            if ($attrib -band 8) { $isHidden = $true } else { $isHidden = $false }
            if ($Hidden -or (-not $isHidden)) {
                # Get the description (cheat by getting a null-terminated string from the beginning of a full string)
                $descriptionString = [System.Text.Encoding]::Unicode.GetString($bytes[6..($bytes.Length-1)])
                $description = ($descriptionString -Split [char]0x0000)[0]
                # Get the file list path start
                $currentStart = 6 + ($description.Length + 1) * 2
                $optionStart = $currentStart + $filePathListLength
                $filePathEntries = @()
                while ($currentStart -lt $optionStart) {
                    # Get the basics
                    $type = [int]$bytes[$currentStart + 0]
                    $subtype = [int]$bytes[$currentStart + 1]
                    $filePathLength = [System.BitConverter]::ToInt16($bytes, $currentStart + 2)
                    $filePath = ""
                    $filePathRaw = ""
                    if ($filePathLength -gt 4) {
                        $filePathString = [System.Text.Encoding]::Unicode.GetString($bytes[($currentStart+4)..($bytes.Length-1)])
                        $filePath = ($filePathString -Split [char]0x0000)[0]
                        $filePathRaw = $bytes[($currentStart+4)..($currentStart+$filePathLength-1)]
                    }
                    # Depending on the type and subtype, decode further
                    $extra = [ordered]@{}
                    $typeName = "Unknown ($type-$subtype)"
                    if (($type -eq 1) -and ($subtype -eq 1)) {
                        $typeName = "PCI"
                        $pciFunction = [int]$filePathRaw[0]
                        $pciDevice = [int]$filePathRaw[1]
                        $extra["DevicePath"] = "PciRoot(0)/PCI($pciDevice/$pciFunction)"
                    } elseif (($type -eq 1) -and ($subtype -eq 4)) {
                        $typeName = "Vendor"
                        $extra["VendorGUID"] = [Guid]::new([byte[]]$filePathRaw[0..15])
                        $extra["VendorData"] = $filePathRaw[16..$filePathLength]
                        $extra["VendorDataString"] = [System.Text.Encoding]::Unicode.GetString($filePathRaw[16..$filePathLength])
                    } elseif (($type -eq 2) -and ($subtype -eq 1)) {
                        $typeName = "ACPI Device Path"
                        if (($filePathRaw[0] -eq 0xD0) -and ($filePathRaw[1] -eq 0x41)) {
                            $s = ($filePathRaw[2..3] | ForEach-Object ToString X2) -Join ""
                            $extra["DevicePath"] = "PNP$s"
                        }
                    } elseif (($type -eq 3) -and ($subtype -eq 11)) {
                        $typeName = "MAC Address"
                        $extra["MacAddress"] = ($filePathRaw[0..5] | ForEach-Object ToString X2) -Join ""
                    } elseif (($type -eq 3) -and ($subtype -eq 12)) {
                        $typeName = "IPv4"
                    } elseif (($type -eq 3) -and ($subtype -eq 13)) {
                        $typeName = "IPv6"
                    } elseif (($type -eq 3) -and ($subtype -eq 24)) {
                        $typeName = "URI"
                        $extra["URI"] = [System.Text.Encoding]::ASCII.GetString($filePathRaw[0..$filePathLength])
                    } elseif (($type -eq 4) -and ($subtype -eq 1)) {
                        $typeName = "Hard Drive"
                        $extra["PartitionNumber"] = [System.BitConverter]::ToUInt32($filePathRaw, 0)
                        $extra["PartitionStart"] = [System.BitConverter]::ToUInt64($filePathRaw, 4)
                        $extra["PartitionSize"] = [System.BitConverter]::ToUInt64($filePathRaw, 12)
                        $extra["PartitionFormat"] = [int]$filePathRaw[36]
                        $extra["SignatureType"] = [int]$filePathRaw[37]
                        if ($extra["SignatureType"] -eq 0x2) {
                            $extra["PartitionSignature"] = [Guid]::new([byte[]]$filePathRaw[20..35])
                        } else {
                            $extra["PartitionSignature"] = $filePathRaw[20..35]
                        }
                    } elseif (($type -eq 4) -and ($subtype -eq 4)) {
                        $typeName = "Media Device Path"
                        $extra["PathName"] = $filePath
                    } elseif (($type -eq 127) -and ($subtype -eq 1)) {
                        $typeName = "End of Device Path Instance"
                    } elseif (($type -eq 127) -and ($subtype -eq 255)) {
                        $typeName = "End of Entire Device Path"
                    }
                    # Add the entry to the list
                    $props = [ordered]@{
                        Type = $type
                        Subtype = $subtype
                        TypeName = $typeName
                        FilePath = $filePath
                        FilePathRaw = $filePathRaw
                    }
                    $props += $extra
                    $filePathEntries += [PSCustomObject] $props
                    $currentStart += $filePathLength
                }
                if ($FilePaths) {
                    [PSCustomObject] @{
                        ID = $_
                        Description = $description
                        Hidden = $isHidden
                        FilePaths = $filePathEntries
                    }
                } else {
                    [PSCustomObject] @{
                        ID = $_
                        Description = $description
                        Hidden = $isHidden
                    }
                }
            }
        }
    }
}

function Add-UEFIBootEntry {
    <#
    .SYNOPSIS
        Adds a new UEFI boot entry to the list of boot entries.
    
    .DESCRIPTION
        Adds a new UEFI boot entry to the list of boot entries.  This new entry is added to the beginning of the boot order.  This must be executed in an elevated process (requires admin rights).
    
    .PARAMETER Name
        Specifies the name that should be assigned to the boot entry.  This will be displayed in the firmware boot menu.
    
    .PARAMETER FilePath
        Specifies the relative path of the boot file (which must be on a FAT32 system volume) that the firmware should try to load when booting using this boot entry.
    
    .PARAMETER DiskNumber
        Specifies the (optional) disk number that the boot file will be placed on.  By default, the disk will be automatically determined as long as there is only one FAT32 system volume.
    
    .PARAMETER PartitionNumber
        Specifies the (optional) partition number that the boot file will be placed on.  By default, the current system partition on the selected disk will be chosen.
    
    .PARAMETER PartitionIndex
        Specifies the (optional) partition index that the boot file will be placed on.  By default, this would be the same as the partition number unless you shrunk an existing partition and created a new partition in the empty space, without rebooting.
    
    .EXAMPLE
        Add-UEFIBootEntry -Name "Linux" -FilePath "\EFI\BOOT\BOOTX64.EFI"
    
    .OUTPUTS
        The boot entry ID (e.g. Boot0001) that was assigned to the new entry.
    
    .LINK
        https://oofhours.com/2019/09/02/geeking-out-with-uefi/
    
    #Requires -Version 2.0
    #>
    [cmdletbinding(SupportsShouldProcess=$True)]  
    Param(
        [Parameter(Mandatory=$true)][String]$Name,
        [Parameter(Mandatory=$true)][String]$FilePath,
        [int]$DiskNumber = -1,
        [int]$PartitionNumber = -1,
        [int]$PartitionIndex = -1
    )

    PROCESS {
        # Get the partition
        if ($DiskNumber -gt -1 -and $PartitionNumber -gt -1) {
            $part = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber
        } elseif ($DiskNumber -eq -1) {
            $part = Get-Partition | ? { $_.Type -eq 'System' }
        } else {
            $part = Get-Partition -DiskNumber $DiskNumber | ? { $_.Type -eq 'System' }
        }
        $disk = $part | Get-Disk
        # Get a new boot entry ID
        $id = "Invalid"
        $idNum = -1
        for ($i = 0; $i -lt 9999; $i++) {
            $id = "Boot" + ([System.Convert]::ToString($i, 16)).PadLeft(4, '0').ToUpper()
            $b = Get-UEFIVariable -VariableName $id -ErrorAction SilentlyContinue
            if ($b -eq "") {
                $idNum = $i
                break
            }
        }
        # Assemble the entry header
        $size = 1024
        $bytes = New-Object Byte[]($size)
        # Attributes: 4 bytes
        $bytes[0] = 1
        # File path list length: two bytes, added later
        # Add the description
        $null = [System.Text.Encoding]::Unicode.GetBytes($Name, 0, $Name.Length, $bytes, 6)
        $descriptionLength = ($Name.Length + 1) * 2
        $offset = 6 + $descriptionLength
        # Add the hard drive file path
        $bytes[$offset] = 4
        $bytes[$offset+1] = 1
        $bytes[$offset+2] = 42
        $bytes[$offset+3] = 0
        if ($PartitionIndex -gt -1) {
            $pn = [System.BitConverter]::GetBytes([uint32]$PartitionIndex)
        } else {
            $pn = [System.BitConverter]::GetBytes([uint32]$part.PartitionNumber)
        }
        $pn.CopyTo($bytes, $offset+4)
        $partOffset = $part.Offset / $disk.LogicalSectorSize
        $po = [System.BitConverter]::GetBytes([uint64]$partOffset)
        $po.CopyTo($bytes, $offset+8)
        $size = $part.Size / $disk.LogicalSectorSize
        $ps = [System.BitConverter]::GetBytes([uint64]$size)
        $ps.CopyTo($bytes, $offset+16)
        $psig = ([guid]$part.Guid).ToByteArray()
        $psig.CopyTo($bytes, $offset+24)
        $bytes[$offset+40] = 2  # GPT
        $bytes[$offset+41] = 2  # GUID signature
        # Add the media device path
        $bytes[$offset+42] = 4
        $bytes[$offset+43] = 4
        # Media device path length = 4 + length
        $dpLen = 4 + ($FilePath.Length + 1) * 2
        $dp = [System.BitConverter]::GetBytes([uint16]$dpLen)
        $dp.CopyTo($bytes, $offset + 44)
        # Set path
        $null = [System.Text.Encoding]::Unicode.GetBytes($FilePath, 0, $FilePath.Length, $bytes, $offset+46)
        $newOffset = $offset + 46 + ($FilePath.Length + 1) * 2
        # End the list
        $bytes[$newOffset] = 127
        $bytes[$newOffset+1] = 255
        $bytes[$newOffset+2] = 4
        $bytes[$newOffset+3] = 0
        # Set the file path list size
        $filePathListLength = ($newOffset+4) - (6 + $descriptionLength)
        $ll = [System.BitConverter]::GetBytes([uint16]$filePathListLength)
        $ll.CopyTo($bytes, 4)
        # Resize to the actual size
        [System.Array]::Resize([ref] $bytes, $newOffset+4)
        # Calculate the boot order
        $bootOrder = Get-UEFIVariable -VariableName BootOrder -AsByteArray
        $newBootOrder = New-Object Byte[]($bootOrder.Length + 2)
        $bootOrder.CopyTo($newBootOrder, 2)
        $newBootOrder[0] = $idNum
        # Save the variable and add it to the boot order
        if ($PSCmdlet.ShouldProcess($id, 'Create new boot entry')) {
            Set-UEFIVariable -VariableName $id -ByteArray $bytes
            Set-UEFIVariable -VariableName BootOrder -ByteArray $newBootOrder
        } else {
            $newBootOrder | Format-Hex
            $bytes | Format-Hex
        }
        # Return the boot entry ID
        $id
    }
}

function Remove-UEFIBootEntry {
    <#
    .SYNOPSIS
        Removes the specified UEFI boot entry.
    
    .DESCRIPTION
        Removes the specified UEFI boot entry variable and the current boot order.  This must be executed in an elevated process (requires admin rights).
    
    .PARAMETER ID
        Specifies the boot entry to display (e.g. Boot0001).
    
    .EXAMPLE
        Add-UEFIBootEntry -Name "Linux" -FilePath "\EFI\BOOT\BOOTX64.EFI"
    
    .OUTPUTS
        The boot entry ID (e.g. Boot0001) that was assigned to the new entry.
    
    .LINK
        https://oofhours.com/2019/09/02/geeking-out-with-uefi/
    
    #Requires -Version 2.0
    #>
    [cmdletbinding(SupportsShouldProcess=$True)]  
    Param(
        [Parameter(Mandatory=$true)][String]$ID
    )

    PROCESS {
        # Get the numeric ID
        $idNum = [int]$id.Substring(4)
        # Calculate the (shorter) boot order
        $bootOrder = Get-UEFIVariable -VariableName BootOrder -AsByteArray
        $newBootOrder = New-Object Byte[]($bootOrder.Length - 2)
        $offset = 0
        $newOffset = 0
        While ($offset -lt $bootOrder.Length) {
            if ($bootOrder[$offset] -ne $idNum) {
                $newBootOrder[$newOffset] = $bootOrder[$offset]
                $newOffset += 2
            }
            $offset += 2
        }
        # Save the variable and add it to the boot order
        if ($PSCmdlet.ShouldProcess($id, 'Remove boot entry')) {
            Set-UEFIVariable -VariableName $id
            Set-UEFIVariable -VariableName BootOrder -ByteArray $newBootOrder
        } else {
            $newBootOrder | Format-Hex
        }
    }
}


# The following functions enable and disable the required SeSystemEnvironmentPrivilege.  It was pulled from
# Lee Holmes' blog at http://www.leeholmes.com/blog/2010/09/24/adjusting-token-privileges-in-powershell/.  This
# is tremendously useful when dealing with Windows priviledges.

function Set-LHSTokenPrivilege
{
<#
.SYNOPSIS
    Enables or disables privileges in a specified access token.

.DESCRIPTION
    Enables or disables privileges in a specified access token.

.PARAMETER Privilege
    The privilege to adjust. This set is taken from
    http://msdn.microsoft.com/en-us/library/bb530716(VS.85).aspx

.PARAMETER ProcessId
    The process on which to adjust the privilege. Defaults to the current process.

.PARAMETER Disable
    Switch to disable the privilege, rather than enable it.

.EXAMPLE
    Set-LHSTokenPrivilege -Privilege SeRestorePrivilege

    To set the 'Restore Privilege' for the current Powershell Process.

.EXAMPLE
    Set-LHSTokenPrivilege -Privilege SeRestorePrivilege -Disable

    To disable 'Restore Privilege' for the current Powershell Process.

.EXAMPLE
    Set-LHSTokenPrivilege -Privilege SeShutdownPrivilege -ProcessId 4711
    
    To set the 'Shutdown Privilege' for the Process with Process ID 4711

.INPUTS
    None to the pipeline

.OUTPUTS
    System.Boolean, True if the privilege could be enabled

.NOTES
    to check privileges use whoami
    PS:\> whoami /priv

    PRIVILEGES INFORMATION
    ----------------------

    Privilege Name                Description                          State
    ============================= ==================================== ========
    SeShutdownPrivilege           Shut down the system                 Disabled
    SeChangeNotifyPrivilege       Bypass traverse checking             Enabled
    SeUndockPrivilege             Remove computer from docking station Disabled
    SeIncreaseWorkingSetPrivilege Increase a process working set       Disabled


    AUTHOR: Pasquale Lantella 
    LASTEDIT: 
    KEYWORDS: Token Privilege

.LINK
    http://www.leeholmes.com/blog/2010/09/24/adjusting-token-privileges-in-powershell/

    The privilege to adjust. This set is taken from
    http://msdn.microsoft.com/en-us/library/bb530716(VS.85).aspx

    pinvoke AdjustTokenPrivileges (advapi32)
    http://www.pinvoke.net/default.aspx/advapi32.AdjustTokenPrivileges

#Requires -Version 2.0
#>
   
[cmdletbinding(  
    ConfirmImpact = 'low',
    SupportsShouldProcess = $false
)]  

[OutputType('System.Boolean')]

Param(

    [Parameter(Position=0,Mandatory=$True,ValueFromPipeline=$False,HelpMessage='An Token Privilege.')]
    [ValidateSet(
        "SeAssignPrimaryTokenPrivilege", "SeAuditPrivilege", "SeBackupPrivilege",
        "SeChangeNotifyPrivilege", "SeCreateGlobalPrivilege", "SeCreatePagefilePrivilege",
        "SeCreatePermanentPrivilege", "SeCreateSymbolicLinkPrivilege", "SeCreateTokenPrivilege",
        "SeDebugPrivilege", "SeEnableDelegationPrivilege", "SeImpersonatePrivilege", "SeIncreaseBasePriorityPrivilege",
        "SeIncreaseQuotaPrivilege", "SeIncreaseWorkingSetPrivilege", "SeLoadDriverPrivilege",
        "SeLockMemoryPrivilege", "SeMachineAccountPrivilege", "SeManageVolumePrivilege",
        "SeProfileSingleProcessPrivilege", "SeRelabelPrivilege", "SeRemoteShutdownPrivilege",
        "SeRestorePrivilege", "SeSecurityPrivilege", "SeShutdownPrivilege", "SeSyncAgentPrivilege",
        "SeSystemEnvironmentPrivilege", "SeSystemProfilePrivilege", "SeSystemtimePrivilege",
        "SeTakeOwnershipPrivilege", "SeTcbPrivilege", "SeTimeZonePrivilege", "SeTrustedCredManAccessPrivilege",
        "SeUndockPrivilege", "SeUnsolicitedInputPrivilege")]
    [String]$Privilege,

    [Parameter(Position=1)]
    $ProcessId = $pid,

    [Switch]$Disable
   )

BEGIN {

    Set-StrictMode -Version Latest
    ${CmdletName} = $Pscmdlet.MyInvocation.MyCommand.Name

## Taken from P/Invoke.NET with minor adjustments.

$definition = @'
 using System;
 using System.Runtime.InteropServices;
  
 public class AdjPriv
 {
  [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
  internal static extern bool AdjustTokenPrivileges(IntPtr htok, bool disall, ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr relen);
  
  [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
  internal static extern bool OpenProcessToken(IntPtr h, int acc, ref IntPtr phtok);

  [DllImport("advapi32.dll", SetLastError = true)]
  internal static extern bool LookupPrivilegeValue(string host, string name, ref long pluid);

  [StructLayout(LayoutKind.Sequential, Pack = 1)]
  internal struct TokPriv1Luid
  {
   public int Count;
   public long Luid;
   public int Attr;
  }
  
  internal const int SE_PRIVILEGE_ENABLED = 0x00000002;
  internal const int SE_PRIVILEGE_DISABLED = 0x00000000;
  internal const int TOKEN_QUERY = 0x00000008;
  internal const int TOKEN_ADJUST_PRIVILEGES = 0x00000020;

  public static bool EnablePrivilege(long processHandle, string privilege, bool disable)
  {
   bool retVal;
   TokPriv1Luid tp;
   IntPtr hproc = new IntPtr(processHandle);
   IntPtr htok = IntPtr.Zero;
   retVal = OpenProcessToken(hproc, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ref htok);
   tp.Count = 1;
   tp.Luid = 0;
   if(disable)
   {
    tp.Attr = SE_PRIVILEGE_DISABLED;
   }
   else
   {
    tp.Attr = SE_PRIVILEGE_ENABLED;
   }
   retVal = LookupPrivilegeValue(null, privilege, ref tp.Luid);
   retVal = AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
   return retVal;
  }
 }
'@



} # end BEGIN

PROCESS {

    $processHandle = (Get-Process -id $ProcessId).Handle
    
    $type = Add-Type $definition -PassThru
    $type[0]::EnablePrivilege($processHandle, $Privilege, $Disable)

} # end PROCESS

END { Write-Verbose "Function ${CmdletName} finished." }

} # end Function Set-LHSTokenPrivilege                
 
# SIG # Begin signature block
# MIInKwYJKoZIhvcNAQcCoIInHDCCJxgCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQU3IX0SQu+I6RzAraoW7v94WhC
# qD6ggiDNMIIFjTCCBHWgAwIBAgIQDpsYjvnQLefv21DiCEAYWjANBgkqhkiG9w0B
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
# CSqGSIb3DQEJBDEWBBT8PYkBJHog1yMlPUCfv99ITMvSYDANBgkqhkiG9w0BAQEF
# AASCAYBeymCxWglX6LzLXxozVDo6kZdgBu7srl2IrYvVedhxG49POHfSiSzHOHOK
# FMVvldzH/4/MZejZFfSOQeuLPpJHIlN0JGeeMTWLw3U41NtGix32NHM2NJrUWyGB
# 0+Lq2Mo1fTAn9Ko2FzsRo7uh9jRysfdiEo26G/yDxBM/b8xqgwfwHqHadXHXvZJw
# XLh81uTWcgiXv4Am/49PjIJ8AdbwqIvK9FKfr6qxSSbiSSlTmzHkYJ0IXaU2Cxy4
# UAYC6DP7vI+3DiJLWc7zmEakLBpwfHWytRkFLie/7LM8Jr7gn0lEXTMtR0Knfjuz
# vL7Ks6ign2PRm89rv7RIS+w+1+yT7R6PP6zoMFTS7wNhjm1g//ekXPrU8x2Fgbxf
# VKa8XO7HzBkgGnwHe/pSDloQvJfPguyAzHqYBWiQ53F67eSVEnD2HEIPncelGlWw
# xq63gRIJrWv4cUl45Z5r50uzUQiDB18BKkNx1kJMZBEOEuwbTl/gY2iRrQ+prS/u
# P0YuykmhggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBpMQswCQYDVQQG
# EwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0
# IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0Ex
# AhAKgO8YS43xBYLRxHanlXRoMA0GCWCGSAFlAwQCAQUAoGkwGAYJKoZIhvcNAQkD
# MQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYwNjAxMTgwODUzWjAvBgkq
# hkiG9w0BCQQxIgQgg18qpsbPxwn7rZL1poPTM6PSNh+yI6ihgcDF3kSxqCswDQYJ
# KoZIhvcNAQEBBQAEggIAZkJAssgs4oMpgPUwFCdvWmJ5WaVFkygj5KTkeKMfMYpV
# RNv2fd6GKJQxa8Hzye4uSSu2QlMssWs7RBdgON0YAdoCYB9epG2Pu6sb7IWUj1q4
# kVS3T0IU6pViwL+SFm2j5yh1sCEhzNRXKQmYkLxj0pkZhLj6t0SC+glXH5vu2oKD
# 0GzMiaWIeUoTzvlJpbSIOPArdQOZrrZd9iP/PBnAiNQOIhtYE9y7nv+leDLbsjMH
# H/13D8CBe42q1l/PLZi/4lDXONUooueAfC3Qe4EMsw0Shssrjw9VDASSjxD5Zkbl
# 2v0uJkW7d4GxppDUQjoCIm9HHst48KUdkCDmRcMiz5ocuxA2PrVeVkVDlVok1/I5
# NkP1zTHO0YWd7DWbZOY8xgHQ1VuMSeve5Gen7L6cCqOZc54j+14KlKSxxlHt/mMI
# H9TXcEah9okeebccJUmwYt3K7kFKNCT6waibuVzlo6b5PKgAMu/AmT/z7xS3H+8d
# crdEsFwDfCUrTcGcOAqx+yuWW0OZ6yBkKzm590jQgrIrJitO+WV+7Xp/Ic25PCIi
# lp2djAlyNGTugQ+1ByHuJg93fYSkXwAJ0m3GR9y5O2OWFI0WqyQ1DkT6Dk5rUrPa
# e8AaAWGWS3RsByLp8PSbEx7AsdP/1iWmf+NE6WrkBDPqOKmk0bx6JR+m+7pkdMo=
# SIG # End signature block
