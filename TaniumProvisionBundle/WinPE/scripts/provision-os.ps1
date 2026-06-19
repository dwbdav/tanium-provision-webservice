param(
	[Switch] $desktop = $false,
	[Switch] $setupComplete = $false
)

$doDebug = $false
$script:taniumClientFolder = ""
$buildVersion = "10.9.71.0"

function Cleanup {

	try {

		# Let the system sleep
		Enable-OSDPowerSaving

		# Stop progress display (needed for cleanup to be fully successful)
		Write-OSDLog "Stopping OSD progress display."
		Stop-OSDProgressDisplay

		Write-OSDLog "The Tanium Client will be stopped before the OS restarts."

		# Stop logging
		if (-not $doDebug) {
			Write-OSDLog "Stopping transcript."
			Stop-Transcript
		}

		# Copy logs to the Tanium programdata folder
		$ProgDataFolder = "$($env:ProgramData)\Tanium\Provision"
		$logDest = "$($ProgDataFolder )\Logs"

		# Create the Progdata\Tanium\Provision folder if needed, and ensure its ACL is correct.
		Initialize-ProgDataFolder -Path $ProgDataFolder -LogPath $logDest

		# Copy the desired files (logs and config) into the folder
		$taniumStateRestored = Get-OSDVariable -Name "TaniumStateRestored"
		Copy-Item -Path "C:\_t\logs\*.log" -Destination $logDest -Force
		if (-not $doDebug -and ($taniumStateRestored -ne "")) {
			# Remove the temporary folder
			Remove-Item -Path "C:\_t" -Recurse -Force
		}
	}
	catch {
		Write-OSDLog "Error during cleanup: $_"
	}
}

function Register-ScriptForRerun {
	# Make sure we re-run after a reboot.  Windows will take care of re-launching us.
	Write-OSDLog "Telling Windows that a restart and re-execution is needed."
	Set-ItemProperty -Path "HKLM:\System\Setup" -Name "SetupShutdownRequired" -Value 1 -Type DWORD
	Set-ItemProperty -Path "HKLM:\System\Setup" -Name "SetupType" -Value 2 -Type DWORD
	Set-ItemProperty -Path "HKLM:\System\Setup" -Name "CmdLine" -Value "C:\_T\SetupComplete.cmd"
}


try
{
	$global:OSDLogFile = "$PSScriptRoot\logs\provision-os.log"
	Import-Module "$PSScriptRoot\TaniumOSD" -Force

	# Initialization
	$rootFolder = Get-OSDRootFolder
	Set-OSDLog -Path "$rootFolder\logs\provision-os.log"
	Start-Transcript -Path "$rootFolder\logs\provision-os-transcript.log" -Append

	Write-OSDLog "Starting provision-os.ps1 from tools version $($buildVersion)."

	# Keep the screen saver off, screen on, system awake
	Write-OSDLog "Disabling screen saver"
	Disable-OSDPowerSaving

	# If debug is specified, we'll alter the behavior some
	$doDebug = ((Get-OSDVariable -Name "Debug") -eq "on")
	if ($doDebug) {
		Write-OSDLog "Debugging specified."
	}

	# Get information about the current windows version/edition:
	$WinEdition = (Get-WindowsEdition -Online).Edition
	$WinVer = Get-WindowsCumulativeUpdate
	$HasSAMRollback = ($WinEdition -match "Professional(N?)$" -and $WinVer -ge [version]"10.0.26100.4061")
	$needsProvisionPost = $false

	Write-OSDLog "Running on Windows edition: $($WinEdition)"
	Write-OSDLog "Windows version: $($WinVer)"
	Write-OSDLog "Has SAM Rollback behavior if not domain joined: $($HasSAMRollback)"

	# Initialize based on command line parameters
	if ($setupComplete) {

		Write-OSDLog "Starting from SetupComplete."
		try {
			$EnableTerminal = [bool]::Parse((Get-OSDVariable -Name "EnableTerminal"))
		} catch {
			$EnableTerminal = $true
		}
		# Start the progress UI to get it in the front
		if ($doDebug) {
			Write-OSDLog "Starting OSD progress display (debug)."
			if ( $EnableTerminal ) {
				Start-OSDProgressDisplay
			} else {
				Start-OSDProgressDisplay -DisableTerminal
			}
		}
		else {
			Write-OSDLog "Starting OSD progress display (always on top)."
			if ( $EnableTerminal ) {
				Start-OSDProgressDisplay -Top
			} else {
				Start-OSDProgressDisplay -DisableTerminal -Top
			}
		}

	}
	elseif ($desktop) {
		Write-OSDLog "Starting from startup group shortcut."
	}
	else {
		# If no command line parameter was specified, we're being executed from unattend.xml
		# (via RunOnce).  Create a startup item to continue our execution from the desktop,
		# since we can then control the user experience better.

		Write-OSDLog "Starting from RunOnce."

		# Create the shortcut
		$startup = [Environment]::GetFolderPath("CommonStartup")
		$objShell = New-Object -ComObject ("WScript.Shell")
		$objShortcut = $objShell.CreateShortcut("$startup\Provision-OS.lnk")
		$objShortcut.TargetPath = "powershell.exe"
		$objShortcut.Arguments = "-noprofile -windowstyle minimized -executionpolicy bypass -file $rootFolder\provision-os.ps1 -desktop"
		$objShortcut.WindowStyle = 7
		$objShortCut.Save()

		# Start the progress UI to get it in the front
		if ($doDebug) {
			Write-OSDLog "Starting OSD progress display (debug)."
			Start-OSDProgressDisplay
		}
		else {
			Write-OSDLog "Starting OSD progress display (always on top)."
			Start-OSDProgressDisplay -Top
		}

		Write-OSDLog "Exiting to re-execute script via startup item."
		exit 0
	}

	# First pass logic (only execute once)
	$firstPass = Get-OSDVariable -Name "FirstPassDone"
	if ($firstPass -eq "") {
		$WaitForReboot = Get-OSDVariable -Name "WaitForReboot"
		if ($WaitForReboot -eq "") {

			# If using wi-fi, re-establish the connection
			$interface = Get-OSDVariable -Name "interface"
			Write-OSDLog "Chosen network interface: $interface"
			if ($interface -like 'e*' -or $interface -eq "") {
				# Ignore Ethernet interfaces
				Write-OSDLog "No Wi-Fi connection to restore."
			} else {
				Write-OSDLog "Re-connecting to Wi-Fi"

				$net = Get-OSDVariable -Name "network" | ConvertFrom-JSON
				$pass = Get-OSDVariable -Name "pass"
				# TODO: Make sure we get the right authentication and encryption values
				$Authentication = 'WPA2PSK'
				$Encryption = 'AES'

				$WirelessProfile = @'
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
	<name>{0}</name>
	<SSIDConfig>
		<SSID>
			<name>{0}</name>
		</SSID>
	</SSIDConfig>
	<connectionType>ESS</connectionType>
	<connectionMode>auto</connectionMode>
	<MSM>
		<security>
			<authEncryption>
				<authentication>{2}</authentication>
				<encryption>{3}</encryption>
				<useOneX>false</useOneX>
			</authEncryption>
			<sharedKey>
				<keyType>passPhrase</keyType>
				<protected>false</protected>
				<keyMaterial>{1}</keyMaterial>
			</sharedKey>
		</security>
	</MSM>
</WLANProfile>
'@ -f $net.SSID, $pass, $Authentication, $Encryption

				$random = Get-Random -Minimum 1111 -Maximum 99999999
				$tempProfileXML = "$env:TEMP\tempProfile$random.xml"
				$WirelessProfile | Out-File $tempProfileXML
				& netsh wlan add profile filename=$tempProfileXML | Write-OSDLog
				& netsh wlan connect name="$($net.SSID)" | Write-OSDLog
			}

			# If there is a customer script, call it
			if (Test-Path "C:\_t\Customer-Pre.ps1") {
				Set-OSDProgressDisplay -Message "Processing customer-specific script."
				Write-OSDLog "Calling custom script Customer-Pre.ps1"
				try {
					Push-Location "C:\_t"
					. "C:\_t\Customer-Pre.ps1" 2>&1 | Write-OSDLog
				}
				catch {
					Write-Warning "$(Get-OSDTimeStamp) Error from calling script: $_"
				}
				Pop-Location
			}

			# Set the time zone and force a time sync
			$timeZone = Get-OSDVariable -Name "TimeZone"
			if ($timeZone -ne "") {
				Write-OSDLog "Setting time zone to $timeZone"
				Set-TimeZone -Id "$timeZone" -ErrorAction Continue
			}
			Write-OSDLog "Attempting to synchronize time"
			net start w32time | Write-OSDLog -NoTimeStamp
			w32tm /resync /force | Write-OSDLog -NoTimeStamp

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

			# Do the offline domain join if we have a blob
			$script:djoined = $false
			if (Test-Path "$rootFolder\odjblob.txt") {

				$elapsed = Measure-Command {

					# The odjblob.txt was downloaded previously, so all we have to do is import it.
					$destFile = "$rootFolder\odjblob.txt"

					# Check if there was an error.  If so, log it.  If not, process it.
					$contents = Get-Content $destFile
					if ($contents.StartsWith("ERROR:"))
					{
						Write-OSDLog "Error reported by ODJ service:"
						$contents | Write-OSDLog -NoTimeStamp
					}
					else {
						Write-OSDLog "About to run DJOIN.EXE"
						& djoin.exe /requestodj /loadfile $destFile /windowspath $env:WINDIR /localos | Write-OSDLog -NoTimeStamp
						$rc = $LASTEXITCODE
						Write-OSDLog "DJOIN exit code = $rc"
						if ($rc -eq 0) {
							$script:djoined = $true
						}
					}
				}
				Set-OSDProgress -Details @{
					ODJExitCode = $LASTEXITCODE
					ODJElapsedTime = [int]$elapsed.TotalSeconds
				}
			}
			elseif ($computerName -ne $env:COMPUTERNAME) {
				# If no offline join and a computer name was specified, just rename the computer.
				# This would break a domain join done through unattend.xml, so don't do a domain
				# join via unattend.xml.
				Rename-Computer -NewName $computerName
				Write-OSDLog "Renamed computer to $computerName"
			}
			Set-OSDProgress -Details @{
				ComputerName = $computerName
			}

			# Clear Autologon (if necessary)
			if (-not $setupComplete) {
				Write-OSDLog "Clearing AutoLogon"
				Set-ItemProperty -Path "HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "AutoAdminLogon" -Value "0"
				Set-ItemProperty -Path "HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "DefaultUsername" -Value ""
				Set-ItemProperty -Path "HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "DefaultPassword" -Value ""
			}

			$user = Get-LocalUser | Where-Object { $_.SID -like '*-500' }
			if ( $HasSAMRollback -and (-not $script:djoined) ) {
				Write-OSDLog "Not adjusting local admin account status in provision-os.ps1 due to May 2025 changes in Windows 11 Professional, will adjust via provision-post.ps1."
				$needsProvisionPost = $true
			} else {
				# Enable the Administrator account only if not domain joined
				Write-OSDLog "Local administrator account name: $($user.Name)"
				if ($script:djoined) {
					Write-OSDLog "Ensuring local Administrator account is disabled."
					$user | Disable-LocalUser
				} else {
					Write-OSDLog "Ensuring local Administrator account is enabled."
					$user | Enable-LocalUser
				}
			}

			# Set Local Administrator password if specified
			$adminPassword = Get-OSDVariable "AdminPassword"
			if ($adminPassword -ne "") {
				$serial = Get-OSDVariable -Name "serial"
				$securePassword = ConvertTo-SecureString -String "$adminPassword-$serial" -AsPlainText -Force
				if ($HasSAMRollback -and (-not $script:djoined)) {
					Write-OSDLog "Not setting local administrator password in provision-os.ps1 due to May 2025 changes in Windows 11 Professional, will adjust via provision-post.ps1."
					$winTemp = "$($env:SystemRoot)\temp"
					if ( -not (Test-Path $winTemp) ) {
						$null = New-Item -ItemType Directory -Path "$winTemp"
					}
					$securePassword | Export-Clixml "$($winTemp)\EncryptedAdminPassword.clixml"
					$needsProvisionPost = $true
				} else {
					# Set the password using the value provided, appending the serial number
					Write-OSDLog "Setting the local Administrator password."
					$user | Set-LocalUser -Password $securePassword
				}
			}

			# Install Tanium client
			Set-OSDProgressDisplay -Message "Installing the Tanium Client."
			Write-OSDLog "Installing Tanium Client"
			& $rootFolder\SetupClient.exe /S /KeyPath=$rootFolder\tanium-init.dat | Out-Null

			Import-Module "$PSScriptRoot\TaniumClient" -Force | Write-OSDLog

			# Write the initial status info
			$script:taniumClientFolder = Get-TaniumClientPath
			$script:taniumReg = Get-TaniumRegistryPath
			if (-not (Test-Path "$taniumReg\Provision")) {
				New-Item "$taniumReg\Provision" | Out-Null
			}

			# Set deploymentID in registry immediately after TC install, to prevent looping/overwriting this deployment with the same action
			$progress = Get-OSDProgress | ConvertFrom-JSON
			if ($progress | Get-Member "DeploymentId") {
				Set-ItemProperty -Path "$taniumReg\Provision" -Name "DeploymentID" -Value $progress.DeploymentId
			}

			# If this is a refresh, restore the user state using USMT
			$refresh = Get-OSDVariable -Name "refresh"
			$migrate = Get-OSDVariable -Name "Migrate"
			if ($refresh -and ($migrate -ine "no")) {
				$elapsed = Measure-Command {
					# Stop the Tanium Client service
					Write-OSDLog "Stopping Tanium Client service."
					Stop-Service "Tanium Client"

					# Run the state restore
					Write-OSDLog "Restoring user state with USMT Loadstate.exe."
					Set-OSDProgressDisplay -Message "Restoring user state."
					$env:USMT_WORKINGDIR = "$rootFolder\temp"
					$env:TEMP = "$rootFolder\temp"
					Copy-Item -Path "$rootFolder\MigTanium.xml" -Destination "$rootFolder\USMT\MigTanium.xml" -Force
					& "$rootFolder\USMT\loadstate.exe" "$rootFolder\StateStore" /l:"$rootFolder\logs\Loadstate.log" /hardlink /nocompress /v:5 /c /lac /i:"$rootFolder\USMT\MigApp.xml" /i:"$rootFolder\USMT\MigDocs.xml" /i:"$rootFolder\USMT\MigTanium.xml" /config:"$rootFolder\USMTConfig.xml" /progress:"$rootFolder\logs\Loadstate_progress.log" | Write-OSDLog -NoTimeStamp
					$usmtExit = $LASTEXITCODE

					# Restart the service and then react to the exit code
					Start-Service "Tanium Client"
					if ($usmtExit -ne 0) {
						Write-Warning "$(Get-OSDTimeStamp) Unexpected return code from USMT LoadState.exe: $usmtExit"
						throw "Unexpected return code from USMT LoadState.exe: $usmtExit"
					}
					else {
						Write-OSDLog "USMT LoadState completed successfully."
						Write-OSDLog "Removing the state store folder $rootFolder\StateStore."
						& "$rootFolder\USMT\usmtutils.exe" /rd "$rootFolder\StateStore" /y | Write-OSDLog -NoTimeStamp
						Write-OSDLog "Return code from USMTUtils.exe: $LASTEXITCODE"
					}
				}
				Set-OSDProgress -Details @{
					USMTRestoreExitCode = $LASTEXITCODE
					USMTRestoreElapsedTime = [int]$elapsed.TotalSeconds
				}
			}

			if ($refresh) {
				Set-ItemProperty -Path "$taniumReg\Provision" -Name "Method" -Value "REFRESH"
			} else {
				Set-ItemProperty -Path "$taniumReg\Provision" -Name "Method" -Value "BAREMETAL"
			}
			Remove-ItemProperty "$taniumReg\Provision" -Name "Result" -ErrorAction Ignore
			Remove-ItemProperty "$taniumReg\Provision" -Name "Reason" -ErrorAction Ignore
			Remove-ItemProperty "$taniumReg\Provision" -Name "Timestamp" -ErrorAction Ignore
			Set-ItemProperty -Path "$taniumReg\Provision" -Name "BundleID" -Value (Get-OSDManifestSetting "id")
			Set-ItemProperty -Path "$taniumReg\Provision" -Name "BundleName" -Value (Get-OSDManifestSetting "name")

			# Set tags
			$tags = Get-OSDVariable -Name "Tags"
			if ($tags -eq "") {
				$tags = "OSD"
			}
			$tags = Resolve-OSDVariables -Value $tags
			$tags -split "," | ForEach-Object {
				Write-OSDLog "Creating tag: $_"
				Add-TaniumTag -Tag $_
			}

			# It is now safe to remove the _t folder on cleanup
			Set-OSDVariable -Name "TaniumStateRestored" -Value $true

			# Set the computer ID.  This might fail if the Tanium Client is not yet fully initialized, but that's OK.
			try {
				Set-OSDProgress -Details @{
					ComputerID = Get-ItemPropertyValue -Path "$taniumReg\Tanium Client" -Name "ComputerID"
				}
			} catch {}
		}

		# If we rebooted in WaitFor, we need to load the necessary variables/modules to process things properly:
		if (-not (Get-Module -Name "TaniumClient")) {
			Import-Module "$PSScriptRoot\TaniumClient" -Force | Write-OSDLog
			$script:taniumClientFolder = Get-TaniumClientPath
			$script:taniumReg = Get-TaniumRegistryPath
		}

		# Wait for Deploy and Patch tools
		$waitFors = Get-OSDVariable -Name "WaitFor"
		foreach ( $waitFor in $waitFors.Trim().Split("|") ) {
			switch -Regex ($waitFor.Trim()) {
				"^Reboot$" {
					if ( $WaitForReboot -ne "" ) {
						# We've already rebooted, so continue to the next WaitFor entry, and clear the WaitForReboot var so we don't loop
						Clear-OSDVariable -Name "WaitForReboot"
						$WaitForReboot = ""

						continue
					} else {
						# Reboot and come back here.
						# Set Variable so we know to skip to WaitFor and not reboot a second time.
						Set-OSDVariable -Name "WaitForReboot" -Value "True"

						# Make sure we run after reboot
						Register-ScriptForRerun

						# Tell TC to stop before rebooting so it gracefully stops any ongoing sensor evaluations.
						Stop-TaniumClient

						# And exit to trigger the reboot
						exit
					}
				}
				"^CX$" {
					$toolList = "SoftwareManagement", "Patch"
					Write-OSDLog "Waiting for tools: $($toolList -join ' ')"
					Set-OSDProgressDisplay -Message "Waiting for tools: $($toolList -join ' ')"
					do {
						$waiting = ""
						$toolList | ForEach-Object {
							$toolInfo = Get-TaniumToolInfo -Name $_
							if ($toolInfo -eq $null) {
								$waiting = "$waiting $($_) "
							}
						}
						if ( $waiting -ne "" ) {
							Write-OSDLog "Waiting for tools: $waiting"
							Set-OSDProgressDisplay -Message "Waiting for tools: $waiting"
							Start-Sleep -Seconds 30
						}
					} while ($waiting -ne "")
				}
				"^C:\\" {
					while (-not (Test-Path $waitFor)) {
						Write-OSDLog "Waiting for path: $waitFor"
						Set-OSDProgressDisplay -Message "Waiting for path: $waitFor"
						Start-Sleep -Seconds 30
					}
				}
			}
		}

		# Set a flag to make sure this doesn't run again
		Set-OSDVariable -Name "FirstPassDone" -Value "True"

		# End of the first pass logic
	} else {
		# Second/nth pass logic

		# Load TaniumClient module
		Import-Module "$PSScriptRoot\TaniumClient" -Force | Write-OSDLog
		$script:taniumClientFolder = Get-TaniumClientPath
		$taniumReg = Get-TaniumRegistryPath
	}

	# If there is a customer script, call it
	if (Test-Path "C:\_t\Customer.ps1") {
		# Keep a count of passes
		$pass = Get-OSDVariable -Name "ExecutionPass"
		if ($pass -eq "") {
			$pass = 0
		}
		$pass = ([int]$pass) + 1
		Set-OSDVariable -Name "ExecutionPass" -Value $pass

		# Run the script
		Set-OSDProgressDisplay -Message "Processing customer-specific script."
		Write-OSDLog "Calling custom script Customer.ps1 (pass $pass)"
		try {
            Push-Location "C:\_t"
			. "C:\_t\Customer.ps1" 2>&1 | Write-OSDLog
		}
		catch {
			Write-Warning "$(Get-OSDTimeStamp) Error from calling script: $_"
		}
		Pop-Location
	}

	# If the customer script asked for a reboot, do it.
	$customerReboot = Get-OSDVariable -Name "RebootAndRerun"
	$waitForReboot = Get-OSDVariable -Name "WaitForReboot"
	if ($customerReboot -ne "" -or $waitForReboot -ne "") {

		# Clear the flag so we don't get in an infinite loop.  The customer.ps1 script can
		# re-set it, but that's fine for it to do.
		Clear-OSDVariable -Name "RebootAndRerun"

		Register-ScriptForRerun
	} else {
		# No re-run needed, do some cleanup and then we're done.

		# Remove the startup shortcut if it exists
		$startup = [Environment]::GetFolderPath("CommonStartup")
		if (Test-Path "$startup\Provision-OS.lnk") {
			Write-OSDLog "Removing startup folder item."
			Remove-Item -Path "$startup\Provision-OS.lnk" -ErrorAction Ignore
		}

		# Report that we are complete and successful
		Set-OSDProgress -Details @{
			Status = "Complete"
			EndTime = "{0:yyyy}-{0:MM}-{0:dd} {0:HH}:{0:mm}:{0:ss}" -f ((Get-Date).ToUniversalTime())
			EndResult = "SUCCESS"
		}

		# Save details
		$progress = Get-OSDProgress | ConvertFrom-JSON
		if ($progress | Get-Member "DeploymentId") {
			Set-ItemProperty -Path "$taniumReg\Provision" -Name "DeploymentID" -Value $progress.DeploymentId
		}
		Set-ItemProperty -Path "$taniumReg\Provision" -Name "Result" -Value "SUCCESS"
		Set-ItemProperty -Path "$taniumReg\Provision" -Name "Timestamp" -Value (Get-OSDTimeStamp).Trim("[","]")
		Set-ItemProperty -Path "$taniumReg\Provision" -Name "ProgressJSON" -Value (Get-OSDProgress)
		Set-ItemProperty -Path "$taniumReg\Provision" -Name "Progress" -Value (Get-OSDProgressMinimal)

		# Prepare for a final restart
		if ($setupComplete) {
			if (Test-Path "C:\Windows\Setup\Scripts\SetupComplete.cmd") {
				Remove-Item -Path "C:\Windows\Setup\Scripts\SetupComplete.cmd" -Force
			}
			Write-OSDLog "Telling Windows that a restart is needed."
			Set-ItemProperty -Path "HKLM:\System\Setup" -Name "SetupShutdownRequired" -Value 1 -Type DWORD
			Set-ItemProperty -Path "HKLM:\System\Setup" -Name "SetupType" -Value 0 -Type DWORD
			Set-ItemProperty -Path "HKLM:\System\Setup" -Name "CmdLine" -Value ""
		}

		if ($needsProvisionPost) {
			Write-OSDLog "Registering provision-post.ps1 as a scheduled task."
			# Register provision-post.ps1 as a next-boot scheduled task if appropriate.
			$scriptTargetPath = "$($env:SystemRoot)\temp\provision-post.ps1"
			Copy-Item "C:\_t\provision-post.ps1" $scriptTargetPath
			$arguments = @()
			# If we are not djoined, we need to enable the local admin account
			if (-not $script:djoined ) {
				$arguments += "-EnableLocalAdmin"
			}
			Register-SelfDestructingScheduledTask -TaskName "Provision-Post" -TaskDescription "Post-OS-install commands for Tanium Provision" -scriptPath $scriptTargetPath -scriptArgumentList $arguments
		}

		# Clean up
		Cleanup
	}
}
catch
{
	# Unhandled exception.  Log as much information as we can, and then clean up.
	$e = $_.Exception

	Write-OSDLog "Unhandled error:"
	Write-OSDLog -NoTimeStamp -Message $e.Message
	Write-OSDLog -NoTimeStamp -Message $_.InvocationInfo.PositionMessage

	# This could fail if the error occurred before the Tanium Client is installed
	try {
		$taniumReg = Get-TaniumRegistryPath
	}
	catch
	{
        if ( [IntPtr]::Size -ne 8  ) {
            $taniumReg = 'HKLM:\Software\Tanium'
        }
        else {
            $taniumReg = 'HKLM:\Software\WOW6432Node\Tanium'
        }
	}

	# Report the failure
	Set-OSDProgress -Details @{
		Status = "Failed"
		EndTime = "{0:yyyy}-{0:MM}-{0:dd} {0:HH}:{0:mm}:{0:ss}" -f ((Get-Date).ToUniversalTime())
		EndResult = "FAILURE"
	}

	# Record the error details
	Set-ItemProperty -Path "$taniumReg\Provision" -Name "Result" -Value "FAILURE"
	Set-ItemProperty -Path "$taniumReg\Provision" -Name "Reason" -Value $_
	Set-ItemProperty -Path "$taniumReg\Provision" -Name "Timestamp" -Value (Get-OSDTimeStamp)
	Set-ItemProperty -Path "$taniumReg\Provision" -Name "ProgressJSON" -Value (Get-OSDProgress)
	Set-ItemProperty -Path "$taniumReg\Provision" -Name "Progress" -Value (Get-OSDProgressMinimal)

	# Prepare for restart
	if ($setupComplete) {
		if (Test-Path "C:\Windows\Setup\Scripts\SetupComplete.cmd") {
			Remove-Item -Path "C:\Windows\Setup\Scripts\SetupComplete.cmd" -Force
		}
		Write-OSDLog "Telling Windows that a restart is needed."
		Set-ItemProperty -Path "HKLM:\System\Setup" -Name "SetupShutdownRequired" -Value 1 -Type DWORD
		Set-ItemProperty -Path "HKLM:\System\Setup" -Name "SetupType" -Value 0 -Type DWORD
		Set-ItemProperty -Path "HKLM:\System\Setup" -Name "CmdLine" -Value ""
	}

	# Clean up
	Cleanup

}
finally {

	# Restart
	Write-OSDLog "Restarting the computer"
	# Tell TC to stop before rebooting so it gracefully stops any ongoing sensor evaluations.
	Write-OSDLog "Stopping Tanium Client service"
	Stop-TaniumClient
	# Have to use legacy shutdown command to provide a reason code.
	# Reason code 2:4 is "Operating System: Reconfiguration (Planned)"
	shutdown /r /t 0 /d p:2:4 /c "Operating System Deployment"
}

exit 0

# SIG # Begin signature block
# MIInKwYJKoZIhvcNAQcCoIInHDCCJxgCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUSLIZul6yaTpRzEMut9JYGhYp
# KAuggiDNMIIFjTCCBHWgAwIBAgIQDpsYjvnQLefv21DiCEAYWjANBgkqhkiG9w0B
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
# CSqGSIb3DQEJBDEWBBR6li9mjxs9KH1fPot2EMSUtxoP8DANBgkqhkiG9w0BAQEF
# AASCAYCKBPCcZmwN+5RrqS4A8DR2Nj4qXGgKOGNBY9OQcTnx4NVpwrqCDmtRWDyV
# 5rXOs+cbm7W5oTghxeKd/UdqGk+fYgFHTM8qy8fn7iTysLlkElUT+N712KdOJvn8
# 0yuj4jNCj/uRpDGxJZREiI0G2z/5Rpuz5lNKic3zj9R5mzMn1gwGASWO5qy1mWHA
# ZXT5eXjcIk3b7lXjZGoLdHu+/NGZTUe7KzcVFcBxuv9Rhg7hVIAX8OLT0t5Lsd3/
# IyR0SE1WF27SC7wMG6fjWYqjbiqeSByZGGGrUOtk6OBWlJwRKSOEpb2lah2GBdmw
# TIflVmjTMbp48ni4t+JjWJYbRwj1DIHvv0bwRoWk5qDSHlNl2PKorN+SR4uFOP6+
# jAKuj/ay4U5M2vuKz+Ti+APpXJZ6XpbH4Hn+AyBMoAG2oZJlL6H6saFKoDKvnOTh
# 1HCfxOyBeeDkLFFQS1OxGFr5t7VIOlAk5RLp3FLUdyXmMxkJpUrZXGOSIT7DRVJY
# W+7vxyyhggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBpMQswCQYDVQQG
# EwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0
# IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0Ex
# AhAKgO8YS43xBYLRxHanlXRoMA0GCWCGSAFlAwQCAQUAoGkwGAYJKoZIhvcNAQkD
# MQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYwNjAxMTgwODE1WjAvBgkq
# hkiG9w0BCQQxIgQgX9Yf/fTpQBw6F9jsd3mDWSGe7wwxLk1xr7LnWv8vlJAwDQYJ
# KoZIhvcNAQEBBQAEggIAN+omrzvKGLzZhWkMsNvi7UVG7HqYWbxoGIG2EEgSQ2rZ
# vli0AqFrpRWnY+x7MExlP92/+2/n/renBgYRAFzph7Pe+4OQLW3PLjJILzMpL6pK
# W6CLhu9jU8929GZZlMD5p9ZTH+ZADZLu9LFca9xG92gIOsxSsg3gQxq6zYNP77RR
# 7JxVfvds8VJOTiyJ4U7xFS/KETboizbkSjwf1crP8BriCq2neBqWMMGNS7tcNIvd
# MOhcNTidDYcH0Au2zWtar+KJar3yGMRHD7FE5r2Xhcg9lFnSVTJlDQlXr9XGmQYC
# DidmXwRkN8KX9o6MVzjYby95IYvUeq71CqzQc7nfHwIOXOROzW/4J9N1KW5EOdMg
# C+cY4Am+rK29O6J7XMs9Sq9owF2HA2sZlu5kE7hI8Zmo8M8gjkst1SMUal1gaBU6
# jz5cqGslqCnEWwzZvHtk4IBqo7YrQ4IjxQ02aAaaiDOfZHZjXjXvwbzJKsB1gbrD
# /QzxgROnLxxpDoAC+hXVepML5ozl09ijn0iA1HHVyUm+O7E+gwRmhojl3O75Ntlb
# KcyaqMFaP0ZNjpuRNArxDgkVq8ImX+3Dd1ZmMOpkJZY/j7yfu6VycBtRVYXU3yTA
# qKJeEbZk6PvSwMMaoiEcsW95zjihlXHH0/S5iXQkNbdnmjtqW/nJRE0nbM/52iA=
# SIG # End signature block
