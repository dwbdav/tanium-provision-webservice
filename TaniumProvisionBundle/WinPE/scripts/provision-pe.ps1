param(
)

$buildVersion = "10.9.71.0"

# Utility functions
function Reset_Folder {
	param(
		[string] $Path
	)

    # Take ownership of the folder
    takeown.exe /f "$Path" /r /a /d Y | Out-Null
    if ($LASTEXITCODE -ne 0) {
		Write-OSDLog "Non-zero return code from TakeOwn, rc = $LASTEXITCODE"
    }

    # Reset permissions
    $escapedPath = $Path.Replace("\","\\")
    $oFile = Get-CimInstance -ClassName CIM_Directory -Filter "Name='$escapedPath'"
    $oSD = New-CimInstance -ClassName Win32_SecurityDescriptor -ClientOnly
    try {
        $iRc = Invoke-CimMethod -InputObject $oFile -MethodName ChangeSecurityPermissionsEx -Arguments @{
            SecurityDescriptor = $oSD; Option = 4; Recursive = $true
        }
    }
	catch
	{
		Write-OSDLog "Unable to change security permissions: $_"
        $iRc = 9999
    }
    return $iRc
}

function Reset_File {
	param(
		[string] $Path
	)

    # Take ownership of the file
    takeown.exe /f "$Path" /a | Out-Null
    if ($LASTEXITCODE -ne 0) {
		Write-OSDLog "Non-zero return code from TakeOwn, rc = $LASTEXITCODE"
    }

    # Reset permissions
    $escapedPath = $Path.Replace("\","\\")
    $oFile = Get-CimInstance -ClassName CIM_DataFile -Filter "Name='$escapedPath'"
    $oSD = New-CimInstance -ClassName Win32_SecurityDescriptor -ClientOnly
    try {
        $iRc = Invoke-CimMethod -InputObject $oFile -MethodName ChangeSecurityPermissions -Arguments @{
            SecurityDescriptor = $oSD; Option = 4
        }
    } catch {
		Write-OSDLog "Unable to change security permissions: $_"
        $iRc = 9998
    }
    return $iRc
}

function Clean_Drive {
	param(
		[string] $Path
	)

    # Remove folders
	Get-ChildItem -Path $Path -Directory -Force | ForEach-Object {
		$folder = $_.Name
		$folderPath = $_.FullName
        switch ($folder) {
            "_t" {
				Write-OSDLog "Skipping folder $folder"
			}
            "recycler" {
				Write-OSDLog "Skipping folder $folder"
			}
            "system volume information" {
				Write-OSDLog "Skipping folder $folder"
			}
            default {
                # Try to remove the folder
				Write-OSDLog "Removing folder $folder"
                cmd.exe /c rd /s /q "$folderPath" | Out-Null
                # If it still exists, reset the permissions and try again
                if (Test-Path $folderPath) {
                    # Reset the permissions
                    $iRc = Reset_Folder($folderPath)
                    if ($iRc -ne 0) {
                        Write-OSDLog "Non-zero return code resetting folder $folderPath, RC = $iRc"
                    }
                    # Try the delete again
					cmd.exe /c rd /s /q "$folderPath" | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        Write-OSDLog "Unable to delete folder $folderPath, RC = $iRc"
                    }
                }
        	}
    	}
	}

	# Remove files at the root of the path
	Get-ChildItem -Path $Path -File -Force | ForEach-Object {
		$file = $_.FullName
        Reset_File $file | Out-Null
		Write-OSDLog "Removing file: $file"
		Remove-Item $file -Force
	}
}

# Similar to logic in Provision-pe.ps1, used here only for Autopilot for existing devices
function Cleanup {

    try {

        # Stop logging
        Write-OSDLog "Stopping transcript."
        Stop-Transcript

        # Copy logs to the Windows folder (no Tanium Client yet)
        $ProgDataFolder = "C:\ProgramData\Tanium\Provision"
        $logDest = "$($ProgDataFolder )\Logs"

        # Create the Progdata\Tanium\Provision folder if needed, and ensure its ACL is correct.
        Initialize-ProgDataFolder -Path $ProgDataFolder -LogPath $logDest
        # Copy the desired files (logs and config) into the folder
        Copy-Item -Path "C:\_t\logs\*.log" -Destination $logDest -Force

        # Stop progress display
        Stop-OSDProgressDisplay

        # Remove the temporary folder
        Remove-Item -Path "C:\_t" -Recurse -Force
    }
    catch {
        Write-OSDLog "Error during cleanup: $_"
    }
}

# Main script

try
{
    $global:OSDLogFile = "$PSScriptRoot\logs\provision-pe.log"
	Import-Module "$PSScriptRoot\TaniumOSD" -Force

	# Initialization
	$rootFolder = Get-OSDRootFolder
    Set-OSDLog -Path "$rootFolder\logs\provision-pe.log"
	Start-Transcript -Path "$rootFolder\logs\provision-pe-transcript.log" -Append

	Write-OSDLog "Starting provision-pe.ps1 from tools version $($buildVersion)."

    # Make sure the folder is appropriately secured
    Write-OSDLog "Securing $rootFolder"
    icacls.exe "$global:OSDRootFolder" /grant "*S-1-5-32-544:(OI)(CI)F" /t | Out-Null

	# Start the progress UI to get it in the front
	Write-OSDLog "Starting OSD progress display"
    try {
        $EnableTerminal = [bool]::Parse((Get-OSDVariable -Name "EnableTerminal"))
    } catch {
        $EnableTerminal = $true
    }
    if ( $EnableTerminal ) {
        Start-OSDProgressDisplay
    } else {
	    Start-OSDProgressDisplay -DisableTerminal
    }

    # Set the device to "high performance" power scheme
	Write-OSDLog "Setting high performance power scheme."
    powercfg /s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
	Write-OSDLog "Return code from powercfg: $LASTEXITCODE"

    # If there is a customer script, call it
	if (Test-Path "$rootFolder\Customer-PE-Pre.ps1") {
        Set-OSDProgressDisplay -Message "Processing customer-specific script."
		Write-OSDLog "Calling custom script Customer-PE-Pre.ps1"
		try {
            Push-Location $rootFolder
			. "$rootFolder\Customer-PE-Pre.ps1" 2>&1 | Write-OSDLog
		}
		catch {
			Write-Warning "$(Get-OSDTimeStamp) Error from calling script: $_"
		}
        Pop-Location
	}

    # Find the right drive letter for the OS
	$sPath = Get-OSDDrive
	$sBoot = Get-OSDBootDrive -Force
	$uefi = Get-OSDVariable -Name "UEFI"
	Write-OSDLog "Located boot volume: $sBoot"
	Write-OSDLog "Located OS volume: $sPath"
	Write-OSDLog "UEFI: $uefi"

    # Fix up partitions
	Write-OSDLog "Updating partitions using DISKPART."
	Set-OSDProgressDisplay -Message "Updating partitions."
	Add-Content -Path "X:\updatepart.txt" -Value "select disk 0"
	if ($uefi) {
        Add-Content -Path "X:\updatepart.txt" -Value "select part 4"
        Add-Content -Path "X:\updatepart.txt" -Value "set id = de94bba4-06d1-4d40-a16a-bfd50179d6ac"
        Add-Content -Path "X:\updatepart.txt" -Value "gpt attributes = 0x8000000000000000"
	}
	else {
        Add-Content -Path "X:\updatepart.txt" -Value "select part 3"
        Add-Content -Path "X:\updatepart.txt" -Value "set id = 27"
	}
    Add-Content -Path "X:\updatepart.txt" -Value "exit"
	diskpart.exe /s x:\updatepart.txt | Write-OSDLog -NoTimeStamp
    Write-OSDLog "Return code from DISKPART = $LASTEXITCODE"

    # Check if BitLocker encryption is already in place (e.g. refresh)
    Write-OSDLog "Checking for BitLocker encryption."
    $script:bEncrypted = $false
	Get-CimInstance -ClassName Win32_EncryptableVolume -Namespace "root\cimv2\security\MicrosoftVolumeEncryption" -Filter "DriveLetter = '$($sPath.substring(0, 2))'" | ForEach-Object {
		if ($_.ConversionStatus -gt 0) {
			$script:bEncrypted = $true
		}
	}

    # If this is a refresh, capture the user state using USMT
    $refresh = Get-OSDVariable -Name "refresh"
    $migrate = Get-OSDVariable -Name "Migrate"
    if ($refresh -and ($migrate -ine "no")) {
        # Create needed folders
        if (-not (Test-Path "$rootFolder\USMT")) {
            MkDir "$rootFolder\USMT" | Out-Null
        }
        if (-not (Test-Path "$rootFolder\StateStore")) {
            MkDir "$rootFolder\StateStore" | Out-Null
        }
        if (-not (Test-Path "$rootFolder\Temp")) {
            MkDir "$rootFolder\Temp" | Out-Null
        }

        # Expand the USMT folder
        $adkArch = Get-OSDVariable -Name "architecture"
        if ($adkArch -eq "x64") {
            $adkArch = "amd64";
        }
        Expand-Archive -Path "$rootFolder\USMT_$($adkArch).zip" -DestinationPath "$rootFolder\USMT" -Force

        # Run the state capture
        $elapsed = Measure-Command {
            Set-OSDProgressDisplay -Message "Capturing user state."
            $env:USMT_WORKING_DIR = "$rootFolder\temp"
            $env:TEMP = "$rootFolder\temp"
            $env:MIG_OFFLINE_PLATFORM_ARCH = "64"
            if ( (Get-OSDVariable -Name "architecture") -eq "x86" ) {
                $env:MIG_OFFLINE_PLATFORM_ARCH = "32"
            }
            Copy-Item -Path "$rootFolder\MigTanium.xml" -Destination "$rootFolder\USMT\MigTanium.xml" -Force
            & "$rootFolder\USMT\scanstate.exe" "$rootFolder\StateStore" /l:"$rootFolder\logs\Scanstate.log" /offlineWinDir:"$($sPath)\Windows" /hardlink /nocompress /v:5 /c /o /i:"$rootFolder\USMT\MigApp.xml" /i:"$rootFolder\USMT\MigDocs.xml" /i:"$rootFolder\USMT\MigTanium.xml" /progress:"$rootFolder\logs\Scanstate_progress.log" | Write-OSDLog -NoTimeStamp
            if ($LASTEXITCODE -ne 0) {
                throw "Unexpected return code from USMT ScanState.exe: $($LASTEXITCODE)"
            }
            else {
                Write-OSDLog "USMT ScanState completed successfully."
            }
        }
        Set-OSDProgress -Details @{
            USMTCaptureExitCode = $LASTEXITCODE
            USMTCaptureElapsedTime = [int]$elapsed.TotalSeconds
        }

    }

    # Clean the drive
    Set-OSDProgressDisplay -Message "Cleaning the drive."
    Write-OSDLog "Cleaning drive $sPath."
    Clean_Drive -Path $sPath

    # Enable BitLocker offline if not already enabled (e.g. refresh)
    $bitLocker = Get-OSDVariable -Name "BitLocker"
    if ($script:bEncrypted) {
        Write-OSDLog "BitLocker encryption is already in place, skipping pre-provisioning."
    }
	elseif ($bitLocker -ne "") {
        Write-OSDLog "Performing BitLocker pre-provisioning."
        # If UEFI, clean up the boot volume before running manage-bde to avoid the error below.
        #    ERROR: An error occurred (code 0x800703ee):
        #    The volume for a file has been externally altered so that the opened file is no longer valid.
        if ($uefi -and (Test-Path $sBoot)) { # Don't try to do this if we can't actually access $sBoot because it's using the \\?\Volume{<guid>}\ format and didn't get mounted to C:\_t\esp
            Write-OSDLog "Cleaning up UEFI boot volume (ESP) $sBoot pre-bitlocker."
            # Unmount BCD (just in case)
            Write-OSDLog "Making sure BCD is unloaded."
            reg.exe unload HKLM\BCD00000000 | Out-Null
            reg.exe unload HKLM\BCD00000001 | Out-Null
            $ChildItems = Get-ChildItem -Path $sBoot
            $tempdir = New-Item -ItemType Directory -Path (Join-Path -Path $sBoot -ChildPath "temp")
            $ChildItems | ForEach-Object { $_ | Move-Item -Destination $tempdir }
        }

        Set-OSDProgressDisplay -Message "Enabling BitLocker."
        if ($bitLocker -eq "XTS-AES-256") {
            Write-OSDLog "Setting BitLocker encryption method to XTS-AES-256."
            if (-not (Test-Path "HKLM:\Software\Policies\Microsoft\FVE")) {
                New-Item "HKLM:\Software\Policies\Microsoft\FVE" | Out-Null
            }
            Set-ItemProperty -Path "HKLM:\Software\Policies\Microsoft\FVE" -Name EncryptionMethodWithXtsFdv -Value 7 -Type DWord
        }
        manage-bde.exe -on "$($sPath.substring(0, 2))" -used | Write-OSDLog -NoTimeStamp
        Write-OSDLog "Return code = $LASTEXITCODE"
        if ($uefi -and (Test-Path $sBoot)) {
            Write-OSDLog "Restoring original UEFI boot volume (ESP) $sBoot."
            Get-ChildItem -Path $tempdir | ForEach-Object { $_ | Move-Item -Destination $sBoot }
            Remove-Item -Path $tempdir
        }
    }
	else {
        Write-OSDLog "Skipping BitLocker pre-provisioning."
    }

    # Apply the OS
    $script:ApplyExitCode = 0
    $elapsed = Measure-Command {
        Set-OSDProgressDisplay -Message "Applying the OS image."
        $imageIndex = Get-OSDManifestSetting -Name "image_index"
        $imageFile = Get-OSDManifestFile -FileType OSIMAGE
        $useDirect = Get-OSDVariable -Name "UseDirect"
        if ($useDirect) {
            $directEdition = Get-OSDVariable -Name "DirectEdition"
            $image = Get-WindowsImage -ImagePath "$rootFolder\$imageFile" | Where-Object { $_.ImageName -like "*$directEdition" }
            if ($image) {
                $imageIndex = $image.ImageIndex
                Write-OSDLog "Adjusted image index to $imageIndex for direct download file with edition $directEdition"
            }
        }
        Write-OSDLog "WIM information:"
        dism.exe /Get-WimInfo /WimFile:"$rootFolder\$imageFile" | Write-OSDLog -NoTimeStamp
        Write-OSDLog "Applying the OS image with index $imageIndex."
        Write-OSDLog "Running command: dism.exe /Apply-Image /ImageFile:`"$rootFolder\$imageFile`" /Index:$imageIndex /ApplyDir:$sPath"
        $job = Start-Job -ScriptBlock {
            dism.exe /Apply-Image /ImageFile:"$($using:rootFolder)\$($using:imageFile)" /Index:$($using:imageIndex) /ApplyDir:"$($using:sPath)" >> X:\DISM_apply.log
            # Return the exit code
            $LASTEXITCODE
        }
        do {
            if (Test-Path "X:\DISM_apply.log") {
                try {
                    $content = Get-Content "X:\DISM_apply.log"
                    $count = ($content | Select-String -Pattern '.0%' -AllMatches)
                    $percent = $count.Count
                    Set-OSDProgressDisplay -Message "Applying the OS image." -Percent $percent
                } catch { }
            }
            Start-Sleep -Milliseconds 1000
        } while ($job.State -eq "Running")
        $result = Receive-Job -Job $job
        $script:ApplyExitCode = $result[0]
    }
    Set-OSDProgress -Details @{
        ApplyExitCode = $script:ApplyExitCode
        ApplyElapsedTime = [int]$elapsed.TotalSeconds
    }
    If (Test-Path "X:\DISM_Apply.log") {
        Move-Item -Path "X:\DISM_Apply.log" -Destination "$rootFolder\logs\DISM_Apply.log" -Force
    }
    if ($script:ApplyExitCode -ne 0) {
        throw "Unexpected return code from DISM /Apply-Image: $script:ApplyExitCode"
    }

    # Inspect sysprep state of applied image
    if ( Test-Path "$($sPath)Windows\Setup\State\State.ini") {
        $sysprepStateFile = Import-Ini -File "$($sPath)Windows\Setup\State\State.ini"
        if ($sysprepStateFile["State"]) {
            if ($sysprepStateFile["State"]["ImageState"]) {
                $sysprepState = $sysprepStateFile["State"]["ImageState"]
                Write-OSDLog "System setup (sysprep) state: $($sysprepState)"
                switch -regex ($sysprepState) {
                    "^IMAGE_STATE_SPECIALIZE_" {
                        Write-OSDLog "Info: System setup is in SPECIALIZE state, this image may not work on different hardware than it was captured from."
                    }
                    {$_ -notmatch "_RESEAL_TO_OOBE$"} {
                        Write-OSDLog "Warning: System setup state is not resealed to OOBE, this system will likely not run provision-os.ps1, and will not complete deployment correctly!"
                    }
                    "IMAGE_STATE_COMPLETE" {
                        Write-OSDLog "Warning: System setup is in COMPLETE state, this image was not captured correctly."
                    }
                    "IMAGE_STATE_UNDEPLOYABLE" {
                        $message = "Error: System setup is in UNDEPLOYABLE state, this image was not sysprepped and/or captured correctly!"
                        Write-OSDLog $message
                        throw $message
                    }
                }
            } else {
                Write-OSDLog "ImageState not found in State.ini"
            }
        } else {
            Write-OSDLog "State section not found in State.ini"
        }
    } else {
        Write-OSDLog "State.ini not found"
    }


    # Inspect and log windows edition of applied image
    try {
        $WinEdition = (Get-WindowsEdition -Path $sPath).Edition
    } catch {
        Write-OSDLog "Error: Unable to get windows edition of applied image: $($_.Exception.Message)"
    }

    # Apply patches
    $elapsed = Measure-Command {
        Write-OSDLog "Applying patches (if any where specified)."
        Set-OSDProgressDisplay -Message "Applying patches."
        if (-not (Test-Path "$rootFolder\scratch")) {
            MkDir "$rootFolder\scratch" | Out-Null
        }
        Get-OSDManifestFile -FileType PATCH | ForEach-Object {
            dism.exe /image:$sPath /Add-Package /PackagePath:"$rootFolder\$_" /LogPath:$rootFolder\logs\DISM_Patch.log /ScratchDir:$rootFolder\Scratch | Write-OSDLog -NoTimeStamp
            Write-OSDLog "Return code from dism.exe = $LASTEXITCODE"
        }
    }
    Set-OSDProgress -Details @{
        PatchesElapsedTime = [int]$elapsed.TotalSeconds
    }

	# Unmount BCD (just in case)
	Write-OSDLog "Making sure BCD is unloaded."
	reg.exe unload HKLM\BCD00000000 | Out-Null
	reg.exe unload HKLM\BCD00000001 | Out-Null

    # Clean up old BCD because it could get in the way
    Write-OSDLog "Cleaning up old BCD."
	if (Test-Path "$sBoot\efi\microsoft\boot\bcd") {
		Remove-Item "$sBoot\efi\microsoft\boot\bcd" -Force
	}
	if (Test-Path "$sBoot\boot\bcd") {
		Remove-Item "$sBoot\boot\bcd" -Force
	}

    # If UEFI, clean up the boot volume before running bcdboot
    if ($uefi) {
        Write-OSDLog "Cleaning up UEFI boot volume (ESP) $sBoot."
        Clean_Drive -Path $sBoot
    }

    # Make it bootable
    Write-OSDLog "Making Windows bootable with bcdboot.exe."
    Set-OSDProgressDisplay -Message "Making OS bootable."
    if ($uefi) {
        Write-OSDLog "Checking secure boot state/config."
        if ( (Get-OSDVariable -Name "bIsSecureBootEnabled") -eq $True ) {
            Write-OSDLog "Secure Boot Enabled = true."
            if ( (Get-OSDVariable -Name "bUEFITrusts2011Cert") -eq $False ) {
                Write-OSDLog "Secure Boot Firmware does not trust the 2011 UEFI cert."
                if ( -not (Test-Path "$($sPath)Windows\Boot\EFI_EX") ) {
                    Write-OSDLog "The installed windows image does not contain bootloaders compatible with/signed by the 2023 UEFI cert.  bcdboot.exe will likely fail."
                    Write-OSDLog "The windows image will need to be updated to include cumulative updates up to August 2024 or later, or the system must be reimaged with secure boot disabled."
                }
            }
        }
        $result = bcdboot.exe "$($sPath)windows"
        if ( $? -eq $false ) {
            $errorMessage = "Unable to stage bcdboot files: $($result)"
            Write-OSDLog "$($errorMessage)"
            Write-OSDLog "This may be due to the firmware requiring newer boot files than the OS image provides."
            Write-OSDLog "Secureboot status:"
            Write-OSDLog "SecureBootEnabled:`t$(Get-OSDVariable -Name "bIsSecureBootEnabled")"
            Write-OSDLog "2011 Cert Trusted:`t$(Get-OSDVariable -Name "bUEFITrusts2011Cert")"
            Write-OSDLog "2023 Cert Trusted:`t$(Get-OSDVariable -Name "bUEFITrusts2023Cert")"

            throw $errorMessage
        }
    } else {
        bcdboot.exe "$($sPath)windows" /s $sBoot | Write-OSDLog -NoTimeStamp
    }
    Write-OSDLog "Return code from bcdboot.exe = $($LASTEXITCODE)"
    if ($LASTEXITCODE -ne 0) {
        throw "Unexpected return code from BCDBOOT: $($LASTEXITCODE)"
    }

    Remove-OSDBCDEntries

    # Inject drivers
    $elapsed = Measure-Command {
        Write-OSDLog "Injecting drivers."
        Set-OSDProgressDisplay -Message "Injecting drivers."
        dism.exe /image:$sPath /Add-Driver /Driver:$rootFolder\drivers /LogPath:$rootFolder\logs\DISM_Drivers.log /Recurse | Write-OSDLog -NoTimeStamp
        Write-OSDLog "Return code from dism.exe = $LASTEXITCODE"
    }
    Set-OSDProgress -Details @{
        DriversExitCode = $LASTEXITCODE
        DriversElapsedTime = [int]$elapsed.TotalSeconds
    }

    # Inject provisioning packages
    Get-ChildItem "$rootFolder\*.ppkg" | ForEach-Object {
        Write-OSDLog "Injecting provisioning package $_"
        dism.exe /image:$sPath /Add-ProvisioningPackage /PackagePath:"$_" /LogPath:$rootFolder\logs\DISM_PPKG.log | Write-OSDLog -NoTimeStamp
        Write-OSDLog "Return code from dism.exe = $LASTEXITCODE"
    }

    # Clean up SetupType if requires
    reg.exe load HKLM\NewSystem "$($sPath)windows\system32\config\SYSTEM" | Write-OSDLog -NoTimeStamp
	$setupType = Get-ItemPropertyValue -Path "HKLM:\NewSystem\Setup" -Name "SetupType"
	if ($setupType -eq 2) {
		Write-OSDLog "Resetting SetupType = 0x1."
		Set-ItemProperty -Path "HKLM:\NewSystem\Setup" -Name "SetupType" -Value 1
	}
    reg.exe unload HKLM\NewSystem | Write-OSDLog -NoTimeStamp

    # Clean up OOBE if required
    reg.exe load HKLM\NewSoftware "$($sPath)windows\system32\config\SOFTWARE" | Write-OSDLog -NoTimeStamp
	$items = Get-ItemProperty -Path "HKLM:\NewSoftware\Microsoft\Windows\CurrentVersion\OOBE"
    if ($null -ne $items) {
        $items | Get-Member -MemberType NoteProperty | Where-Object { -not ($_.Name -like 'PS*') } | ForEach-Object {
            Write-OSDLog "Removing OOBE value $($_.Name)."
            Remove-ItemProperty -Path "HKLM:\NewSoftware\Microsoft\Windows\CurrentVersion\OOBE" -Name $_.Name
        }
    }
    # Capture some info about the deployed image
    $items = Get-ItemProperty -Path "HKLM:\NewSoftware\Microsoft\Windows NT\CurrentVersion"
    if ($null -ne $items) {
        if ($items.ProductName) {
            $WinProductName = $items.ProductName
        }
        if ($items.DisplayVersion) {
            $WinDisplayVersion = $items.DisplayVersion
        }
        if ($items.ReleaseId) {
            $WinReleaseId = $items.ReleaseId
        }
        if ($items.LCUVer) {
            $WinLCUVer = $items.LCUVer
        }
        if ($items.CurrentBuild) {
            $WinCurrentBuild = $items.CurrentBuild
        }
        if ($items.InstallationType) {
            $WinInstallationType = $items.InstallationType
        }
    }
    reg.exe unload HKLM\NewSoftware | Write-OSDLog -NoTimeStamp

    # Log deployed image info:
    Write-OSDLog "Deployed image info:"
    Write-OSDLog "`tProductName: $($WinProductName)"
    Write-OSDLog "`tDisplayVersion: $($WinDisplayVersion)"
    Write-OSDLog "`tReleaseId: $($WinReleaseId)"
    Write-OSDLog "`tEdition: $($WinEdition)"
    Write-OSDLog "`tLCUVer: $($WinLCUVer)"
    Write-OSDLog "`tCurrentBuild: $($WinCurrentBuild)"
    Write-OSDLog "`tInstallationType: $($WinInstallationType)"

    # If we find an AutopilotConfigurationFile.json, we're doing Autopilot for existing devices.
    # Put the file in the right place, and don't use SetupComplete/unattend.xml.
    if (Test-Path "$rootFolder\AutopilotConfigurationFile.json") {
        # Generate the computer name if necessary
        $computerName = Get-OSDVariable -Name 'ComputerName'
        if ($computerName -eq "") {
            $computerName = $env:COMPUTERNAME
        } else {
            $computerName = Resolve-OSDVariables -Value $computerName
        }

        # Sanitize name by substituting for invalid characters, and limit length to 15.
        $computerName = $computerName -Replace '[^-a-zA-Z0-9]','-'
        $computerName = $computerName.substring(0, [System.Math]::Min(15, $computerName.Length))

        # Add the computer name to the JSON file
        Write-OSDLog "Writing AutopilotConfigurationFile.json with computer name $computerName"
        $config = Get-Content "$rootFolder\AutopilotConfigurationFile.json" | ConvertFrom-Json
        $config | Add-Member -MemberType NoteProperty -Name "CloudAssignedDeviceName" -Value $computerName -Force

        # Write the updated JSON file
        $null = MkDir "$($sPath)windows\Provisioning\Autopilot" -Force
        $destConfig = "$($sPath)Windows\Provisioning\Autopilot\AutopilotConfigurationFile.json"
        $config | ConvertTo-JSON | Set-Content -Path $destConfig -Force

        reg.exe load HKLM\OfflineHive "$($sPath)windows\system32\config\SOFTWARE" | Write-OSDLog
        $regPath = "HKLM:\OfflineHive\Wow6432Node\Tanium"

        New-Item -Path "$regPath\Provision" -ItemType Directory -Force

        $BundleID = Get-OSDManifestSetting "id"
        $BundleName = (Get-OSDManifestSetting "name")
        $Method = ""
        if ($refresh) {
            $Method = "REFRESH"
		} else {
            $Method = "BAREMETAL"
		}

        Write-OSDLog "Set new registry value for $regPath\Provision: BundleID - $BundleID."
        New-ItemProperty -Path "$regPath\Provision" -Name "BundleID" -Value $BundleID -PropertyType String -Force

        Write-OSDLog "Set new registry value for $regPath\Provision: BundleName - $BundleName."
        New-ItemProperty -Path "$regPath\Provision" -Name "BundleName" -Value $BundleName -PropertyType String -Force

        Write-OSDLog "Set new registry value for $regPath\Provision: Method - $Method."
        New-ItemProperty -Path "$regPath\Provision" -Name "Method" -Value $Method -PropertyType String -Force

        $progress = Get-OSDProgress | ConvertFrom-JSON
		if ($progress | Get-Member "DeploymentId") {
            Write-OSDLog "Set new registry value for $regPath\Provision: DeploymentId - $($progress.DeploymentId)."
			New-ItemProperty -Path "$regPath\Provision" -Name "DeploymentID" -Value $progress.DeploymentId -PropertyType String -Force
		}

        reg.exe unload HKLM\OfflineHive | Write-OSDLog

    } else {
        # Put the unattend.xml in the right location
        $unattendFile = Get-OSDManifestFile -FileType UNATTEND
        $sUnattendSource = "$rootFolder\$unattendFile"
        $sUnattendDir = "$($sPath)windows\panther\unattend"
        Write-OSDLog "Reading unattend.xml from $sUnattendSource and writing edited file to $sUnattendDir\unattend.xml"
        if (-not (Test-Path "$($sPath)windows\panther")) {
            MkDir "$($sPath)windows\panther" | Out-Null
        }
        if (-not (Test-Path $sUnattendDir)) {
            MkDir $sUnattendDir | Out-Null
        }
        $unattendContents = Get-Content -Path $sUnattendSource -Raw

        # Resolve twice to make sure variables that embed other variables get resolved
        $unattendContents = Resolve-OSDVariables -Value $unattendContents
        $unattendContents = Resolve-OSDVariables -Value $unattendContents
        Set-Content -Path "$sUnattendDir\unattend.xml" -Value $unattendContents -Force
        Write-OSDLog "Unattend.xml written."

        # Put the SetupComplete file in place
        Write-OSDLog "Copying SetupComplete.cmd."
        if (-not (Test-Path "$($sPath)windows\Setup\Scripts")) {
            MkDir "$($sPath)windows\Setup\Scripts" | Out-Null
        }
        Copy-Item -Path "$rootFolder\SetupComplete.cmd" -Destination "$($sPath)windows\Setup\Scripts\SetupComplete.cmd" -Force
    }

	# If there is a customer script, call it
	if (Test-Path "$rootFolder\Customer-PE.ps1") {
        Set-OSDProgressDisplay -Message "Processing customer-specific script."
		Write-OSDLog "Calling custom script Customer-PE.ps1"
		try {
            Push-Location $rootFolder
			. "$rootFolder\Customer-PE.ps1" 2>&1 | Write-OSDLog
		}
		catch {
			Write-Warning "$(Get-OSDTimeStamp) Error from calling script: $_"
		}
        Pop-Location
	}

	# Stop progress display
    Wait-OSDProgressCommandPrompt
	Write-OSDLog "Stopping OSD progress display."
	Stop-OSDProgressDisplay

    if (Test-Path "$rootFolder\AutopilotConfigurationFile.json") {
        Cleanup
    }

	# Reboot
	exit 0
}
catch
{
	Write-OSDLog "Unhandled error:"
    Write-OSDLog -NoTimeStamp -Message $_
    Set-OSDProgressDisplay -Message "ERROR: $($_);  See $rootFolder\logs\provision-pe.log for details"

    $windowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    if ( $EnableTerminal ) {
        $windowStyle = [System.Diagnostics.ProcessWindowStyle]::Minimized
    }
	Start-Process "cmd.exe" -Wait -WindowStyle $windowStyle
    try {
        Stop-OSDProgressDisplay
    } catch {}

}

exit 0

# SIG # Begin signature block
# MIInKwYJKoZIhvcNAQcCoIInHDCCJxgCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUWD4kA3SrObtmaIEGW+8l9JKw
# wqOggiDNMIIFjTCCBHWgAwIBAgIQDpsYjvnQLefv21DiCEAYWjANBgkqhkiG9w0B
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
# CSqGSIb3DQEJBDEWBBR/aionAJz+o4lxDuff+odppqSuBTANBgkqhkiG9w0BAQEF
# AASCAYB0sEinB+ydSi7eZRa2zcGdp7L9cwNCv1Q0xfAU9FtL2bFLssnhn+LjoHCN
# 2gnpSrWOhnVVLeICKpFYI+P2uacQL8o98PeYJrgRB4LjyQpqROkAnNTN+6fzyxf+
# 0tfgGMt6q+8Mw37AU2DoU10xcHDXHFaFBJNPp9sthuR6SqSvXW/kKlCrUM6bJMFh
# D5Wl/2pizDLB/FxrbCguvdDPx3prSgUq3sllHEnSI8ff9EREP8WfLagtDG2r1y6I
# nhDgtsYjdaZ4sheZl30yfF3zHlR/3tynL//o8CHv96fLsp8m6L/rVEhLkdWwQruQ
# mcu1ivglnvhk/6UcuQdjyS4cM/wewucI6fBj1/XV4QJU1768Tj9/UbjN35wY7JVN
# EUipoReLwhZQHI0TNW/nhhcCycbLTkTsZyBYy4+FoPaTS+S/iW7yMqSTLJy7P2Y4
# zcoVgR5Ox/82N+iXU0Yuz3lx0rcSbVxuxcVdZZhbDBIYmrra7x9888/sK2uZEWLe
# oH6TNtWhggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBpMQswCQYDVQQG
# EwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0
# IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0Ex
# AhAKgO8YS43xBYLRxHanlXRoMA0GCWCGSAFlAwQCAQUAoGkwGAYJKoZIhvcNAQkD
# MQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYwNjAxMTgwODIxWjAvBgkq
# hkiG9w0BCQQxIgQgtRRb910ooHxTk00ykx82aE1pi5wIj2jc/4VZ0HCylsYwDQYJ
# KoZIhvcNAQEBBQAEggIAizLOkW6QqQRJugd3g7dze45PrewBEreQPvIlLlEDKJ0N
# ly8+BVfJHeA3V0candHpXbJcy4anjt6ByGNhAFVIxnniZlSSoYnV0en0XbiBCGLQ
# BjBD2ceZaQCqhbzX1hkU2mgpWp1AwvE73Qtdhg5IUsym0kXR59ZyCskg0KmGrEfp
# 1eOrTV/Kd+G0WIMTtBD8AwWzpDEwcgHrdKuy2Mp5UvRQuSS8AZgLympm9Nc8Q6Jl
# O07x5/FjdB1o9WrU2E2gLF/G0p1U/p3ScZPj1R6S25eqKqVeVFDYsY81JI8Pc5Tt
# 8osCuovVWipeTskG7mh1SLofs+3kRI0mKWwbgTob+suvUn350wUaVIbZ+35foYBp
# /10aqdSeswW4IpLV4yDgQyfYo2rkj8147yPEMrFVZndhRh/B4mzEDZfs4wabheHC
# oRS9VmzVaCGbRAAqHCNkbCx0huBZm2UsGEXXZ39abYx+JrMsHcbTi/2HNxH5l5yl
# GaDim0ySGGbCe3l+salT2IGr1JUIVVdU1NWzyIDxsinc3YEu72qVXIMrrTlJdPDG
# dQwYCMNaIwwTsz/nxJ3nwEUv3tkcNjZo/jbCHBgxOXV+x+GVQe8hMh4j+RJZ2s2H
# uhNo4447JKBiu5g4N1nRb1drCD1j2MknZtzQCEd7dtYPk5K2uHdW6OFSdi1GPG8=
# SIG # End signature block
