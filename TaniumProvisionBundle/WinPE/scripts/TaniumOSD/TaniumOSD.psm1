enum OSDFileType {
    INVALID = 0
    OSIMAGE = 1
    UNATTEND = 2
    SCRIPTS = 3
    DRIVER = 4
    PATCH = 5
    CLIENT = 6
    ADK = 7
    LOGO = 8
    CLOUDINIT = 9
}
enum OSPlatform {
    WINDOWS = 0
    LINUX = 1
}
enum OSType {
    INVALID = 0
    ALMA = 1
    CENTOS = 2
    DEBIAN = 3
    OPENSUSE = 4
    REDHAT = 5
    ROCKY = 6
    SUSE = 7
    UBUNTU = 8
    WINDOWS = 99
}

function Get-OSDTimeStamp {
	return "[$((Get-Date).ToUniversalTime().ToString('u'))]"
}

function Get-OSDDrive {
    [CmdletBinding()]
    param(
    )

    Process {
        $root = Get-OSDRootFolder
        if ($root -eq "") {
            return ""
        }
        else {
            return $root.Substring(0,3)
        }
    }
}

function Get-OSDBootDrive {
    [CmdletBinding()]
    param(
        [switch] $Force = $false
    )

    Process {
        if ($null -ne $global:OSDBootDrive) {
            return $global:OSDBootDrive
        }
        # Ideally we'd use Get-Volume, but that's not available on older OSes
        Get-CimInstance -ClassName Win32_Volume | ForEach-Object {
            if ($_.Label -ieq "BOOT") {
                if ($null -ne $_.DriveLetter) {
                    $global:OSDBootDrive = $_.DriveLetter.Substring(0, 1)
                }
                if ($Force) {
                    $sDrive = "$(Get-OSDRootFolder)\esp"
                    if (-not (Test-Path $sDrive)) {
                        MkDir $sDrive | Out-Null
                    }
                    mountvol $sDrive $_.DeviceID | Write-OSDLog
                    $global:OSDBootDrive = $sDrive
                }
                else {
                    $global:OSDBootDrive = $_.DeviceID
                }
            }
        }
        return $global:OSDBootDrive
    }
}
function Get-OSDRootFolder {
    [CmdletBinding()]
    param(
    )

    Process {
        if ($null -ne $global:OSDRootFolder) {
            return $global:OSDRootFolder
        }
        
        # Ideally we'd use Get-Volume, but that's not available on older OSes
        Get-CimInstance -ClassName Win32_Volume | ForEach-Object {
            if (($null -ne $_.DriveLetter) -and (Test-Path "$($_.DriveLetter)\_T")) {
                $global:OSDRootFolder = "$($_.DriveLetter)\_T"
            }
        }
        return $global:OSDRootFolder
    }
}

function Get-OSDManifestSetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [String] $Name
    )    

    Process {
        if ($global:OSDManifest.PSObject.Properties[$Name]) {
            return $global:OSDManifest.PSObject.Properties[$Name].Value
        } else {
            return ""
        }
    }
}

function Get-OSDManifestFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [OSDFileType] $FileType
    )    

    Process {
        $global:OSDManifest.files | Where-Object { $_.type -eq $FileType } | ForEach-Object { $_.name }
    }
}

function Get-OSDVariable
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string] $Name
    )    

    Process {
        if ($global:OSDSettings.PSObject.Properties[$Name]) {
            return $global:OSDSettings.PSObject.Properties[$Name].Value
        } else {
            return ""
        }
    }
}

function Set-OSDVariable
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string] $Name,
        [Parameter(Mandatory=$true)] [string] $Value
    )    

    Process {
        # Update existing value if it exists, otherwise add a new one
        if ($global:OSDSettings.PSObject.Properties[$Name]) {
            $global:OSDSettings.$Name = $Value
        } else {
            Add-Member -InputObject $global:OSDSettings -MemberType NoteProperty -Name $Name -Value $Value
        }
        # Write out the updated settings.json file
        $global:OSDSettings | ConvertTo-JSON | Set-Content "$(Get-OSDRootFolder)\settings.json"
    }
}

function Clear-OSDVariable
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string] $Name
    )

    Process {
        # If the setting exists, remove it
        if ($global:OSDSettings.PSObject.Properties[$Name]) {
            $global:OSDSettings.PSObject.Properties.Remove($Name)
        }
        # Write out the updated settings.json file
        $global:OSDSettings | ConvertTo-JSON | Set-Content "$(Get-OSDRootFolder)\settings.json"
    }
}

function Resolve-OSDVariables
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string] $Value
    )

    Process {
        $newVal = $Value
        try {
            $search = $Value | Select-String -Pattern "%((?:\w+(?::(-?\d+))?)+)%" -AllMatches
            if ($null -ne $search) {
                Write-OSDLog "Resolving the following OSD variables:`r`n$($search)"
                $search.matches | ForEach-Object {
                    $match = $_
                    try {
                        if ($_ -notlike "*AdminPass*") {
                            Write-OSDLog "Resolving $($_)"
                        }
                        else {
                            Write-OSDLog "Resolving AdminPass"
                        }
                        # Figure out the variable name
                        $var = ($_.groups[1].Value.Split(":"))[0]
                        $varVal = Get-OSDVariable -Name $var
                        # Set default replacement to blank.
                        $replacement = ""
                        # Only process more if the variable isn't null/empty, or if it's RAND.
                        # Figure out the length
                        $len = [int] $_.groups[2].Value
                        # If the variable isn't null/empty
                        if ( -not [System.String]::IsNullOrEmpty($varVal) ) {
                            if (($null -eq $_.groups[2]) -or ($len -eq 0)) {
                                # No length, use the whole value
                                $len = $varVal.Length
                            } elseif ($len -lt 0) {
                                # Negative length, use the rightmost characters
                                if ([Math]::Abs($len) -gt $varVal.Length) {
                                    # Too long, use actual length
                                    $len = $varVal.Length
                                }
                            } elseif ($len -gt $varVal.Length) {
                                $len = $varVal.Length
                            }

                            # Calculate the replacement
                            if ($len -lt 0) {
                                $len = [Math]::Abs($len)
                                $replacement = $varVal.Substring($varVal.Length - $len, $len)
                            } else {
                                $replacement = $varVal.Substring(0, $len)
                            }
                        } elseif ($var -ieq "RAND") {
                            if ($len -eq 0) {
                                # If specifying RAND without a number of digits, pick 6 as a default length
                                $len = 6
                            }
                            $randomNum = Get-Random -Maximum ([int64]([Math]::Pow(10,$len)))
                            $replacement = ([string]$randomNum).PadLeft($len, "0")
                        }

                        # Do the replacement
                        $newVal = $newVal.Replace($_.groups[0], $replacement)

                        if ($_ -notlike "*AdminPass*") {
                            Write-OSDLog "Resolved variable: $($replacement)"
                        }
                        else {
                            Write-OSDLog "Returning resolved $($_)"
                        }
                    } catch {
                        Write-OSDLog "Error processing OSD variable resolution for variable $($match): $_"
                    }
                }
            }
            return $newVal
        } catch {
            Write-OSDLog "Error processing OSD Variable resolutions: $_"
            return $newVal
        }
    }
}

function Start-OSDProgressDisplay
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)] [switch] $Top = $false,
        [Parameter(Mandatory=$false)] [switch] $DisableTerminal = $false
    )

    Begin {
        # Make sure the registry is configured appropriately
        if (-not (Test-Path "HKCU:\Software\TaniumOSD")) {
            New-Item "HKCU:\Software\TaniumOSD" | Out-Null
        }
        Set-ItemProperty -Path "HKCU:\Software\TaniumOSD" -Name "Message" -Value "Initializing..."
        Set-ItemProperty -Path "HKCU:\Software\TaniumOSD" -Name "Version" -Value $global:BUILD_VERSION
        Remove-ItemProperty -Path "HKCU:\Software\TaniumOSD" -Name "Percent" -ErrorAction Ignore
        $ArgumentList = @()
        if ($Top) {
            $ArgumentList += "/TOP"
        }
        if ($DisableTerminal) {
            $ArgumentList += "/NODEBUG"
        }

    }

    Process {
        # Start the process
        if ($ArgumentList.Count -ge 1) {
            # Specify to make the progress UI always on top
            $script:progressProcess = Start-Process -FilePath $script:exe -WorkingDirectory $PSScriptRoot -PassThru -ArgumentList $ArgumentList
        } else {
            # Don't force the progress UI to always be on top
            $script:progressProcess = Start-Process -FilePath $script:exe -WorkingDirectory $PSScriptRoot -PassThru
        }
    }
}

function Wait-OSDProgressCommandPrompt {
    [CmdletBinding()]
    param(
    )

    Process {
        if ($script:progressProcess) {
            $children = Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $($script:progressProcess.Id)"
            while ($children) {
                Set-OSDProgressDisplay -Message "Waiting for Command Prompt processes to exit."
                Write-OSDLog "Waiting for F8 child processes to exit."
                Start-Sleep -Seconds 2
                $children = Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $($script:progressProcess.Id)"
            }
        }
    }
}

function Stop-OSDProgressDisplay
{
    [CmdletBinding()]
    param(
    )

    Process {
        if ($script:progressProcess) {
            $script:progressProcess | Stop-Process
        }
        else {
            $root = [io.path]::GetFileNameWithoutExtension($script:exe)
            Get-Process -Name $root -ErrorAction Ignore | Stop-Process
        }
    }
}

function Set-OSDProgressDisplay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string] $Message,
        [Parameter(Mandatory=$false)] [int] $Percent = -1
    )

    Process {
        Set-ItemProperty -Path "HKCU:\Software\TaniumOSD" -Name "Message" -Value $Message
        if (($Percent -ge 0) -and ($Percent -lt 100)) {
            Set-ItemProperty -Path "HKCU:\Software\TaniumOSD" -Name "Percent" -Value $Percent
        }
        else {
            Remove-ItemProperty -Path "HKCU:\Software\TaniumOSD" -Name "Percent" -ErrorAction Ignore
        }
    }
}

function Invoke-OSDCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string] $Command,
        [Parameter(Mandatory=$false)] [string] $WorkingDirectory = "",
        [Parameter(Mandatory=$false)] [string] $Arguments
    )

    Process {
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.CreateNoWindow = $true 
        $processInfo.UseShellExecute = $false 
        $processInfo.RedirectStandardOutput = $true 
        $processInfo.RedirectStandardError = $true 
        $processInfo.FileName = $Command 
        $processInfo.Arguments = @($Arguments) 
        if ($WorkingDirectory -ne "") {
            $processInfo.WorkingDirectory = $WorkingDirectory
        }
        $process = New-Object System.Diagnostics.Process 
        $process.StartInfo = $processInfo 
        [void]$process.Start()
        do
        {
           $process.StandardOutput.ReadLine()
        }
        while (!$process.HasExited)
        return $process
    }
}

function Set-OSDProgress
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [hashtable] $Details
    )

    Process {
        # Read the current progress.json
        $progressJson = "$(Get-OSDRootFolder)\progress.json"
        $progress = @{}
        if (Test-Path $progressJson) {
            $t = Get-Content $progressJson | ConvertFrom-Json
            $t.PSObject.Properties | ForEach-Object {
                $progress[$_.Name] = $_.Value
            }
        }
        # Add the provided details to it
        $Details.Keys | ForEach-Object {
            $progress[$_] = $Details[$_]
        }
        # Write the progress back out
        $progressText = $progress | ConvertTo-JSON
        $progressText | Out-File -FilePath $progressJson
        Write-OSDLog "Writing progress JSON to $($progressJson)."
        # Try to POST the progress
        try {
            $response = Invoke-WebRequest -Uri "$(Get-OSDVariable -Name 'anchor')/progress" -Method POST -Body $progressText -UseBasicParsing
            Write-OSDLog "Progress posted with response $($response.StatusCode)"
        }
        catch
        {
            Write-OSDLog "WARNING: Unable to POST progress to $(Get-OSDVariable -Name 'anchor')/progress: $_"
        }
    }
}

function Get-OSDProgress
{
    [CmdletBinding()]
    param(
    )

    Process {
        $progressJson = "$(Get-OSDRootFolder)\progress.json"
        return (Get-Content -Path $progressJson -Raw).Replace("`n", "")
    }
}

function Get-OSDProgressMinimal
{
    [CmdletBinding()]
    param(
    )

    Process {
        # Read the current progress.json
        $progressJson = "$(Get-OSDRootFolder)\progress.json"
        $progress = @{}
        if (Test-Path $progressJson) {
            $t = Get-Content $progressJson | ConvertFrom-Json
            $t.PSObject.Properties | ForEach-Object {
                $progress[$_.Name] = $_.Value
            }
        }
        # Write startTime with just the date followed by 00:00:00.  Trying to limit cardinality of results.
        $startTime = $progress.StartTime.split(' ')[0] + " 00:00:00"
        $progressArray = ($progress.DeploymentId, $progress.BundleId, $progress.EndResult, $progress.Method, $progress.Status, $startTime)
        $osdProgressMinimal = $progressArray -join "|"
        Write-OSDLog "Current minimal progress:`r`n$($osdProgressMinimal)"
        return $osdProgressMinimal
    }    
}

function Disable-OSDPowerSaving {
    [CmdletBinding()]
    param(
    )

    Process {
        # Keep the machine from going to sleep
	    $script:ste::SetThreadExecutionState($script:ES_CONTINUOUS -bor $script:ES_AWAYMODE_REQUIRED -bor $script:ES_DISPLAY_REQUIRED -bor $script:ES_SYSTEM_REQUIRED)
    }
}

function Enable-OSDPowerSaving {
    [CmdletBinding()]
    param(
    )

    Process {
        # Revert back to normal, let the machine sleep
		$script:ste::SetThreadExecutionState($script:ES_CONTINUOUS)
    }
}

function Get-OSDDirectDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)] [string] $LicenseType = 'vol',
        [Parameter(Mandatory=$true)] [string] $Build,
        [Parameter(Mandatory=$true)] [string] $Architecture,
        [Parameter(Mandatory=$true)] [string] $Language
    )

    Process {

        if ($Build -in '19045', '22631','26100') {
            $searchPattern = '^https?:\/\/dl\.delivery\.mp\.microsoft\.com\/filestreamingservice\/files\/.*\/(?<build>{4})\.(?<revision>[0-9]*)\..*(?<search>{0}_{1}{2}_{3})\.esd$' -f ( $LicenseType, $Architecture, 'fre', $Language, $Build )
            switch ($build) {
                '19045' {
                    Write-OSDLog "Using Media Creation Tool Metadata for Windows 10 19045"
                    $Uri = 'https://download.microsoft.com/download/7/9/c/79cbc22a-0eea-4a0d-89c0-054a1b3aa8e0/products.cab'
                }
                '22631' {
                    Write-OSDLog "Using Media Creation Tool Metadata for Windows 11 22631"
                    $Uri = 'https://download.microsoft.com/download/6/2/b/62b47bc5-1b28-4bfa-9422-e7a098d326d4/products_win11_20231208.cab'
                }
                '26100' {
                    Write-OSDLog "Using Media Creation Tool Metadata for Windows 11 26100"
                    $Uri = 'https://download.microsoft.com/download/6/2/b/62b47bc5-1b28-4bfa-9422-e7a098d326d4/products-Win11-20241004.cab'
                }
            }
            $ProductData = Get-MediaCreationToolProductData -Uri $Uri

            # The MCT data will list several editions that all use the same ESD file.
            $foundESD = $ProductData.MCT.Catalogs.Catalog.PublishedMedia.Files.File | ForEach-Object {
                if ($_.FilePath -match $searchPattern) {
                    New-Object -TypeName PSCustomObject -Property @{
                        '0' = $_.FilePath
                        'sha1' = $_.Sha1
                        'search' = $matches.search
                        'build' = $matches.build
                        'revision' = $matches.revision
                    }
                }
            } | Sort-Object -Property @{Expression={[version]::new($_.build,$_.revision)}} | Select-Object -Last 1
        } else {
            $searchPattern = "^https?\:(?>[^\/]*\/)*(?<build>{4})\.(?<revision>[0-9]*)\..*(?<search>{0}_{1}{2}_{3})_(?<sha1>[0-9a-f]*)\.esd$" -f ( $LicenseType, $Architecture, 'fre', $Language, $Build )
            # Download the control file
            $controlUrl = "https://content.tanium.com/files/tsw/update-map.xml.gz"
            Write-OSDLog "Downloading direct download details from $($controlUrl)"
            $destCompressed = "$(Get-OSDRootFolder)\update-map.xml.gz"
            Invoke-WebRequest -Uri $controlURL -OutFile $destCompressed -UseBasicParsing
            # Decompress it
            $compressed = New-Object System.IO.FileStream $destCompressed, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read)
            $decompressed = New-Object System.IO.MemoryStream
            $gzipStream = New-Object System.IO.Compression.GzipStream $compressed, ([IO.Compression.CompressionMode]::Decompress)
            $gzipStream.CopyTo( $decompressed )
            $compressed.Close()
            # Convert it to XML
            [xml] $WUData = [System.Text.Encoding]::ASCII.GetString($decompressed.toarray())
            # Search for the specified version
            $foundESD = $WUData.updates.update.url.'#cdata-section' | ForEach-Object {
                if ( $_ -match $searchPattern ) {
                    # $matches.remove(0);
                    [pscustomobject]$matches
                }
            } | Sort-Object -Property @{Expression={[version]::new($_.build,$_.revision)}} | Select-Object -last 1
        }
        $foundESD | Out-String -Width 200 | Write-Verbose
        $foundESD
    }
}

function Get-MediaCreationToolProductData {
    param (
        $Uri
    )
    Write-OSDLog "Downloading direct download details from $($Uri)"
    $ProductsCab = Join-Path $env:TEMP 'Products.cab'
    $ProductsXmlFile = Join-Path $env:TEMP 'Products.xml'
    if (Test-Connectivity -Uri $Uri) {
        # Save current progress preference and hide the progress
        $prevProgressPreference = $global:ProgressPreference
        $global:ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Uri -OutFile $ProductsCab -UseBasicParsing
        $global:ProgressPreference = $prevProgressPreference
        if (Test-Path -Path $ProductsCab) {
            Write-OSDLog "Extracting data file"
            Expand-Cab -Path $ProductsCab -Destination $ProductsXmlFile | Out-Null
            if (Test-Path -Path $ProductsXmlFile) {
                [xml]$ProductData = Get-Content -Path $ProductsXmlFile
                $ProductData
            }
            else {
                Write-OSDLog "Unable to find $($ProductsXmlFile)"
            }
        }
        else {
            Write-OSDLog "Unable to find $($ProductsCab)"
        }
    }
    else {
        Write-OSDLog "Unable to connect to $($Uri)"
    }

}

function Test-Connectivity {
    [CmdletBinding()]
    param (
        $Uri
    )
    Write-OSDLog "Attempting to read file size from $Uri"
    try {
        # Save current progress preference and hide the progress
        $prevProgressPreference = $global:ProgressPreference
        $global:ProgressPreference = 'SilentlyContinue'
        [int]$Size = (Invoke-WebRequest -Uri $Uri -Method Head -ErrorAction Stop -UseBasicParsing).Headers.'Content-Length' | Select-String -Pattern '\d+' -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Value }
        $global:ProgressPreference = $prevProgressPreference
        if ($Size -gt 0) {
            Write-Output $true
        }
        else {
            Write-OSDLog "Size is not greater than 0"
            Write-Output $false
        }
    }
    catch {
        Write-OSDLog "Unable to read file size from $Uri"
        Write-Output $false
    }
}

function Expand-Cab {
    param (
        $Path,
        $Destination
    )
    if (Test-Path -Path $Path) {
        # Find expand.exe path
        $ExpandExe = "$env:windir\system32\expand.exe"
        if (Test-Path -Path $ExpandExe) {
            & "$ExpandExe" "$Path" -F:* "$Destination"
        }
        else {
            Write-OSDLog "Unable to find expand.exe"
        }
    }
    else {
        Write-OSDLog "Unable to find $Path"
    }
}

function Resolve-BCDEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [switch] $All
    )

    try {
        if ( $all ) {
            $output = bcdedit /enum all
        } else {
            $output = bcdedit
        }

        Write-Verbose ($output -join [system.environment]::newline)

        $outEntries = @()
        $currentEntry = @{}
        $output | ForEach-Object {
            if ( $_ -match "^ " -or $_.Trim() -match "^$" ) {
                Write-Verbose "Skipping empty line: $($_)"
                #skip empty lines and lines that don't have an identifier on the left
            } else {
                $splitLine = $_.Split(" ",2) | ForEach-Object {$_.Trim()}
                switch -Regex ($splitline[0]) {
                    "^-+$" {
                        Write-Verbose "New entry starting, currentEntry: $($currentEntry)"
                        # New entry is starting, add prior entry to array, clear new entry.
                        if ( $currentEntry["identifier"] -ne "" ) {
                            Write-Verbose "Adding entry: $currentEntry"
                            $outEntries += New-Object -TypeName pscustomobject -Property $currentEntry
                        }
                        $currentEntry = @{}
                        #and, the "-------------------" divider is after the type header, so grab the prior line as the type.
                        $currentEntry["type"] = $lastLine
                        Write-Verbose "New entry type: $($lastLine)"
                    }
                    "identifier" {
                        Write-Verbose "Adding identifier $($splitLine[1])"
                        $currentEntry["identifier"] = $splitLine[1]
                    }
                    "description" {
                        Write-Verbose "Adding description $($splitLine[1])"
                        $currentEntry["description"] = $splitLine[1]
                    }
                    "device" {
                        Write-Verbose "adding device $($splitLine[1])"
                        $currentEntry["device"] = $splitLine[1]
                    }
                    "path" {
                        Write-Verbose "adding path $($splitLine[1])"
                        $currentEntry["path"] = $splitLine[1]
                    }
                }
                $lastLine = $_
            }
        }

        Write-Verbose "Returning $($outEntries.count) entries"
        return $outEntries
    } catch {
        Write-Error "failed to enumerate BCD Entries:"
        $_.Exception
        throw "Failed to enumerate BCD entries:"
    }
}

function Remove-OSDBCDEntries {
    [CmdletBinding()]
    param()

    # Clean up BCD
    try {
        $entries = Resolve-BCDEntries -All
        $changes = $false
        foreach ( $entry in $entries ) {
            if ( $entry.description -eq "Tanium Windows PE" -or ( $entry.identifier -eq "{00000001-ffff-ffff-ffff-000000000001}" -and $entry.device -match "ramdisk=\[.:\]\\_t\\esp\\sources\\boot\.wim" ) ) {
                    Write-OSDLog "Removing BCD entry $($entry.identifier)"
                    bcdedit /delete $entry.identifier | Write-OSDLog
                    $changes = $true
            }
        }
        if ($changes) {
            bcdedit /timeout 0 | Write-OSDLog
        }
    } catch {
        Write-OSDLog "Error cleaning up BCD (non-fatal): $_"
    }
}

function Set-OSDLog {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Path
    )
    try {
        "$(Get-OSDTimeStamp) Logging to $($Path)." | Out-Host | Out-File -FilePath $Path -Append
        $global:OSDLogFile = $Path
    } catch {
        "$(Get-OSDTimeStamp) Error setting Log file to $($Path): $_"
    }
}

function Write-OSDLog {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline=$true)]
        [object[]]
        $Message,
        [Parameter()]
        [switch]
        $NoTimeStamp
    )
    process {
        foreach ($object in $message) {
            if ( -not $NoTimeStamp ) {
                $timeStamp = "$(Get-OSDTimeStamp) "
            }
            if ( $global:OSDLogFile -and (Test-Path $global:OSDLogFile) ) {
                "$($timeStamp)$($object)" | Out-File -FilePath $global:OSDLogFile -Append
            }
            Write-Host "$($timestamp)$($object)"
        }
    }
}

function Register-SelfDestructingScheduledTask {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $taskName,
        [Parameter()]
        [string]
        $taskDescription,
        [Parameter()]
        [string]
        $scriptPath,
        [Parameter()]
        [string[]]
        $scriptArgumentList
    )

    $fullCommand = @"
# Create the folder if it doesn't exist.  But it should always already exist.
`$logDir = "`$(`$env:ProgramData)\Tanium\Provision\Logs"
if (-not (Test-Path `$logDir)) {
    MkDir `$logDir | Out-Null
    # Make sure the folder is secure
    icacls "`$(`$logDir)" /grant "*S-1-5-18:(OI)(CI)F" /grant "*S-1-5-32-544:(OI)(CI)F" /inheritance:r | Out-Null
}
`$logFile = "`$(`$logDir)\Provision-post-transcript.log"

Start-Transcript -Path `$logFile -Append
try {
    if ( Test-Path "$($scriptPath)" ) {
        Write-Host "Running: $($scriptPath) $($scriptArgumentList -join ' ')"
        & "$($scriptPath)" $($scriptArgumentList -join " ")
        Write-Host "$($scriptPath) exited code: `$(`$LASTEXITCODE)"
        Write-Host "Cleaning up $($scriptPath)"
        Remove-Item "$($scriptPath)" -Force
    } else {
        Write-Host "$($scriptPath) does not exist, cleaning up."
    }
    Write-Host "Removing scheduled task: $($TaskName)"
    `$task = Get-ScheduledTask -TaskName "$($taskName)"
    `$task | Unregister-ScheduledTask -Confirm:`$false
} catch {
    Write-Host `$_
} finally {
    Stop-Transcript
}
"@

    $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($fullCommand))
    $arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"


    $scheduledAction = New-ScheduledTaskAction -Execute 'Powershell.exe' -Argument $arguments
    $trigger =  New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DontStopOnIdleEnd
    $SID = [System.Security.Principal.SecurityIdentifier]"S-1-5-18"
    $Account = $SID.Translate([System.Security.Principal.NTAccount])
    Register-ScheduledTask -Action $scheduledAction -Trigger $trigger -TaskName $taskname -Description $taskdescription -Settings $settings -User $account.Value -RunLevel Highest
}

function Initialize-ProgDataFolder {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $Path,
        [Parameter(Mandatory=$false)]
        [String]
        $LogPath
    )

    # Create the Provision folder if it doesn't exist
    if (-not (Test-Path $Path)) {
        MkDir $Path | Out-Null
    }

    # Make sure the folder is secure.
    $ACL = Get-Acl -Path $Path

    # Disable inheritance
    $ACL.SetAccessRuleProtection($true, $false)

    # Remove all existing access rules (Since we just disabled inheritance, there should be no inherited rules, only explicit rules.)
    $ACL.Access | ForEach-Object {$ACL.RemoveAccessRule($_) | Out-Null}

    # Give SYSTEM full control
    $SYSTEM = ([System.Security.Principal.SecurityIdentifier]"S-1-5-18").Translate([System.Security.Principal.NTAccount])
    $SystemRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $SYSTEM,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        @([System.Security.AccessControl.InheritanceFlags]::ContainerInherit,[System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $ACL.AddAccessRule($SystemRule)

    # Give Administrators full control
    $AdminsRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        ([System.Security.Principal.SecurityIdentifier]"S-1-5-32-544").Translate([System.Security.Principal.NTAccount]),
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        @([System.Security.AccessControl.InheritanceFlags]::ContainerInherit,[System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $ACL.AddAccessRule($AdminsRule)

    # Set SYSTEM as the owner
    $ACL.SetOwner($SYSTEM)

    # Apply the ACL
    $ACL | Set-Acl -Path $Path

    if ($PSBoundParameters.Keys -contains "LogPath") {
    # Create the Logs folder if it doesn't exist
        if (-not (Test-Path $LogPath)) {
            MkDir $LogPath | Out-Null
        } else {
            # Make sure the folder is secure if it already existed.
            # Since we just set the parent folder's ACL properly, we just reset the logs folder to inherit from it and make sure the owner is correct.
            $ACL = Get-Acl -Path $LogPath
            # Remove any existing explicit access rules
            $ACL.Access | Where-Object { $_.IsInherited -eq $false } | ForEach-Object {$ACL.RemoveAccessRule($_) | Out-Null}
            # Enable inheritance
            $ACL.SetAccessRuleProtection($false, $true)
            # Set owner to SYSTEM
            $ACL.SetOwner($SYSTEM)
            # Apply the ACL
            $ACL | Set-Acl -Path $LogPath
        }
    }
}

function Get-WindowsCumulativeUpdate {
    try {
        $LCUVer = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name LCUVer | Select-Object -ExpandProperty LCUVer
        return [version]$LCUVer
    } catch {
        Write-OSDLog "Error looking up LCU version: $($_.Exception.Message)"
        return [version]$null
    }
}

Function Import-Ini ($file) {
    $ini = @{}

    $section = "NO_SECTION"

    switch -regex -file $file {
        "^\[(.+)\]$" {
            $section = $matches[1].Trim()
            $ini[$section] = @{}
        }
        "^\s*([^#].+?)\s*=\s*(.*)" {
            $name,$value = $matches[1..2]
            # skip comments that start with semicolon:
            if (!($name.StartsWith(";"))) {
                $ini[$section][$name] = $value.Trim()
            }
        }
    }
    $ini
}

# Initialization

if ( $global:OSDLogFile ) {
    Set-OSDLog -Path $global:OSDLogFile
}

$global:BUILD_VERSION = "10.9.71.0"
Write-OSDLog "Loading TaniumOSD Module version $($global:BUILD_VERSION)"
if (-not (Test-Path "$(Get-OSDRootFolder)\settings.json")) {
    Write-OSDLog "WARNING: Unable to locate settings.json file, settings will be unavailable"
    $global:OSDSettings = @{}
    $global:OSDManifest = @{}
}
else {
    $global:OSDSettings = Get-Content "$(Get-OSDRootFolder)\settings.json" | ConvertFrom-JSON
    if ($global:OSDSettings.manifest) {
        try
        {
            $global:OSDManifest = $global:OSDSettings.manifest | ConvertFrom-JSON
        }
        catch
        {
            $global:OSDSettingsFallback = Get-Content "$(Get-OSDRootFolder)\settings-fallback.json" | ConvertFrom-JSON
            if ($global:OSDSettingsFallback.manifest)
            {
                $global:OSDManifest = $global:OSDSettingsFallback.manifest | ConvertFrom-JSON
            }
        }
    }
}

# Power initialization
$code = @' 
[DllImport("kernel32.dll", CharSet = CharSet.Auto,SetLastError = true)]
public static extern void SetThreadExecutionState(uint esFlags);
'@

$script:ste = Add-Type -memberDefinition $code -name System -namespace Win32 -passThru 
$script:ES_CONTINUOUS = [uint32]"0x80000000" #Requests that the other EXECUTION_STATE flags set remain in effect until SetThreadExecutionState is called again with the ES_CONTINUOUS flag set and one of the other EXECUTION_STATE flags cleared.
$script:ES_AWAYMODE_REQUIRED = [uint32]"0x00000040" #Requests Away Mode to be enabled.
$script:ES_DISPLAY_REQUIRED = [uint32]"0x00000002" #Requests display availability (display idle timeout is prevented).
$script:ES_SYSTEM_REQUIRED = [uint32]"0x00000001" #Requests system availability (sleep idle timeout is prevented).

# Decide which executable to use
if ("$($env:PROCESSOR_ARCHITECTURE)" -eq "AMD64") {
    $script:exe = "TaniumOSDProgress_x64.exe"
}
elseif ("$($env:PROCESSOR_ARCHITECTURE)" -eq "X86") {
    $script:exe = "TaniumOSDProgress_x86.exe"
}
else {
    $script:exe = "TaniumOSDProgress_arm64.exe"
}

# Logic to trust all certs (ignore TLS errors)
try {
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
}
catch
{
    Write-OSDLog "Unable to set TrustAllCertsPolicy, probably because it is already set"
    Write-Verbose "$(Get-OSDTimeStamp) Error: $_"
}
# SIG # Begin signature block
# MIInKwYJKoZIhvcNAQcCoIInHDCCJxgCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQU5ZSyP25KVZeR6iZjBQ+cKI1w
# 9zaggiDNMIIFjTCCBHWgAwIBAgIQDpsYjvnQLefv21DiCEAYWjANBgkqhkiG9w0B
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
# CSqGSIb3DQEJBDEWBBQk/HIFUB6HqJHcMIVJEWzI8OaaHzANBgkqhkiG9w0BAQEF
# AASCAYBGW96kRhpxV7eF+A1GfTMKGpcNB3/2gJnKcQ/cX69nw97w2qizmdEP5YGY
# P+lD+eJLaT6uMgxVJnMG25BC2KlaikBElbzPwGmDPKxWY8kP4X7eiBsZM0Y9pePW
# WT9i/PIXJIsfuu6811lBJquxHLwrmctFJ4OqzDnHOvDmm1l5wBZ4u2f66AQt3GO0
# 8GlsfQpRm099o3LLRuB4ztcfDshznhXyTBRTPKyCsSUnixFaHuXk3OObq7dZ3jwk
# sFj4BKIjaLqj3fAmO3cPv4wgv15eUZk8xMFwKMH2RCbTXrRB0QWrFWErDx3QVwAP
# fc9fz3B3oLXgQcS0WnZGbPbPnk6vXolvHIdGFwIfHQmDRA6qbksXNtPTzvym+IJy
# xh+hxELAW1wi1j0omh6Jnrb0v7JgHEc+Am1i5lVFaRjY5uaKkgdsq9iPV51Z6meP
# KfhfHAFPVpK5jxN0lY2AwLdfqGyCX6VY8D5ol4Nm5CS8Nk9vk88iQ8A2YVfijKcl
# uW7AG3mhggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBpMQswCQYDVQQG
# EwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0
# IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0Ex
# AhAKgO8YS43xBYLRxHanlXRoMA0GCWCGSAFlAwQCAQUAoGkwGAYJKoZIhvcNAQkD
# MQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYwNjAxMTgwODMxWjAvBgkq
# hkiG9w0BCQQxIgQgBo0KdF6iuK2pzi/7v6qsQnHl6YLOfIX5417fcPrVjDUwDQYJ
# KoZIhvcNAQEBBQAEggIAAKUeNy3BkPEsLkmVOie0RKbs8kopsWKl9kCdnjygrL89
# 01i8IPREAkFIpyjiu9jBkgiaph7DzALSPuQDFsV1lzPyhrwWQyc6R8WOHOdhuaoZ
# 3EkAmGQHxBA4reg8D7VY3N6NXTltdY8M4uoa+Pk5gVkBLDFg3d5imDzLnedPgCMO
# fOUgKZKWjVHTvPHyCtXHFU6KFT0bXaoQCl19F4l0CE0z+I5ZgG+Z+XE/qi7GpZWd
# WCvJ1NmWWBw/sD6ZliM1544hzTJBliNlGEXt0YvYy2fM2EMEfl890ejzL9nrC8u5
# /mNElOmdpBR0ndCfxm4+L76kg90LajmKGvLm4Qkk6WspAN4Rv0LvZvs/X7+qBRHS
# NbzK7kRnM58Ku4VnpQlYspa2Ey+2M8D5lIUVvmZbt6lLvfuZaY3SqMrVkrxCcIqE
# rZCJW9Sj5eRhKZeEbZgGT+Drg7kHBGOqVtiyw1S2bbCApPWXrQgcc573pr4AiJLY
# VT74yUwyZQ+4S+TSfRb2qUxZU9miYaeZy/9x0yngv+UBOKWbTNF/Q+M5ua/ZQbLn
# 1OhJ8hC2xeNvHXhDXhMQoUUejvEIeAyFZF0PgiAJ8QeESsunj5/UbZ7DB5Xf5isa
# 4CrVFyR/9ISN+DMGw5TC1z7No8I0pz/p6dgR2rJBWagJ5feZ3mnw/jtCMe0S1tE=
# SIG # End signature block
