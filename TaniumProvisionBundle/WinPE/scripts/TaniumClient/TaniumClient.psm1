
#region Module Initialization
function Get-TS {
	return "[$((Get-Date).ToUniversalTime().ToString('u'))]"
}

"Loading TaniumClient Module version 10.9.71.0"

# Find the client (must already be installed)
if (Test-Path "HKLM:\Software\Wow6432Node\Tanium") {
    $regPath = "HKLM:\Software\Wow6432Node\Tanium"
}
else {
    $regPath = "HKLM:\Software\Tanium"
}
$clientDir = Get-ItemPropertyValue -Path "$regPath\Tanium Client" -Name "Path"

#endregion

function Get-TaniumSOAPSession {

    # Get the latest SOAP session
    $sessionToken = ""
    if (Test-Path "$clientDir\soap_session")
    {
        $sessionToken = Get-Content -Path "$clientDir\soap_session"
    }
    return $sessionToken
}

function Wait-TaniumClient {

    # Wait for the client to initialize (status key doesn't initially exist)
    $attempts = 0
    $global:apiPort = 0
    while ($attempts -lt 120)
    {
        if (Test-Path "$regPath\Tanium Client\Status")
        {
            $vals = Get-ItemProperty "$regPath\Tanium Client\Status"
            if ($vals.ClientAddress) {
                $portString = $vals.ClientAddress.Split(':')[1]
                $global:apiPort = ($portString -as [int]) + 1
                break
            }
            Write-Host "$(Get-TS) Waiting for ClientAddress"
            Start-Sleep -Seconds 5
            $attempts = $attempts + 1
        }
    }
    if ($global:apiPort -eq 0) {
        Write-Warning "$(Get-TS) WARNING: Unable to get Tanium ClientAddress"
    }

    # Wait for the soap_session to be created
    $attempts = 0
    $sessionToken = ""
    while ($attempts -lt 120)
    {    
        $sessionToken = Get-TaniumSOAPSession
        if ($sessionToken -ne "")
        {
            break
        }
        Write-Host "$(Get-TS) Waiting for soap_session"
        Start-Sleep -Seconds 5
        $attempts = $attempts + 1
    }
    if ($sessionToken -eq "") {
        Write-Warning "$(Get-TS) WARNING: Unable to get Tanium client soap_session"
    }
}

function Invoke-TaniumDownload {
<#
.SYNOPSIS
Downloads a file via the Tanium Client API.

.DESCRIPTION
This cmdlet downloads a file via the Tanium Client API, specified via a URL.  That URL must be whitelisted on the Tanium server for this to work.

.PARAMETER Url
The full URL for the file to be downloaded.
 
.PARAMETER Destination
The full path that should be used for the destination file, including the name of the file.  If this specifies only the file name, the current directory will be assumed.
 
.PARAMETER Timeout
The maximum amount of time, in minutes, for the download to complete before an error is thrown.

.EXAMPLE
Invoke-TaniumDownload -Url $url -Destination "C:\Test.txt"
 
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string] $Url,
        [Parameter(Mandatory=$true)] [string] $Destination,
        [Parameter(Mandatory=$false)] [int] $Timeout = 10,
        [Parameter(Mandatory=$false)] [switch] $Async = $false
    )    

    Process {
        # Get the file name from the destination
        $fileName = Split-Path -Leaf $Destination

        # Clean up from any previous attempts, but only if it isn't still an 'active download'.
        # Otherwise, if the client is still tracking the download, lets not forcibly restart it.
        $status = Get-TaniumDownloadStatus -Url $Url -Destination $Destination
        if ( $status.Status -eq "NotFound" ) {
            if (Test-Path "$clientDir\Downloads\$fileName") {
                Write-Host "$(Get-TS) Removing old $clientDir\Downloads\$fileName"
                Remove-Item "$clientDir\Downloads\$fileName" -Force
            }
        }
        if (Test-Path $Destination) {
            Write-Host "$(Get-TS) Removing old $Destination"
            Remove-Item $Destination -Force
        }

        # Build the SOAP request
        $sessionToken = Get-TaniumSOAPSession
        $soap = @'
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:TaniumSOAP">
<soapenv:Header/>
<soapenv:Body>
<urn:tanium_soap_request>
<session>{0}</session>
<command>AddObject</command>
<object_list>
<download>
<name>{1}</name>
<url>{2}</url>
</download>
</object_list>
</urn:tanium_soap_request>
</soapenv:Body>
</soapenv:Envelope>
'@ -f $sessionToken, $fileName, $Url

        # Make the request
        $namespaces = @{soap="http://schemas.xmlsoap.org/soap/envelope/"; t="urn:TaniumSOAP"}

        $r = Invoke-WebRequest -Method POST -Uri "http://localhost:$($global:apiPort)/soap" -Body $soap -UseBasicParsing
        $soapResponse = [xml]$r.Content
        $status = (Select-Xml $soapResponse -XPath "//soap:Envelope/soap:Body/t:return/result_object/download/status" -Namespace $namespaces).Node.InnerText
        Write-Host "$(Get-TS) Status: $status"

        # If async, bail out now
        if ($Async) {
            return
        }

        # Poll until done
        for ($i = 1; $i -le ($timeout * 20); $i++) {
            try {
                $sessionToken = Get-TaniumSOAPSession
                $soap = @'
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:TaniumSOAP">
<soapenv:Header/>
<soapenv:Body>
<urn:tanium_soap_request>
<session>{0}</session>
<command>GetObject</command>
<object_list>
<download>
<name>{1}</name>
<url>{2}</url>
</download>
</object_list>
</urn:tanium_soap_request>
</soapenv:Body>
</soapenv:Envelope>
'@ -f $sessionToken, $fileName, $Url
                $r = Invoke-WebRequest -Method POST -Uri "http://localhost:$($global:apiPort)/soap" -Body $soap -UseBasicParsing
                $soapResponse = [xml]$r.Content
                $status = (Select-Xml $soapResponse -XPath "//soap:Envelope/soap:Body/t:return/result_object/download/status" -Namespace $namespaces).Node.InnerText
                Write-Host "$(Get-TS) Status: $status"
                if ($status -eq "Completed") {
                    break
                } elseif ($null -eq $status) {
                    Write-Host "$(Get-TS) Unexpected null status.  SOAP response:"
                    Write-Host $r.Content
                    # If we can find the expected file, the download was actually successful, so let's continue.
                    if (Test-Path "$clientDir\Downloads\$fileName") {
                        $status = "Completed"
                        break
                    }
                }
            }
            catch {
                Write-Host "$(Get-TS) Unhandled error: $_"
            }
            Start-Sleep -Seconds 5
        }

        # Move the file to the script folder
        if ($status -eq "Completed") {
            $source = "$clientDir\Downloads\$fileName"
            while (Test-Path $source) {
                try {
                    Complete-TaniumDownload -Url $Url -Destination $Destination -source $source
                    break
                }
                catch {
                    Write-Host "$(Get-TS) Failed to move file: $_"
                    Start-Sleep -Seconds 2
                }
            }
        }
        else {
            throw "Download timed out"
        }
    }
}

function Stop-TaniumDownload {
<#
.SYNOPSIS
Stops the downloading of a file already requested via the Tanium Client API.

.DESCRIPTION
This cmdlet stops the downloading of a file requested via the Tanium Client API, specified via a URL.

.PARAMETER Url
The full URL for the file to be downloaded.
 
.PARAMETER Destination
The full path that was specified for the destination file, including the name of the file. (Only the file name is used.)
 
.EXAMPLE
Stop-TaniumDownload -Url $url -Destination "C:\Test.txt"
 
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string] $Url,
        [Parameter(Mandatory=$true)] [string] $Destination
    )    

    Process {
        # Get the file name from the destination
        $fileName = Split-Path -Leaf $Destination

        # Build the SOAP request
        $sessionToken = Get-TaniumSOAPSession
        $soap = @'
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:TaniumSOAP">
<soapenv:Header/>
<soapenv:Body>
<urn:tanium_soap_request>
<session>{0}</session>
<command>DeleteObject</command>
<object_list>
<download>
<name>{1}</name>
<url>{2}</url>
</download>
</object_list>
</urn:tanium_soap_request>
</soapenv:Body>
</soapenv:Envelope>
'@ -f $sessionToken, $fileName, $Url
Write-Host $soap

        # Make the request
        $namespaces = @{soap="http://schemas.xmlsoap.org/soap/envelope/"; t="urn:TaniumSOAP"}

        $r = Invoke-WebRequest -Method POST -Uri "http://localhost:$($global:apiPort)/soap" -Body $soap -UseBasicParsing
        $soapResponse = [xml]$r.Content
        $status = (Select-Xml $soapResponse -XPath "//soap:Envelope/soap:Body/t:return/result_object/download/status" -Namespace $namespaces).Node.InnerText
        Write-Host "$(Get-TS) Status: $status"
    }

}

function Get-TaniumDownloadStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)] [string] $Url = "",
        [Parameter(Mandatory=$false)] [string] $Destination = ""
    )

    try {
        $sessionToken = Get-TaniumSOAPSession
        if ($Destination -eq "") {
            $fileName = ""
        } else {
                $fileName = Split-Path -Leaf $Destination
        }
        $soap = @'
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:TaniumSOAP">
<soapenv:Header/>
<soapenv:Body>
<urn:tanium_soap_request>
<session>{0}</session>
<command>GetObject</command>
<object_list>
<download>
<name>{1}</name>
<url>{2}</url>
</download>
</object_list>
</urn:tanium_soap_request>
</soapenv:Body>
</soapenv:Envelope>
'@ -f $sessionToken, $fileName, $Url

        # Make the request
        $namespaces = @{soap="http://schemas.xmlsoap.org/soap/envelope/"; t="urn:TaniumSOAP"}
        $r = Invoke-WebRequest -Method POST -Uri "http://localhost:$($global:apiPort)/soap" -Body $soap -UseBasicParsing
        $soapResponse = [xml]$r.Content
        $status = (Select-Xml $soapResponse -XPath "//soap:Envelope/soap:Body/t:return/result_object/download/status" -Namespace $namespaces).Node.InnerText

        # If requesting all files, just return the response
        if ($Destination -eq "") {
            return $soapResponse.Envelope.Body.return.result_object.download
        }

        # Move the file to the specified location when complete
        Write-Host "$(Get-TS) Status: $status"
        if ($status -eq "Completed") {
            $source = "$clientDir\Downloads\$fileName"
            while (Test-Path $source) {
                try {
                    Complete-TaniumDownload -Url $Url -Destination $Destination -source $source
                    break
                }
                catch {
                    Write-Host "$(Get-TS) Failed to move/link file: $_"
                    Start-Sleep -Seconds 2
                }
            }
        } elseif ($null -eq $status) {
            Write-Host "$(Get-TS) Unexpected null status.  SOAP response:"
            Write-Host $r.Content
            # If we can find the expected file, the download was actually successful, so let's continue.
            if (Test-Path "$clientDir\Downloads\$fileName") {
                $status = "Completed"
            }
        }
    }
    catch {
        Write-Host "$(Get-TS) Unhandled error: $_"
    }
    if ($status -like "Downloading(*") {
        [int]$percent = $status.Substring(12).Replace("%)", "")
        $response = New-Object PSObject -Property @{
            Status = "Downloading"
            Percent = $percent
        }
    } else {
        if ($status -eq "Completed") {
            $percent = 100
        } else {
            $percent = 0
        }
        $response = New-Object PSObject -Property @{
            Status = $status
            Percent = $percent
        }
    }
    return $response
}

function Add-TaniumTag {
    <#
    .SYNOPSIS
    Adds the specified tag to the Windows registry.
    
    .DESCRIPTION
    This cmdlet adds the specified tag to the Tanium client registry.
    
    .PARAMETER Tag
    The tag to be added
         
    .EXAMPLE
    Add-TaniumTag -Tag $tag
     
    #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory=$true)] [string] $Tag
        )    
    
        Process {
            $tagPath = "$regPath\Tanium Client\Sensor Data\Tags"
            if (-not (Test-Path $tagPath)) {
                New-Item -Path $tagPath -Force | Out-Null
            }
            Set-ItemProperty -Path $tagPath -Name $Tag -Value $null 
        }
    }

function Get-TaniumToolInfo {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)] [string] $Name = ""
    )    

    Process {
        if ($Name -eq "") {
            Get-ChildItem -Path "$clientDir\Tools" -Directory | ForEach-Object {
                Write-Output (Get-TaniumToolInfo -Name $_.Name)
            }
        }
        else {
            if (Test-Path "$clientDir\Tools\$($Name)\version") {
                $version = Get-Content "$clientDir\Tools\$($Name)\version"
                $toolInfo = New-Object PSObject -Property @{
                    Tool = $Name
                    Version = $version
                }
                Write-Output $toolInfo
            }
        }
    }
}

function Get-TaniumRegistryPath {
    [CmdletBinding()]
    param(
    )    

    Process {
        return $regPath
    }
}

function Get-TaniumClientPath {
    [CmdletBinding()]
    param(
    )    

    Process {
        return $clientDir
    }
}

function Get-TaniumMailboxResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)] [string] $Command = "config.get-items",
        [Parameter(Mandatory=$false)] [int] $CommandVersion = 1,
        [Parameter(Mandatory=$false)] [int] $FormatVersion = 1,
        [Parameter(Mandatory=$false)] [string] $Payload = "",
        [Parameter(Mandatory=$false)] [string] $Domain = "",
        [Parameter(Mandatory=$false)] [string] $DataCategory = "",
        [Parameter(Mandatory=$false)] [switch] $SkipFailedItems = $false,
        [Parameter(Mandatory=$false)] [switch] $Raw = $false
    )    

    Process {

        # Define the mailbox request        
        if ($Payload -ne "") {
            $mailboxRequest = @"
{
    "command": "$Command",
    "format_version": $FormatVersion,
    "command_version": $CommandVersion,
    "payload": $Payload
}
"@
        } else {
            $mailboxRequest = @"
{
    "command": "$Command",
    "format_version": $FormatVersion,
    "command_version": $CommandVersion,
    "payload": {
        "skip_failed_items": $($SkipFailedItems.ToString().ToLower()),
        "filters": [{
            "domain": "$Domain",
            "data_category": "$DataCategory"
        }]
    }
}
"@
        }

        # Get paths
        $tc = Get-TaniumClientPath
        $mailboxTmp = "$tc\extensions\core\tmp"
        $mailboxInbox = "$tc\extensions\core\mailbox\inbox"
        $mailboxOutbox = "$tc\extensions\core\mailbox\outbox"

        # Write it to the tmp folder
        $file = [System.IO.Path]::GetRandomFileName()
        $mailboxRequest | Out-File "$mailboxTmp\$file" -Encoding ascii

        # Move it to the inbox
        Write-Verbose "Submitting request to $mailboxInbox\${$file}: $mailboxRequest"
        Move-Item -Path "$mailboxTmp\$file" -Destination "$mailboxInbox\$file" -Force

        # Get the outbox result
        $tries = 0
        $content = ""
        do {
            Start-Sleep -Milliseconds 500
            try {
                if (Test-Path "$mailboxOutbox\$file") {
                    $content = Get-Content "$mailboxOutbox\$file"
                    break
                }
            } catch {
                Write-Verbose "Error reading outbox, will retry: $_"
                $tries++
            }        
        } while ($tries -lt 120)

        if ($content -eq "") {
            throw "ERROR (local): No content received."
        } elseif ($content -like "ERROR*") {
            throw $content
        } elseif ($Raw) {
            $content
        } else {
            $content | ConvertFrom-Json
        }
    }
}

function Complete-TaniumDownload {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Url,
        [Parameter()]
        [string]
        $Destination,
        [Parameter()]
        [string]
        $source
    )

    # Initial attempt: hard-link the file to the destination so it stays live in the TC\Downloads folder
    try {
        New-Item -ItemType HardLink -Path $Destination -Value $source -ErrorAction Stop
        Write-Host "$(Get-TS) Linked file to $Destination"
    } catch {
        # If hard-linking fails, move the file to the TC\Downloads folder and cancel the Tanium Client API download request,
        # since it will be broken after the file is moved.
        Move-Item -Path $source -Destination $Destination -Force
        Write-Host "$(Get-TS) Moved file to $Destination, stopping download tracking."
        try {
            Stop-TaniumDownload -Url $Url -Destination $Destination
        } catch {
            # But don't make a failure to stop the download a fatal error, let the parent process continue.
            Write-Host "$(Get-TS) could not stop download request: $($_)"
        }
    }
}

function Stop-TaniumClient {
    try {
        Stop-Service -Name "Tanium Client" -ErrorAction Stop
    } catch {
        Write-Host "$(Get-TS) could not stop Tanium Client service: $($_)"
    }
}
# SIG # Begin signature block
# MIInKwYJKoZIhvcNAQcCoIInHDCCJxgCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQU7hudX7EA267IUd6csNrKOPOq
# p/KggiDNMIIFjTCCBHWgAwIBAgIQDpsYjvnQLefv21DiCEAYWjANBgkqhkiG9w0B
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
# CSqGSIb3DQEJBDEWBBTkNKYoRSETZo0AGsZGvIku5b+zvzANBgkqhkiG9w0BAQEF
# AASCAYAyVC0QN1IF/PycovIUkmTWGyehg33mD25hYIvfGJVIloKX1Fok6HFiJ66Q
# IL2MtJn9eFdAeQobqPRH2ccn5TWVXYHRJdLHK8yD9fsQ/Fx7UET6970ii5G6IGmk
# 3gycZXVp8jkvqA3mjuE4mWJzIRIj9hZoOWht3o2emWylvK2bHBB2v37s98MipqMg
# oPITWsz6pwnC3daZ64EjIRWvg5+KeP9F8Q2WLwl5ja38fJLE8UcpImZxHvf2uoLY
# JEdext/wPN2/c9nNksoZ7GNeKByQa0cg6F8+vT2YJ1TkqeljDYVP4CeQHioW5NPn
# acxLUTLshrjq4de+h5Jw8M72VzNE5mlwHDQBrUheFXYZAt5cmvUaQjMf+U+W/Vss
# N1vFRft/UBaxJwqrvMbXOJ/YEuU4tJmnAI/9t130EKkmJ5NZnTOk0zMLO9f6+qKQ
# zJ1rG2D2hrWgYRhWR4HuF7AY6MGlUV1zKdzAK7e7w6ysFJVxOxrWyMRlM5lYdFsu
# bAfeXGahggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBpMQswCQYDVQQG
# EwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0
# IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0Ex
# AhAKgO8YS43xBYLRxHanlXRoMA0GCWCGSAFlAwQCAQUAoGkwGAYJKoZIhvcNAQkD
# MQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYwNjAxMTgwODQyWjAvBgkq
# hkiG9w0BCQQxIgQg6NouiNen0EqsQyufyqaqIkca5rKs13Td0bc2inRkWWAwDQYJ
# KoZIhvcNAQEBBQAEggIAOGopL0h59fv55f6oVd/QapmJrZnNCURZfWkCUOQwU7Ea
# dyLoePnCc6udmjR0yJi+gLL8b2DpeDIIjt48fapEJrriUpIMgNctrQ/P6U7R6CML
# ebdWIqLm9EDpLFg4N9tVceSI+i0ftiAeB3J7VfeJSSY8wSXHA7BAlYYa0rgXNtOX
# X5zLeCmu5A3XNYHssV3T/a7PXo8NjWvP4Sc6CxUXD7AWEkFS+HGRd1DdoztRwIz1
# pnUdUQEs++ALxf+H2v2y83R4vIlAihd4srANz/9rV2JWOoP5paG9Xj3AZQgyHBCK
# 7YV5+0oqpcNeGJ/B4cHSoO1uTXURsKQmm/MUPPrnvU/tMi7eofHRHu/mO49PLp9c
# JJuiUe9o4TK4O1eMrNVCdH7RMFRZcEsnUSnT30pZ+qlWk88ypV1h8z05hLtDAs8n
# QuE99ZYqZYwjJ5qasaFW3OibxSecQ0GMQQDVxbMlAs29k5iLwlyq+3cvXArxjB6X
# RAYxKOvBy8bsIM0tMyNsbj/gyi5ZFjvI8Mem2kVhDmSQFX+BTxdrCrdlZRAqdle7
# ZgXmWCQNnLPXOeGV9h21TzSJ3J/WuRLfr2ggPoteeM+gDi0eSDc1BJNuYYhbXdM/
# V4sUQ586pfzwapavNY+9wqRylPRn1gqf/qqvghPF5kaljBDCnSyz7Q1kEsnU5zI=
# SIG # End signature block
