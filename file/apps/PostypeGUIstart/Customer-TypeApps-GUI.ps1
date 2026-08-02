#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$WsBase = '',
    [string]$Country = '',
    [Alias('ConfigJsonPath')]
    [string]$IniPath = '',
    [string]$WorkingRoot = 'C:\provision\Apps',
    [switch]$AllowInsecureTls
)

$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Convert-ToPsSingleQuotedLiteral {
    param([string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

if (-not (Test-IsAdministrator)) {
    $scriptPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        throw 'Cannot self-elevate: script path is empty.'
    }

    $argLine = "-NoProfile -ExecutionPolicy Bypass -File {0}" -f (Convert-ToPsSingleQuotedLiteral -Value $scriptPath)
    if (-not [string]::IsNullOrWhiteSpace($WsBase)) {
        $argLine += " -WsBase {0}" -f (Convert-ToPsSingleQuotedLiteral -Value $WsBase)
    }
    if (-not [string]::IsNullOrWhiteSpace($Country)) {
        $argLine += " -Country {0}" -f (Convert-ToPsSingleQuotedLiteral -Value $Country)
    }
    if (-not [string]::IsNullOrWhiteSpace($IniPath)) {
        $argLine += " -IniPath {0}" -f (Convert-ToPsSingleQuotedLiteral -Value $IniPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkingRoot)) {
        $argLine += " -WorkingRoot {0}" -f (Convert-ToPsSingleQuotedLiteral -Value $WorkingRoot)
    }
    if ($AllowInsecureTls.IsPresent) {
        $argLine += ' -AllowInsecureTls'
    }

    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine -WindowStyle Normal | Out-Null
        exit 0
    }
    catch {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [void][System.Windows.Forms.MessageBox]::Show(
            'Administrator rights are required to run this tool.',
            'Customer Type Apps GUI',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        exit 1223
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[void][System.Windows.Forms.Application]::EnableVisualStyles()

function Resolve-IniPath {
    param(
        [string]$ExplicitPath,
        [string]$ScriptPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        return $ExplicitPath
    }

    $baseDir = ''
    if (-not [string]::IsNullOrWhiteSpace($ScriptPath)) {
        try { $baseDir = Split-Path -Path $ScriptPath -Parent } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($baseDir)) {
        $baseDir = (Get-Location).Path
    }

    return (Join-Path $baseDir 'Customer-TypeApps-GUI.ini')
}

function Get-WsBasesFromIni {
    param([Parameter(Mandatory)][string]$IniFilePath)

    if (-not (Test-Path -LiteralPath $IniFilePath)) {
        throw "INI not found: $IniFilePath"
    }

    $result = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($rawLine in (Get-Content -LiteralPath $IniFilePath -ErrorAction Stop)) {
        $line = ([string]$rawLine).Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith('#') -or $line.StartsWith(';')) { continue }
        if ($line -match '^\[.+\]$') { continue }

        $candidate = $line
        if ($line -match '^[^=]+=(.+)$') {
            $candidate = ([string]$matches[1]).Trim()
        }

        $candidate = $candidate.Trim('"').Trim("'").Trim()
        if (-not ($candidate -match '^https?://')) { continue }

        $normalized = $candidate.TrimEnd('/')
        if ($seen.Add($normalized)) {
            [void]$result.Add($normalized)
        }
    }

    return @($result)
}

function Resolve-WsBase {
    param(
        [string]$Preferred,
        [string[]]$WsList
    )
    if (-not [string]::IsNullOrWhiteSpace($Preferred)) {
        return $Preferred.TrimEnd('/')
    }

    if ($WsList -and $WsList.Count -gt 0) {
        return ([string]$WsList[0]).TrimEnd('/')
    }

    throw 'No WS configured. Add at least one http(s) URL in Customer-TypeApps-GUI.ini or pass -WsBase.'
}

function Normalize-WsBase {
    param([string]$Raw)
    $v = ([string]$Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($v)) {
        throw 'WS base is empty.'
    }
    return $v.TrimEnd('/')
}

function Expand-BaseUrl {
    param(
        [string]$Url,
        [string]$Base
    )
    if ([string]::IsNullOrWhiteSpace($Url)) { return $Url }
    if ($Url.StartsWith('[baseurl]', [System.StringComparison]::OrdinalIgnoreCase)) {
        return ($Url -replace '^\[baseurl\]', $Base.TrimEnd('/'))
    }
    if (Test-HttpUrl -Value $Url) {
        return $Url
    }
    return (Expand-SystemEnvironmentVariables -Value $Url)
}

function Test-HttpUrl {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    try {
        $uri = [uri]$Value
        return ($uri.IsAbsoluteUri -and $uri.Scheme -in @('http', 'https'))
    }
    catch {
        return $false
    }
}

function Test-UncPath {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return $Value.Trim().StartsWith('\\')
}

function Expand-SystemEnvironmentVariables {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }

    return [regex]::Replace($Value, '%([^%]+)%', {
        param($Match)

        $name = $Match.Groups[1].Value
        if ([string]::IsNullOrWhiteSpace($name)) { return $Match.Value }

        $machineValue = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Machine)
        if (-not [string]::IsNullOrWhiteSpace($machineValue)) { return $machineValue }

        $processValue = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if (-not [string]::IsNullOrWhiteSpace($processValue)) { return $processValue }

        return $Match.Value
    })
}

function Invoke-RobocopyChecked {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    $robocopy = Get-Command 'robocopy.exe' -ErrorAction SilentlyContinue
    if (-not $robocopy) {
        throw 'robocopy.exe not found'
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $logDir = 'C:\SysTools\Logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $safeLogName = ((Split-Path -Leaf $Destination) -replace '[^\w\.-]', '_')
    if ([string]::IsNullOrWhiteSpace($safeLogName)) { $safeLogName = 'PostypeGUIstart-Robocopy' }
    $logFile = Join-Path $logDir ("PostypeGUIstart-Robocopy-{0}-{1}.log" -f $safeLogName, (Get-Date -Format 'yyyyMMdd-HHmmss'))

    Write-UiLog ("Robocopy log: {0}" -f $logFile)
    Write-UiLog ("Robocopy source: {0}" -f $Source)
    Write-UiLog ("Robocopy destination: {0}" -f $Destination)

    & $robocopy.Source $Source $Destination /E /R:3 /W:10 /TEE "/LOG:$logFile"
    $exitCode = [int]$LASTEXITCODE
    Write-UiLog ("Robocopy exit code: {0}" -f $exitCode)
    if ($exitCode -ge 8) {
        throw ("robocopy failed ExitCode={0}: {1} -> {2}; log={3}" -f $exitCode, $Source, $Destination, $logFile)
    }
}

function Copy-UncFolder {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "UNC source folder not found: $Source"
    }

    Invoke-RobocopyChecked -Source $Source -Destination $Destination
}

function Invoke-JsonGet {
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSec = 30,
        [int]$Attempts = 3,
        [switch]$InsecureTls
    )

    $lastErr = $null
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            $prevCb = [Net.ServicePointManager]::ServerCertificateValidationCallback
            if ($InsecureTls) {
                [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            }
            try {
                return Invoke-RestMethod -Uri $Url -Method GET -TimeoutSec $TimeoutSec
            }
            finally {
                if ($InsecureTls) {
                    [Net.ServicePointManager]::ServerCertificateValidationCallback = $prevCb
                }
            }
        }
        catch {
            $lastErr = $_
            if ($i -lt $Attempts) {
                Start-Sleep -Seconds 1
            }
        }
    }
    throw $lastErr
}

function Download-WithCurl {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$InsecureTls,
        [switch]$AllowEmptyFile
    )

    $curl = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
    if (-not $curl) {
        throw 'curl.exe not found'
    }

    $destDir = Split-Path -Path $Destination -Parent
    if ($destDir) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    $downloadUrl = Convert-UrlForHttp -Url $Url
    $args = @(
        '-fSL',
        '-sS',
        '--retry', '3',
        '--connect-timeout', '60',
        '--max-time', '600',
        '-o', $Destination,
        $downloadUrl
    )
    if ($InsecureTls) { $args = @('-k') + $args }

    $prevEap = $ErrorActionPreference
    $hadNativePreference = Test-Path Variable:\PSNativeCommandUseErrorActionPreference
    if ($hadNativePreference) { $prevNativePreference = $PSNativeCommandUseErrorActionPreference }
    try {
        # curl writes progress/errors to stderr. Keep native stderr from becoming a
        # PowerShell exception; success is decided from curl's exit code and file state.
        $ErrorActionPreference = 'Continue'
        if ($hadNativePreference) { $PSNativeCommandUseErrorActionPreference = $false }
        $curlOutput = & $curl.Source @args 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEap
        if ($hadNativePreference) { $PSNativeCommandUseErrorActionPreference = $prevNativePreference }
    }
    if ($exitCode -ne 0) {
        $curlDetails = ''
        if ($curlOutput) {
            $lines = @($curlOutput) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }
            if ($lines.Count -gt 0) { $curlDetails = ": $($lines -join ' | ')" }
        }
        throw "curl failed (exit=$exitCode)$curlDetails"
    }
    if (-not (Test-Path -LiteralPath $Destination)) {
        throw "downloaded file missing: $Destination"
    }
    if (-not $AllowEmptyFile -and (Get-Item -LiteralPath $Destination).Length -le 0) {
        throw "downloaded file is empty: $Destination"
    }
}

function Convert-HtmlAttributeValue {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlDecode($Value)
}

function Convert-UrlForHttp {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $Url }

    try {
        $u = [uri]$Url
        if (-not ($u.Scheme -in @('http','https'))) { return $Url }
        if ($u.AbsolutePath -notmatch '\+') { return $Url }

        $b = [System.UriBuilder]::new($u)
        $b.Path = ($u.AbsolutePath -replace '\+', '%2B')
        return $b.Uri.AbsoluteUri
    }
    catch {
        return ($Url -replace '\+', '%2B')
    }
}

function Resolve-RemoteUrl {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Href
    )
    $base = [uri]$BaseUrl
    return (Convert-UrlForHttp -Url ([uri]::new($base, $Href)).AbsoluteUri)
}

function Convert-FileBrowserUrlToRawUrl {
    param([Parameter(Mandatory)][string]$Url)
    $u = [uri]$Url
    if ($u.AbsolutePath -match '^/file/raw/') { return (Convert-UrlForHttp -Url $u.AbsoluteUri) }
    if ($u.AbsolutePath -notmatch '^/file/') { return (Convert-UrlForHttp -Url $u.AbsoluteUri) }

    $rawPath = $u.AbsolutePath -replace '^/file/', '/file/raw/'
    $b = [System.UriBuilder]::new($u)
    $b.Path = $rawPath
    $b.Query = ''
    return (Convert-UrlForHttp -Url $b.Uri.AbsoluteUri)
}

function Invoke-WebRequestContent {
    param(
        [Parameter(Mandatory)][string]$Url,
        [switch]$InsecureTls
    )

    $prevCb = [Net.ServicePointManager]::ServerCertificateValidationCallback
    if ($InsecureTls) {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }
    try {
        return (Invoke-WebRequest -Uri (Convert-UrlForHttp -Url $Url) -UseBasicParsing -TimeoutSec 60).Content
    }
    finally {
        if ($InsecureTls) {
            [Net.ServicePointManager]::ServerCertificateValidationCallback = $prevCb
        }
    }
}

function Get-RemoteFileBrowserEntries {
    param(
        [Parameter(Mandatory)][string]$Url,
        [switch]$InsecureTls
    )

    $html = Invoke-WebRequestContent -Url $Url -InsecureTls:$InsecureTls
    $entries = @()
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $rowMatches = [regex]::Matches($html, '<tr\b(?<attrs>[^>]*)\bdata-entry-href="(?<href>[^"]+)"[^>]*>(?<body>.*?)</tr>', 'IgnoreCase,Singleline')
    foreach ($m in $rowMatches) {
        $href = Convert-HtmlAttributeValue $m.Groups['href'].Value
        if ([string]::IsNullOrWhiteSpace($href)) { continue }

        $body = $m.Groups['body'].Value
        $isDir = ($body -match 'folder-link')
        $isFile = ($body -match 'file-name')

        $absUrl = Resolve-RemoteUrl -BaseUrl $Url -Href $href
        $leaf = [uri]::UnescapeDataString([System.IO.Path]::GetFileName(([uri]$absUrl).AbsolutePath))
        if ([string]::IsNullOrWhiteSpace($leaf)) { continue }
        if ($leaf -ieq '@eaDir') { continue }
        if (-not ($isDir -or $isFile)) {
            $isFile = ($leaf -match '\.[^./\\]+$')
            $isDir = -not $isFile
        }
        if (-not $seen.Add($absUrl)) { continue }

        $entries += [pscustomobject]@{
            Name  = $leaf
            Url   = $absUrl
            IsDir = [bool]$isDir
        }
    }
    return @($entries)
}

function Download-PackageFolderRecursive {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$InsecureTls,
        [switch]$AllowEmpty
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $entries = Get-RemoteFileBrowserEntries -Url $Url -InsecureTls:$InsecureTls
    if ($entries.Count -le 0) {
        if ($AllowEmpty) { return }
        throw "Package folder has no downloadable entries: $Url"
    }

    foreach ($entry in $entries) {
        $target = Join-Path $Destination $entry.Name
        if ($entry.IsDir) {
            Download-PackageFolderRecursive -Url $entry.Url -Destination $target -InsecureTls:$InsecureTls -AllowEmpty
        }
        else {
            $rawUrl = Convert-FileBrowserUrlToRawUrl -Url $entry.Url
            Download-WithCurl -Url $rawUrl -Destination $target -InsecureTls:$InsecureTls -AllowEmptyFile
        }
    }
}

function Get-InstallerExtensionFromUrl {
    param([Parameter(Mandatory)][string]$Url)
    $uri = [uri]$Url
    $ext = [System.IO.Path]::GetExtension($uri.AbsolutePath)
    if ([string]::IsNullOrWhiteSpace($ext)) { return '.ps1' }
    return $ext.ToLowerInvariant()
}

function Invoke-Installer {
    param(
        [Parameter(Mandatory)][string]$Extension,
        [Parameter(Mandatory)][string]$LocalFile,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    switch ($Extension) {
        '.ps1' {
            $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $LocalFile))
            return (Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WorkingDirectory $WorkingDirectory -WindowStyle Normal -Wait -PassThru).ExitCode
        }
        '.cmd' {
            $args = @('/c',('"{0}"' -f $LocalFile))
            return (Start-Process -FilePath 'cmd.exe' -ArgumentList $args -WorkingDirectory $WorkingDirectory -WindowStyle Normal -Wait -PassThru).ExitCode
        }
        '.bat' {
            $args = @('/c',('"{0}"' -f $LocalFile))
            return (Start-Process -FilePath 'cmd.exe' -ArgumentList $args -WorkingDirectory $WorkingDirectory -WindowStyle Normal -Wait -PassThru).ExitCode
        }
        '.msi' {
            $args = @('/i',('"{0}"' -f $LocalFile),'/qn','REBOOT=ReallySuppress')
            return (Start-Process -FilePath 'msiexec.exe' -ArgumentList $args -WorkingDirectory $WorkingDirectory -WindowStyle Normal -Wait -PassThru).ExitCode
        }
        '.exe' {
            $args = @('/S')
            return (Start-Process -FilePath $LocalFile -ArgumentList $args -WorkingDirectory $WorkingDirectory -WindowStyle Normal -Wait -PassThru).ExitCode
        }
        default {
            $args = @('/S')
            return (Start-Process -FilePath $LocalFile -ArgumentList $args -WorkingDirectory $WorkingDirectory -WindowStyle Normal -Wait -PassThru).ExitCode
        }
    }
}

function Get-TypeList {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [switch]$InsecureTls
    )

    function Normalize-TypeList {
        param([string[]]$InputTypes)
        $ordered = New-Object System.Collections.Generic.List[string]
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($t in @($InputTypes | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })) {
            if ($seen.Add($t)) { [void]$ordered.Add($t) }
        }

        return @($ordered)
    }

    # Preferred endpoint (if present)
    try {
        $resp = Invoke-JsonGet -Url ("{0}/gettypes" -f $BaseUrl) -InsecureTls:$InsecureTls
        if ($resp -and $resp.types) {
            $vals = @()
            foreach ($t in $resp.types) {
                if ($t -is [string]) { $vals += $t }
                elseif ($t.PSObject.Properties.Match('value').Count -gt 0) { $vals += [string]$t.value }
                elseif ($t.PSObject.Properties.Match('type').Count -gt 0) { $vals += [string]$t.type }
            }
            $vals = $vals | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique
            if ($vals.Count -gt 0) { return (Normalize-TypeList -InputTypes $vals) }
        }
    }
    catch {}

    # Fallback endpoint available today
    $fallback = Invoke-JsonGet -Url ("{0}/list_used?lower=0" -f $BaseUrl) -InsecureTls:$InsecureTls
    $types = @()
    if ($fallback -and $fallback.types) {
        foreach ($x in $fallback.types) {
            if ($x -is [string]) { $types += $x }
            elseif ($x.PSObject.Properties.Match('value').Count -gt 0) { $types += [string]$x.value }
        }
    }
    $types = $types | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique
    return (Normalize-TypeList -InputTypes $types)
}

function Get-AppsForType {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$TypeName,
        [string]$CountryCode,
        [switch]$InsecureTls
    )

    $u = "{0}/getapps?type={1}" -f $BaseUrl, [uri]::EscapeDataString($TypeName)
    if (-not [string]::IsNullOrWhiteSpace($CountryCode)) {
        $u += "&country={0}" -f [uri]::EscapeDataString($CountryCode.Trim().ToUpperInvariant())
    }
    $model = ''
    try {
        $model = ([string](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Model).Trim()
    }
    catch {
        try { $model = ([string](Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop).Model).Trim() } catch {}
    }
    if (-not [string]::IsNullOrWhiteSpace($model)) {
        $u += "&model={0}" -f [uri]::EscapeDataString($model)
    }
    $resp = Invoke-JsonGet -Url $u -InsecureTls:$InsecureTls
    if ($null -eq $resp -or $null -eq $resp.applications) { return @() }
    return @($resp.applications)
}

$startupWsError = $null
$resolvedWsBase = ''
$resolvedIniPath = Resolve-IniPath -ExplicitPath $IniPath -ScriptPath $PSCommandPath
$script:WsBases = @()
try {
    $script:WsBases = Get-WsBasesFromIni -IniFilePath $resolvedIniPath
    $resolvedWsBase = Resolve-WsBase -Preferred $WsBase -WsList $script:WsBases
}
catch {
    $startupWsError = $_.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace($WsBase)) {
        $resolvedWsBase = $WsBase.TrimEnd('/')
    }
}
New-Item -ItemType Directory -Path $WorkingRoot -Force | Out-Null

$form = New-Object System.Windows.Forms.Form
$form.Text = "Type Applications Runner"
$form.StartPosition = 'WindowsDefaultLocation'
$form.MinimumSize = [System.Drawing.Size]::new(1024, 768)
$form.ClientSize = [System.Drawing.Size]::new(1200, 820)
$form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
$form.BackColor = [System.Drawing.Color]::WhiteSmoke

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'
$root.ColumnCount = 1
$root.RowCount = 4
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 70)))
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 60)))
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 56)))
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 40)))
$form.Controls.Add($root)

$top = New-Object System.Windows.Forms.Panel
$top.Dock = 'Fill'
$top.Padding = [System.Windows.Forms.Padding]::new(12, 12, 12, 8)

$lblType = New-Object System.Windows.Forms.Label
$lblType.Text = 'Type'
$lblType.AutoSize = $true
$lblType.Font = [System.Drawing.Font]::new('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$lblType.Location = [System.Drawing.Point]::new(8, 16)
$top.Controls.Add($lblType)

$cbType = New-Object System.Windows.Forms.ComboBox
$cbType.DropDownStyle = 'DropDownList'
$cbType.Font = [System.Drawing.Font]::new('Segoe UI', 11)
$cbType.Location = [System.Drawing.Point]::new(70, 12)
$cbType.Width = 320
$top.Controls.Add($cbType)

$lblCountry = New-Object System.Windows.Forms.Label
$lblCountry.Text = 'Country'
$lblCountry.AutoSize = $true
$lblCountry.Font = [System.Drawing.Font]::new('Segoe UI', 10)
$lblCountry.Location = [System.Drawing.Point]::new(410, 16)
$top.Controls.Add($lblCountry)

$tbCountry = New-Object System.Windows.Forms.TextBox
$tbCountry.Font = [System.Drawing.Font]::new('Segoe UI', 10)
$tbCountry.Location = [System.Drawing.Point]::new(470, 12)
$tbCountry.Width = 80
$tbCountry.Text = $Country
$top.Controls.Add($tbCountry)

$btnReload = New-Object System.Windows.Forms.Button
$btnReload.Text = 'Reload'
$btnReload.Font = [System.Drawing.Font]::new('Segoe UI', 10)
$btnReload.Location = [System.Drawing.Point]::new(570, 11)
$btnReload.Size = [System.Drawing.Size]::new(90, 32)
$top.Controls.Add($btnReload)

$lblWs = New-Object System.Windows.Forms.Label
$lblWs.Text = 'WS'
$lblWs.AutoSize = $true
$lblWs.Font = [System.Drawing.Font]::new('Segoe UI', 10)
$lblWs.Location = [System.Drawing.Point]::new(680, 16)
$top.Controls.Add($lblWs)

$tbWsBase = New-Object System.Windows.Forms.ComboBox
$tbWsBase.DropDownStyle = 'DropDown'
$tbWsBase.Font = [System.Drawing.Font]::new('Consolas', 10)
$tbWsBase.Location = [System.Drawing.Point]::new(715, 13)
$tbWsBase.Width = 430
$tbWsBase.Text = $resolvedWsBase
$top.Controls.Add($tbWsBase)

$root.Controls.Add($top, 0, 0)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.MultiSelect = $true
$grid.SelectionMode = 'FullRowSelect'
$grid.AutoSizeColumnsMode = 'Fill'
$grid.RowHeadersVisible = $false
$grid.BackgroundColor = [System.Drawing.Color]::White
$grid.Font = [System.Drawing.Font]::new('Segoe UI', 10)

$colSel = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colSel.Name = 'Select'
$colSel.HeaderText = 'Run'
$colSel.Width = 60
$colSel.FillWeight = 12
$grid.Columns.Add($colSel) | Out-Null

$colOrder = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colOrder.Name = 'Order'
$colOrder.HeaderText = '#'
$colOrder.ReadOnly = $true
$colOrder.FillWeight = 10
$grid.Columns.Add($colOrder) | Out-Null

$colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colName.Name = 'Name'
$colName.HeaderText = 'Application'
$colName.ReadOnly = $true
$colName.FillWeight = 50
$grid.Columns.Add($colName) | Out-Null

$colUrl = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colUrl.Name = 'Url'
$colUrl.HeaderText = 'URL'
$colUrl.ReadOnly = $true
$colUrl.Visible = $false
$colUrl.FillWeight = 38
$grid.Columns.Add($colUrl) | Out-Null

$colScript = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colScript.Name = 'Script'
$colScript.HeaderText = 'Script'
$colScript.ReadOnly = $true
$colScript.Visible = $false
$grid.Columns.Add($colScript) | Out-Null

$root.Controls.Add($grid, 0, 1)

$actions = New-Object System.Windows.Forms.Panel
$actions.Dock = 'Fill'
$actions.Padding = [System.Windows.Forms.Padding]::new(12, 8, 12, 8)

$btnSelectAll = New-Object System.Windows.Forms.Button
$btnSelectAll.Text = 'Select all'
$btnSelectAll.Font = [System.Drawing.Font]::new('Segoe UI', 10)
$btnSelectAll.Location = [System.Drawing.Point]::new(8, 8)
$btnSelectAll.Size = [System.Drawing.Size]::new(110, 32)
$actions.Controls.Add($btnSelectAll)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = 'Clear'
$btnClear.Font = [System.Drawing.Font]::new('Segoe UI', 10)
$btnClear.Location = [System.Drawing.Point]::new(126, 8)
$btnClear.Size = [System.Drawing.Size]::new(90, 32)
$actions.Controls.Add($btnClear)

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = 'Execute selected'
$btnRun.Font = [System.Drawing.Font]::new('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$btnRun.BackColor = [System.Drawing.Color]::FromArgb(16, 142, 92)
$btnRun.ForeColor = [System.Drawing.Color]::White
$btnRun.FlatStyle = 'Flat'
$btnRun.FlatAppearance.BorderSize = 0
$btnRun.Location = [System.Drawing.Point]::new(230, 8)
$btnRun.Size = [System.Drawing.Size]::new(170, 32)
$actions.Controls.Add($btnRun)

$root.Controls.Add($actions, 0, 2)

$tbLog = New-Object System.Windows.Forms.TextBox
$tbLog.Dock = 'Fill'
$tbLog.Multiline = $true
$tbLog.ScrollBars = 'Vertical'
$tbLog.ReadOnly = $true
$tbLog.Font = [System.Drawing.Font]::new('Consolas', 10)
$tbLog.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
$tbLog.ForeColor = [System.Drawing.Color]::Gainsboro
$root.Controls.Add($tbLog, 0, 3)

function Write-UiLog {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message
    $tbLog.AppendText($line + [Environment]::NewLine)
}

function Load-WsCombo {
    param(
        [string[]]$WsList,
        [string]$SelectedValue
    )

    $tbWsBase.Items.Clear()
    foreach ($ws in @($WsList)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$ws)) {
            [void]$tbWsBase.Items.Add(([string]$ws).TrimEnd('/'))
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($SelectedValue)) {
        $tbWsBase.Text = $SelectedValue.TrimEnd('/')
    }
}

function Load-AppsToGrid {
    param([string]$TypeName)
    $grid.Rows.Clear()
    if ([string]::IsNullOrWhiteSpace($TypeName)) { return }

    $currentWsBase = Normalize-WsBase -Raw $tbWsBase.Text
    Write-UiLog ("Loading apps for type '{0}'..." -f $TypeName)
    $apps = Get-AppsForType -BaseUrl $currentWsBase -TypeName $TypeName -CountryCode $tbCountry.Text -InsecureTls:$AllowInsecureTls
    foreach ($a in $apps) {
        $name = ([string]$a.name).Trim()
        $urlRaw = ([string]$a.url).Trim()
        $url = Expand-BaseUrl -Url $urlRaw -Base $currentWsBase
        $script = ([string]$a.script).Trim()
        $order = [string]$a.order
        [void]$grid.Rows.Add($false, $order, $name, $url, $script)
    }
    Write-UiLog ("Loaded {0} item(s)." -f $grid.Rows.Count)
}

function Get-SelectedGridKeys {
    $selectedKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $grid.Rows) {
        $isChecked = $false
        try { $isChecked = [bool]$row.Cells['Select'].Value } catch {}
        if (-not $isChecked) { continue }

        $name = ([string]$row.Cells['Name'].Value).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        [void]$selectedKeys.Add($name)
    }
    return ,$selectedKeys
}

function Restore-SelectedGridRows {
    param(
        [Parameter(Mandatory)]$SelectedKeys
    )

    $selectedRows = @()
    foreach ($row in $grid.Rows) {
        $name = ([string]$row.Cells['Name'].Value).Trim()

        if ($SelectedKeys.Contains($name)) {
            $row.Cells['Select'].Value = $true
            $selectedRows += $row
        }
        else {
            $row.Cells['Select'].Value = $false
        }
    }
    return @($selectedRows)
}

function Load-TypeList {
    param([string]$PreferredType = '')

    $cbType.Items.Clear()
    $currentWsBase = Normalize-WsBase -Raw $tbWsBase.Text
    Write-UiLog 'Loading type list...'
    $types = Get-TypeList -BaseUrl $currentWsBase -InsecureTls:$AllowInsecureTls
    foreach ($t in $types) { [void]$cbType.Items.Add($t) }
    if ($cbType.Items.Count -gt 0) {
        $selectedIndex = 0
        if (-not [string]::IsNullOrWhiteSpace($PreferredType)) {
            for ($i = 0; $i -lt $cbType.Items.Count; $i++) {
                if ([string]::Equals([string]$cbType.Items[$i], $PreferredType, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $selectedIndex = $i
                    break
                }
            }
        }
        $cbType.SelectedIndex = $selectedIndex
    }
    Write-UiLog ("Loaded {0} type(s)." -f $cbType.Items.Count)
}

$btnReload.Add_Click({
    try {
        $selectedType = [string]$cbType.SelectedItem
        Load-TypeList -PreferredType $selectedType
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            ("Failed to reload types: {0}" -f $_.Exception.Message),
            'Error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$cbType.Add_SelectedIndexChanged({
    try {
        Load-AppsToGrid -TypeName ([string]$cbType.SelectedItem)
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            ("Failed to load apps: {0}" -f $_.Exception.Message),
            'Error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$btnSelectAll.Add_Click({
    foreach ($row in $grid.Rows) {
        $row.Cells['Select'].Value = $true
    }
})

$btnClear.Add_Click({
    foreach ($row in $grid.Rows) {
        $row.Cells['Select'].Value = $false
    }
})

$btnRun.Add_Click({
    try {
        $selectedKeys = Get-SelectedGridKeys

        if ($selectedKeys.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                'No application selected.',
                'Info',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            return
        }

        $btnRun.Enabled = $false
        $btnReload.Enabled = $false
        $cbType.Enabled = $false
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        Write-UiLog 'Refreshing selected apps before execution...'
        Load-AppsToGrid -TypeName ([string]$cbType.SelectedItem)
        $selectedRows = Restore-SelectedGridRows -SelectedKeys $selectedKeys

        if ($selectedRows.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                'Selected application(s) no longer exist after refresh.',
                'Info',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            return
        }

        $okCount = 0
        $errCount = 0

        foreach ($row in $selectedRows) {
            $name = [string]$row.Cells['Name'].Value
            $url = [string]$row.Cells['Url'].Value
            $script = [string]$row.Cells['Script'].Value
            if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($url)) {
                Write-UiLog ("SKIP invalid row: name/url missing")
                continue
            }

            try {
                $safe = ($name -replace '[^\w\.-]','_')
                $itemDir = Join-Path $WorkingRoot $safe
                if (Test-Path -LiteralPath $itemDir) {
                    Remove-Item -LiteralPath $itemDir -Recurse -Force -ErrorAction SilentlyContinue
                }
                New-Item -ItemType Directory -Path $itemDir -Force | Out-Null

                if (-not [string]::IsNullOrWhiteSpace($script)) {
                    if ([System.IO.Path]::IsPathRooted($script) -or $script -match '(^|[\\/])\.\.([\\/]|$)') {
                        throw "Invalid package script path: $script"
                    }

                    if (Test-HttpUrl -Value $url) {
                        Write-UiLog ("Download package {0}" -f $name)
                        Download-PackageFolderRecursive -Url $url -Destination $itemDir -InsecureTls:$AllowInsecureTls
                    }
                    elseif (Test-UncPath -Value $url) {
                        Write-UiLog ("Copy UNC package {0}" -f $name)
                        Copy-UncFolder -Source $url -Destination $itemDir
                    }
                    else {
                        $itemDir = $url
                        Write-UiLog ("Local package {0}: {1}" -f $name, $itemDir)
                        if (-not (Test-Path -LiteralPath $itemDir -PathType Container)) {
                            throw "Local package folder not found: $itemDir"
                        }
                    }

                    $scriptRel = $script -replace '/', '\'
                    $localFile = Join-Path $itemDir $scriptRel
                    if (-not (Test-Path -LiteralPath $localFile)) {
                        throw "Package script not found after download: $localFile"
                    }

                    $ext = [System.IO.Path]::GetExtension($localFile)
                    if ([string]::IsNullOrWhiteSpace($ext)) { $ext = '.ps1' }
                    $ext = $ext.ToLowerInvariant()
                    $workDir = Split-Path -Path $localFile -Parent
                }
                else {
                    if (-not (Test-HttpUrl -Value $url)) {
                        throw "Package script is required for local or UNC sources: $name"
                    }
                    $ext = Get-InstallerExtensionFromUrl -Url $url
                    $localFile = Join-Path $itemDir ("{0}{1}" -f $safe, $ext)

                    Write-UiLog ("Download {0}" -f $name)
                    Download-WithCurl -Url $url -Destination $localFile -InsecureTls:$AllowInsecureTls
                    $workDir = $itemDir
                }

                Write-UiLog ("Execute {0}" -f $name)
                $exitCode = Invoke-Installer -Extension $ext -LocalFile $localFile -WorkingDirectory $workDir

                if ($exitCode -eq 0 -or $exitCode -eq 3010) {
                    $okCount++
                    Write-UiLog ("OK {0} (exit={1})" -f $name, $exitCode)
                }
                else {
                    $errCount++
                    Write-UiLog ("ERROR {0} (exit={1})" -f $name, $exitCode)
                }

            }
            catch {
                $errCount++
                Write-UiLog ("ERROR {0}: {1}" -f $name, $_.Exception.Message)
            }

            [System.Windows.Forms.Application]::DoEvents()
        }

        [System.Windows.Forms.MessageBox]::Show(
            ("Done.`nSuccess: {0}`nErrors: {1}" -f $okCount, $errCount),
            'Execution completed',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnRun.Enabled = $true
        $btnReload.Enabled = $true
        $cbType.Enabled = $true
    }
})

$form.Add_Shown({
    try {
        Load-WsCombo -WsList $script:WsBases -SelectedValue $resolvedWsBase
        Write-UiLog ("WS INI: {0}" -f $resolvedIniPath)
        Write-UiLog ("WS loaded from INI: {0}" -f $tbWsBase.Items.Count)
        if (-not [string]::IsNullOrWhiteSpace($startupWsError)) {
            Write-UiLog ("WS init: {0}" -f $startupWsError)
            Write-UiLog "Select a WS from list or type one manually, then click Reload."
        }
        Load-TypeList
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            ("Initialization failed: {0}" -f $_.Exception.Message),
            'Error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

[void]$form.ShowDialog()
