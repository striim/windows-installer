<#
.SYNOPSIS
    Striim 5.x+ install/verify/repair wizard for Windows (Forwarding Agent first, Node secondary).
.NOTES
    Compatibility floor: Windows PowerShell 5.1; pwsh 7 compatible.
    For Striim 4.x use the legacy msjetchecker.ps1.
#>
#region Bootstrap
[CmdletBinding()]
param(
    # Target Striim version (used with -DownloadOnly; interview default otherwise).
    [Parameter()] [string]$Version,

    # Path to a DPAPI-protected plan file. Set by the elevated relaunch; skips straight to Execute.
    [Parameter()] [string]$PlanFile,

    # Download all dependencies into downloads\ and exit (offline bundling). Requires -Version and -Agent or -Node.
    [Parameter()] [switch]$DownloadOnly,

    # With -DownloadOnly: bundle Forwarding Agent files.
    [Parameter()] [switch]$Agent,

    # With -DownloadOnly: bundle Node files.
    [Parameter()] [switch]$Node,

    # Test hook: define all functions, execute nothing (used by the Pester suite to dot-source this file).
    [Parameter()] [switch]$NoRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# The classic PowerShell download penalty fix - never show Write-Progress from cmdlets.
$ProgressPreference = 'SilentlyContinue'

# System.Net.Http is not auto-loaded on Windows PowerShell 5.1.
try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { }

$script:ScriptPath  = $PSCommandPath
$script:ScriptDir   = Split-Path -Parent $PSCommandPath

# Runtime artifacts (downloads\, install-plan.json) live beside the script by default - that keeps
# an offline/air-gapped bundle self-contained. But the script's own directory is not always
# writable: if it was downloaded into C:\Windows\System32 (the default working dir of an elevated
# prompt, so 'iwr -OutFile Install-Striim.ps1' lands it there), a later non-admin run cannot write
# next to it and plan-file save fails with 'Access denied'. Probe for write access and fall back to
# a per-user writable directory when the script dir is read-only.
$script:WorkingDir = $script:ScriptDir
$script:WorkingDirFallback = $false
try {
    $probe = Join-Path $script:ScriptDir ('.striim-writetest-{0}.tmp' -f $PID)
    New-Item -ItemType File -Path $probe -Force -ErrorAction Stop | Out-Null
    Remove-Item -Path $probe -Force -ErrorAction SilentlyContinue
} catch {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } elseif ($env:TEMP) { $env:TEMP } else { $script:ScriptDir }
    $script:WorkingDir = Join-Path $base 'Striim\installer'
    New-Item -ItemType Directory -Force -Path $script:WorkingDir -ErrorAction SilentlyContinue | Out-Null
    $script:WorkingDirFallback = $true
}
$script:DownloadDir = Join-Path $script:WorkingDir 'downloads'
$script:TranscriptPath = $null
$script:WarningsCollected = New-Object System.Collections.ArrayList

$script:DefaultStriimVersion   = '5.4.0.6'
$script:MinSupportedVersion    = [version]'5.0'
$script:Java17EraVersion       = [version]'5.0.6'   # builds below this are the Java-11 era
$script:KnownGoodOleDbVersions = @('18.2.3.0', '18.7.4.0')  # extend as QA'd

# Shared exit-code table (field lore from msjetchecker.ps1) - one place, no per-step magic numbers.
$script:ExitCodeTable = @{
    0    = [pscustomobject]@{ Result = 'Pass';            Message = 'Success';                                              Hint = '' }
    3010 = [pscustomobject]@{ Result = 'PassWithWarning'; Message = 'Success - reboot required';                            Hint = 'A reboot is recommended once the install completes.' }
    1638 = [pscustomobject]@{ Result = 'Pass';            Message = 'Another version of this product is already installed'; Hint = '' }
    1618 = [pscustomobject]@{ Result = 'Fail';            Message = 'Another MSI installation is already in progress';      Hint = 'Wait for Windows Update or the other installer to finish, then choose Retry.' }
    5100 = [pscustomobject]@{ Result = 'Fail';            Message = 'A newer version of this runtime is already installed'; Hint = "Striim MSJet requires the VC++ 2015-2019 (14.2x) runtime. Uninstall 'Microsoft Visual C++ 2015-2022 Redistributable (x64)' via Settings > Apps, then choose Retry." }
}

function Get-ExitCodeMeaning {
    param([Parameter(Mandatory)][int]$Code)
    if ($script:ExitCodeTable.ContainsKey($Code)) { return $script:ExitCodeTable[$Code] }
    return [pscustomobject]@{ Result = 'Fail'; Message = "Installer exited with unexpected code $Code"; Hint = '' }
}

function Write-Log {
    param(
        [ValidateSet('Info', 'Success', 'Warn', 'Error', 'Step')] [string]$Level = 'Info',
        [Parameter(Mandatory)][string]$Message
    )
    $color = switch ($Level) {
        'Success' { 'Green' } 'Warn' { 'Yellow' } 'Error' { 'Red' } 'Step' { 'Cyan' } default { 'Gray' }
    }
    if ($Level -eq 'Warn') { [void]$script:WarningsCollected.Add($Message) }
    Write-Host ('[{0,-7}] {1}' -f $Level.ToUpper(), $Message) -ForegroundColor $color
}

function Start-InstallTranscript {
    param([Parameter(Mandatory)][string]$InstallPath)
    $logDir = Join-Path $InstallPath 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    $script:TranscriptPath = Join-Path $logDir ('install-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Start-Transcript -Path $script:TranscriptPath -Append | Out-Null
    Write-Log -Level Info -Message "Transcript started: $script:TranscriptPath"
    return $script:TranscriptPath
}

function Stop-InstallTranscript {
    try { Stop-Transcript | Out-Null } catch { }
}

function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
#endregion Bootstrap

#region UI
function Show-Header {
    Write-Host ('=' * 74) -ForegroundColor Cyan
    Write-Host '            STRIIM  -  Install-Striim.ps1  Setup & Maintenance Wizard' -ForegroundColor White
    Write-Host ('=' * 74) -ForegroundColor Cyan
    Write-Host ''
}

function Confirm-UserChoice {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$DefaultChoice = 'y'
    )
    $validChoices = 'y', 'n'
    if ($DefaultChoice.ToLower() -notin $validChoices) { $DefaultChoice = 'y' }
    $promptHint = if ($DefaultChoice.ToLower() -eq 'y') { '(Y/n)' } else { '(y/N)' }
    while ($true) {
        $response = Read-Host -Prompt "$Prompt $promptHint"
        if ([string]::IsNullOrWhiteSpace($response)) { return $DefaultChoice.ToLower() -eq 'y' }
        if ($response.ToLower() -in $validChoices) { return $response.ToLower() -eq 'y' }
        Write-Log -Level Warn -Message "Invalid input. Please enter 'y' or 'n'."
    }
}

function Read-PromptWithDefault {
    # Read-Host with an optional prefill shown in brackets; Enter accepts the default.
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [AllowEmptyString()][string]$Default
    )
    if ([string]::IsNullOrWhiteSpace($Default)) { return (Read-Host -Prompt $Prompt) }
    $raw = Read-Host -Prompt "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    return $raw
}

function Show-PickList {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][scriptblock]$DisplayWith
    )
    Write-Host "`n$Title" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ('  [{0}] {1}' -f ($i + 1), (& $DisplayWith $Items[$i]))
    }
    while ($true) {
        $raw = Read-Host -Prompt ('Select 1-{0}' -f $Items.Count)
        $idx = 0
        if ([int]::TryParse($raw, [ref]$idx) -and $idx -ge 1 -and $idx -le $Items.Count) {
            return $Items[$idx - 1]
        }
        Write-Log -Level Warn -Message 'Invalid selection.'
    }
}

function ConvertTo-SelectionIndexes {
    # Parses multi-select input like "1,3 5" / "all" / "" into sorted unique 1-based indexes.
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$OptionCount
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $trimmed = $Text.Trim().ToLower()
    if ($trimmed -in @('none', '0')) { return @() }
    if ($trimmed -in @('a', 'all')) { return @(1..$OptionCount) }
    $indexes = New-Object System.Collections.ArrayList
    foreach ($token in ($Text -split '[,\s]+')) {
        if ([string]::IsNullOrWhiteSpace($token)) { continue }
        $n = 0
        if (-not [int]::TryParse($token, [ref]$n) -or $n -lt 1 -or $n -gt $OptionCount) {
            throw "Invalid selection '$token'. Enter numbers between 1 and $OptionCount, 'all', or press Enter for none."
        }
        if (-not $indexes.Contains($n)) { [void]$indexes.Add($n) }
    }
    return @($indexes | Sort-Object)
}
#endregion UI

#region VersionGate
function ConvertTo-StriimVersion {
    # Striim hotfix releases append letters to the build number (e.g. 5.4.0.2A).
    # [version] only parses numeric segments, so strip a trailing letter suffix
    # for comparisons; callers keep the raw string for URLs and display.
    param([Parameter(Mandatory)][string]$VersionString)
    if ($VersionString -notmatch '^(\d+(\.\d+)*)[A-Za-z]*$') { return $null }
    $numeric = $Matches[1]
    $parsed = $null
    if ([version]::TryParse($numeric, [ref]$parsed)) { return $parsed }
    return $null
}

function Test-StriimVersionSupported {
    # Gate: 5.x+ only. <5.0 -> reject (msjetchecker.ps1 handles 4.x).
    # 5.0 <= v < 5.0.6 -> allowed with a Java-11-era warning (this wizard supports the Java-17 line only).
    param([Parameter(Mandatory)][string]$VersionString)
    $v = ConvertTo-StriimVersion -VersionString $VersionString
    if ($null -eq $v) {
        return [pscustomobject]@{
            Supported = $false; Warning = $null
            Reason    = "'$VersionString' is not a valid version. Use a format like 5.4.0.6."
        }
    }
    if ($v -lt $script:MinSupportedVersion) {
        return [pscustomobject]@{
            Supported = $false; Warning = $null
            Reason    = "Striim $VersionString is below 5.0. This wizard supports 5.x+ only - use the legacy msjetchecker.ps1 for 4.x installs."
        }
    }
    $warning = $null
    if ($v -lt $script:Java17EraVersion) {
        $warning = "Striim $VersionString is an early-5.0.x build from the Java 11 era. This wizard only supports the Java-17 line (~5.0.6 and later). Prefer upgrading Striim, or use msjetchecker.ps1."
    }
    return [pscustomobject]@{ Supported = $true; Warning = $warning; Reason = $null }
}
#endregion VersionGate

#region Manifest
# Central manifest of all downloadable files. 5.x-only scope: no Java 8, no 4.2.0.20 patch jars.
# NodeType 'A' = Agent, 'N' = Node, $null = common to both.
# Category 'Patch' entries (none today) use TargetFile + Min/MaxVersion - the generic version-gated
# patch-jar step type (Task 14) consumes them, so future 5.x field patches are manifest-only changes.
$script:AllDownloads = @(
    # NOTE: the ICU/MSSQLNative lib\ DLLs and the GitHub (StriimQueryAutoLoader) sources were
    # removed - they were 4.2.0.20-era fixes; Striim 5.x ships its own natives. sqljdbc_auth.dll
    # (Integrated Security) is no longer downloaded either: it ships NEXT TO THIS SCRIPT.

    # Java 17 (Microsoft Build of OpenJDK) - the only Java this wizard installs
    [pscustomobject]@{ Name = 'microsoft-jdk-17-windows-x64.msi'; Url = 'https://aka.ms/download-jdk/microsoft-jdk-17-windows-x64.msi'; Category = 'Java'; NodeType = $null; TargetFile = $null; MinVersion = '5.0'; MaxVersion = '99.9'; Sha256 = $null }

    # OS prerequisites
    # VS 2019 (vs/16) pinned link: MSJet needs the 2015-2019 runtime line, NOT 2015-2022 (see Test-VcRedistInstalled).
    [pscustomobject]@{ Name = 'vc_redist.x64.exe'; Url = 'https://aka.ms/vs/16/release/14.29.30133/VC_Redist.x64.exe'; Category = 'Prereq'; NodeType = $null; TargetFile = $null; MinVersion = '5.0'; MaxVersion = '99.9'; Sha256 = $null }
    [pscustomobject]@{ Name = 'msoledbsql.msi';    Url = 'https://go.microsoft.com/fwlink/?linkid=2278907';        Category = 'Prereq'; NodeType = $null; TargetFile = $null; MinVersion = '5.0'; MaxVersion = '99.9'; Sha256 = $null }

    # JDBC drivers (Agent only)
    [pscustomobject]@{ Name = 'mariadb-java-client-2.4.3.jar';                       Url = 'https://repo1.maven.org/maven2/org/mariadb/jdbc/mariadb-java-client/2.4.3/mariadb-java-client-2.4.3.jar';                       Category = 'Driver'; NodeType = 'A'; TargetFile = $null; MinVersion = '5.0'; MaxVersion = '99.9'; Sha256 = $null }
    [pscustomobject]@{ Name = 'mysql-connector-j-8.0.30.zip';                        Url = 'https://cdn.mysql.com/archives/mysql-connector-j/mysql-connector-j-8.0.30.zip';                                              Category = 'Driver'; NodeType = 'A'; TargetFile = $null; MinVersion = '5.0'; MaxVersion = '99.9'; Sha256 = $null }
    [pscustomobject]@{ Name = 'instantclient-basic-windows.x64-21.6.0.0.0dbru.zip';  Url = 'https://download.oracle.com/otn_software/nt/instantclient/216000/instantclient-basic-windows.x64-21.6.0.0.0dbru.zip';        Category = 'Driver'; NodeType = 'A'; TargetFile = $null; MinVersion = '5.0'; MaxVersion = '99.9'; Sha256 = $null }
    [pscustomobject]@{ Name = 'postgresql-42.2.27.jar';                              Url = 'https://jdbc.postgresql.org/download/postgresql-42.2.27.jar';                                                                 Category = 'Driver'; NodeType = 'A'; TargetFile = $null; MinVersion = '5.0'; MaxVersion = '99.9'; Sha256 = $null }

    # Main Striim application zips
    [pscustomobject]@{ Name = 'Striim_Agent_{VERSION}.zip'; Url = 'https://striim-downloads.striim.com/Releases/{VERSION}/Striim_Agent_{VERSION}.zip'; Category = 'MainInstaller'; NodeType = 'A'; TargetFile = $null; MinVersion = '5.0'; MaxVersion = '99.9'; Sha256 = $null }
    [pscustomobject]@{ Name = 'Striim_{VERSION}.zip';       Url = 'https://striim-downloads.striim.com/Releases/{VERSION}/Striim_{VERSION}.zip';       Category = 'MainInstaller'; NodeType = 'N'; TargetFile = $null; MinVersion = '5.0'; MaxVersion = '99.9'; Sha256 = $null }

    # Windows service wrapper zips (yajsw)
    [pscustomobject]@{ Name = 'Striim_windowsAgent_{VERSION}.zip';   Url = 'https://striim-downloads.striim.com/Releases/{VERSION}/Striim_windowsAgent_{VERSION}.zip';   Category = 'ServiceInstaller'; NodeType = 'A'; TargetFile = $null; MinVersion = '5.0'; MaxVersion = '99.9'; Sha256 = $null }
    [pscustomobject]@{ Name = 'Striim_windowsService_{VERSION}.zip'; Url = 'https://striim-downloads.striim.com/Releases/{VERSION}/Striim_windowsService_{VERSION}.zip'; Category = 'ServiceInstaller'; NodeType = 'N'; TargetFile = $null; MinVersion = '5.0'; MaxVersion = '99.9'; Sha256 = $null }
)

function Resolve-ManifestEntry {
    param(
        [Parameter(Mandatory)][object]$Entry,
        [Parameter(Mandatory)][string]$TargetVersion
    )
    return [pscustomobject]@{
        Name       = $Entry.Name.Replace('{VERSION}', $TargetVersion)
        Url        = $Entry.Url.Replace('{VERSION}', $TargetVersion)
        Category   = $Entry.Category
        NodeType   = $Entry.NodeType
        TargetFile = $Entry.TargetFile
        MinVersion = $Entry.MinVersion
        MaxVersion = $Entry.MaxVersion
        Sha256     = $Entry.Sha256
    }
}

function Get-ManifestFiles {
    param(
        [Parameter(Mandatory)][ValidateSet('A', 'N')][string]$NodeType,
        [Parameter(Mandatory)][string]$TargetVersion,
        [string[]]$Categories,
        [object[]]$ManifestEntries = $script:AllDownloads
    )
    $v = ConvertTo-StriimVersion -VersionString $TargetVersion
    if ($null -eq $v) { throw "Invalid Striim version '$TargetVersion'." }
    $matched = $ManifestEntries | Where-Object {
        ($v -ge [version]$_.MinVersion) -and ($v -le [version]$_.MaxVersion) -and
        ($null -eq $_.NodeType -or $_.NodeType -eq $NodeType) -and
        ((-not $Categories) -or ($Categories -contains $_.Category))
    }
    return @($matched | ForEach-Object { Resolve-ManifestEntry -Entry $_ -TargetVersion $TargetVersion })
}
#endregion Manifest

#region Downloads
function Test-FileSha256 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedSha256
    )
    $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    return ($actual -ieq $ExpectedSha256)
}

function Get-CurlArguments {
    # curl.exe ships with Windows 10 1809+/Server 2019+: HTTP/2, redirects, retries, resume.
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    return @(
        '--location', '--fail',
        '--retry', '3', '--retry-delay', '2',
        '--continue-at', '-',
        '--progress-bar',
        '--output', $OutFile,
        $Uri
    )
}

function Invoke-HttpClientDownload {
    # Last-resort buffered stream with progress redraws throttled to ~2/sec.
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    $client = $null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromMinutes(30)
        $response = $client.GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
        if (-not $response.IsSuccessStatusCode) { throw "HTTP $([int]$response.StatusCode) $($response.StatusCode)" }
        $total = $response.Content.Headers.ContentLength
        $inStream = $response.Content.ReadAsStreamAsync().Result
        $outStream = [System.IO.File]::Create($OutFile)
        try {
            $buffer = New-Object byte[] 1048576
            $done = [long]0
            $lastDraw = [DateTime]::MinValue
            while ($true) {
                $read = $inStream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                $outStream.Write($buffer, 0, $read)
                $done += $read
                if (((Get-Date) - $lastDraw).TotalMilliseconds -ge 500) {
                    $lastDraw = Get-Date
                    if ($total) {
                        $pct = [math]::Round(($done / $total) * 100)
                        Write-Host ("`r  {0,3}%  ({1:N0} / {2:N0} MB)" -f $pct, ($done / 1MB), ($total / 1MB)) -NoNewline
                    } else {
                        Write-Host ("`r  {0:N0} MB" -f ($done / 1MB)) -NoNewline
                    }
                }
            }
            Write-Host ''
        } finally {
            $outStream.Dispose()
            $inStream.Dispose()
        }
        return $true
    } catch {
        Write-Log -Level Error -Message "HttpClient download failed: $($_.Exception.Message)"
        return $false
    } finally {
        if ($client) { $client.Dispose() }
    }
}

function Get-RemoteFile {
    # Single downloader used everywhere: cache -> curl.exe -> BITS -> HttpClient.
    # Partial files land in <name>.partial and resume (curl --continue-at -); completed files move into place.
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$Sha256
    )
    if (Test-Path $OutFile) {
        if ($Sha256) {
            if (Test-FileSha256 -Path $OutFile -ExpectedSha256 $Sha256) {
                Write-Log -Level Success -Message "Cached: $(Split-Path $OutFile -Leaf)"
                return $true
            }
            Write-Log -Level Warn -Message "Cached $(Split-Path $OutFile -Leaf) failed its checksum - re-downloading."
            Remove-Item -Path $OutFile -Force
        } else {
            Write-Log -Level Success -Message "Cached: $(Split-Path $OutFile -Leaf)"
            return $true
        }
    }
    $outDir = Split-Path -Parent $OutFile
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    $partial = "$OutFile.partial"
    $ok = $false

    # 1) curl.exe (primary)
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        Write-Log -Level Info -Message "Downloading $(Split-Path $OutFile -Leaf) via curl.exe..."
        $curlArgs = Get-CurlArguments -Uri $Uri -OutFile $partial
        try {
            & $curl.Source @curlArgs
            if ($LASTEXITCODE -eq 0) { $ok = $true }
            else { Write-Log -Level Warn -Message "curl.exe failed (exit $LASTEXITCODE); trying BITS..." }
        } catch {
            # Unlike the BITS/HttpClient fallbacks below, a bare '& curl.exe' has no try/catch of
            # its own - under $ErrorActionPreference = 'Stop' a native-command error here (e.g. a
            # NativeCommandError surfaced as terminating) would otherwise skip the $LASTEXITCODE
            # check entirely and abort the whole download instead of falling through to BITS.
            Write-Log -Level Warn -Message "curl.exe threw an error ($($_.Exception.Message)); trying BITS..."
        }
    }

    # 2) BITS (Server 2016 / curl-less boxes)
    if (-not $ok) {
        try {
            Import-Module BitsTransfer -ErrorAction Stop
            Write-Log -Level Info -Message "Downloading $(Split-Path $OutFile -Leaf) via BITS..."
            Start-BitsTransfer -Source $Uri -Destination $partial -ErrorAction Stop
            $ok = $true
        } catch {
            Write-Log -Level Warn -Message "BITS unavailable or failed ($($_.Exception.Message)); trying HttpClient..."
        }
    }

    # 3) HttpClient buffered stream (last resort)
    if (-not $ok) {
        Write-Log -Level Info -Message "Downloading $(Split-Path $OutFile -Leaf) via HttpClient..."
        $ok = Invoke-HttpClientDownload -Uri $Uri -OutFile $partial
    }

    if (-not $ok) {
        # Keep the .partial so curl can resume on Retry rather than restart.
        return $false
    }
    Move-Item -Path $partial -Destination $OutFile -Force

    if ($Sha256 -and -not (Test-FileSha256 -Path $OutFile -ExpectedSha256 $Sha256)) {
        Write-Log -Level Warn -Message "SHA-256 mismatch for $(Split-Path $OutFile -Leaf)."
        if (-not (Confirm-UserChoice -Prompt 'Checksum mismatch - keep the file anyway?' -DefaultChoice 'n')) {
            Remove-Item -Path $OutFile -Force
            return $false
        }
    }
    return $true
}

function Build-DownloadManifest {
    # JSON document written next to the bundle so the offline side can validate it.
    param(
        [Parameter(Mandatory)][object[]]$Files,
        [Parameter(Mandatory)][string]$TargetVersion,
        [Parameter(Mandatory)][string]$NodeType
    )
    $items = foreach ($f in $Files) {
        [pscustomobject]@{
            Name      = $f.Name
            Url       = $f.Url
            Category  = $f.Category
            SizeBytes = $f.SizeBytes
            Sha256    = $f.Sha256
        }
    }
    $doc = [pscustomobject]@{
        GeneratedUtc  = (Get-Date).ToUniversalTime().ToString('o')
        StriimVersion = $TargetVersion
        NodeType      = $NodeType
        Files         = @($items)
    }
    return ($doc | ConvertTo-Json -Depth 4)
}

function Invoke-DownloadOnly {
    param(
        [Parameter(Mandatory)][ValidateSet('A', 'N')][string]$NodeType,
        [Parameter(Mandatory)][string]$TargetVersion,
        [Parameter(Mandatory)][string]$DownloadDir
    )
    $gate = Test-StriimVersionSupported -VersionString $TargetVersion
    if (-not $gate.Supported) { throw $gate.Reason }
    if ($gate.Warning) { Write-Log -Level Warn -Message $gate.Warning }

    if (-not (Test-Path $DownloadDir)) { New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null }
    $files = Get-ManifestFiles -NodeType $NodeType -TargetVersion $TargetVersion
    $bundled = New-Object System.Collections.ArrayList
    $failed = New-Object System.Collections.ArrayList
    foreach ($file in $files) {
        $target = Join-Path $DownloadDir $file.Name
        if (Get-RemoteFile -Uri $file.Url -OutFile $target -Sha256 $file.Sha256) {
            $hash = (Get-FileHash -Path $target -Algorithm SHA256).Hash
            [void]$bundled.Add([pscustomobject]@{
                Name      = $file.Name
                Url       = $file.Url
                Category  = $file.Category
                SizeBytes = (Get-Item $target).Length
                Sha256    = $hash
            })
        } else {
            [void]$failed.Add($file.Name)
            Write-Log -Level Error -Message "Failed to download $($file.Name)."
        }
    }
    $manifestPath = Join-Path $DownloadDir 'manifest.json'
    Build-DownloadManifest -Files @($bundled) -TargetVersion $TargetVersion -NodeType $NodeType |
        Set-Content -Path $manifestPath -Encoding UTF8
    Write-Log -Level Success -Message "Bundle complete: $($bundled.Count) file(s) in $DownloadDir; manifest at $manifestPath."
    if ($failed.Count -gt 0) {
        Write-Log -Level Warn -Message "Failed downloads: $($failed -join ', '). Re-run to resume."
    }
    Write-Log -Level Info -Message 'Copy this whole directory (script + downloads\) to the offline machine and run the script normally.'
}
#endregion Downloads

#region StepEngine
function New-InstallStep {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Test,
        [scriptblock]$Action = { },
        [switch]$Critical
    )
    return [pscustomobject]@{
        Name     = $Name
        Test     = $Test
        Action   = $Action
        Critical = [bool]$Critical
    }
}

function Show-FailureMenu {
    # Pause menu on step failure. Critical steps hide [S]kip.
    param(
        [Parameter(Mandatory)][string]$StepName,
        [Parameter(Mandatory)][bool]$Critical,
        [string]$ErrorMessage
    )
    Write-Log -Level Error -Message "Step failed: $StepName"
    if ($ErrorMessage) { Write-Log -Level Error -Message "  $ErrorMessage" }
    if ($script:TranscriptPath) { Write-Log -Level Info -Message "Full log: $script:TranscriptPath" }
    $options = if ($Critical) { '[R]etry / [A]bort (critical step - cannot skip)' } else { '[R]etry / [S]kip / [A]bort' }
    while ($true) {
        $choice = (Read-Host -Prompt $options).Trim().ToUpper()
        if ($choice -eq 'R') { return 'Retry' }
        if ($choice -eq 'A') { return 'Abort' }
        if ($choice -eq 'S' -and -not $Critical) { return 'Skip' }
        Write-Log -Level Warn -Message 'Invalid choice.'
    }
}

$script:ClosureAutomaticNames = $null
function Get-ClosureCapturedVariables {
    # Pull the variables a .GetNewClosure() block captured out of its dynamic module so they can be
    # re-supplied when the block is re-bound to the script scope (see Invoke-StepBlock). Captured
    # values sit at scope 1 of the module (scope 0 is the transient scope of the probe block); the
    # automatic variables present in any fresh closure module are computed once and filtered out.
    param([Parameter(Mandatory)][scriptblock]$Block)
    $list = New-Object 'System.Collections.Generic.List[System.Management.Automation.PSVariable]'
    if (-not $Block.Module) { return , $list }
    if ($null -eq $script:ClosureAutomaticNames) {
        $script:ClosureAutomaticNames = @(& ({ }.GetNewClosure().Module) { Get-Variable -Scope 1 -ErrorAction SilentlyContinue } | ForEach-Object Name)
    }
    foreach ($v in (& $Block.Module { Get-Variable -Scope 1 -ErrorAction SilentlyContinue })) {
        if ($script:ClosureAutomaticNames -notcontains $v.Name) {
            $list.Add((New-Object System.Management.Automation.PSVariable($v.Name, $v.Value)))
        }
    }
    return , $list
}

function Invoke-StepBlock {
    # Run a step's Test/Action block so that it (and any installer functions it calls, including
    # nested calls between them) resolves reliably on EVERY PowerShell version. The blocks are built
    # with .GetNewClosure(), which binds them to an isolated dynamic-module SessionState; under
    # Windows PowerShell 5.1 that module does not resolve this script's script-scoped functions, so a
    # step like 'Backup-StriimConfig ...' fails as 'not recognized'. We re-create the block from its
    # source text (binding it to this script's session state, where all functions live) and re-supply
    # the closure's captured variables via InvokeWithContext.
    param([Parameter(Mandatory)][scriptblock]$Block)
    $rebound = [scriptblock]::Create($Block.ToString())
    return $rebound.InvokeWithContext($null, (Get-ClosureCapturedVariables -Block $Block))
}

function Test-StepCondition {
    # Invoke a step Test block and coerce its output to a single boolean (InvokeWithContext returns a
    # collection; the block's result is its last output).
    param([Parameter(Mandatory)]$Step)
    $out = @(Invoke-StepBlock -Block $Step.Test)
    if ($out.Count -eq 0) { return $false }
    return [bool]$out[-1]
}

function Invoke-StepList {
    # The core loop: Test -> satisfied? skip : run Action -> re-Test -> failure menu.
    # Mode Verify runs all Tests and changes nothing (maintenance [1]).
    param(
        [Parameter(Mandatory)][object[]]$Steps,
        [ValidateSet('Execute', 'Verify')][string]$Mode = 'Execute'
    )
    $steps = @($Steps)
    $results = New-Object System.Collections.ArrayList
    $total = $steps.Count
    $n = 0
    foreach ($step in $steps) {
        $n++
        Write-Log -Level Step -Message ('[{0}/{1}] {2}' -f $n, $total, $step.Name)
        $passed = $false
        try { $passed = Test-StepCondition -Step $step } catch { $passed = $false }

        if ($Mode -eq 'Verify') {
            $status = if ($passed) { 'Passed' } else { 'Failed' }
            [void]$results.Add([pscustomobject]@{ Name = $step.Name; Status = $status; Detail = '' })
            continue
        }

        if ($passed) {
            Write-Log -Level Success -Message '  Already present - nothing to do.'
            [void]$results.Add([pscustomobject]@{ Name = $step.Name; Status = 'AlreadyPresent'; Detail = '' })
            continue
        }

        $done = $false
        while (-not $done) {
            $err = ''
            try {
                Invoke-StepBlock -Block $step.Action | Out-Host
                $passed = Test-StepCondition -Step $step
            } catch {
                $passed = $false
                # InvokeWithContext wraps the real error - surface the inner message when present.
                $err = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
            }
            if ($passed) {
                Write-Log -Level Success -Message '  Done.'
                [void]$results.Add([pscustomobject]@{ Name = $step.Name; Status = 'Fixed'; Detail = '' })
                $done = $true
                break
            }
            $decision = Show-FailureMenu -StepName $step.Name -Critical $step.Critical -ErrorMessage $err
            if ($decision -eq 'Skip') {
                Write-Log -Level Warn -Message "Skipped: $($step.Name)"
                [void]$results.Add([pscustomobject]@{ Name = $step.Name; Status = 'Skipped'; Detail = $err })
                $done = $true
            } elseif ($decision -eq 'Abort') {
                [void]$results.Add([pscustomobject]@{ Name = $step.Name; Status = 'Failed'; Detail = $err })
                throw "Aborted at step '$($step.Name)'."
            }
            # 'Retry' falls through and loops.
        }
    }
    return @($results)
}
#endregion StepEngine

#region Detect
function Get-ProfileArtifacts {
    # One table of per-profile names. Service names are exactly 'Striim Agent' / 'Striim' (field lore).
    param([Parameter(Mandatory)][ValidateSet('A', 'N')][string]$NodeType)
    if ($NodeType -eq 'A') {
        return [pscustomobject]@{
            NodeType = 'A'; ProfileName = 'Forwarding Agent'; ServiceName = 'Striim Agent'
            ConfigFile = 'conf\agent.conf'
            WrapperConfRelPath = $script:WrapperConfRelPaths['A']
            JksFile = 'conf\aks.jks'; PwdFile = 'conf\aksKey.pwd'; KeystoreScript = 'bin\aksConfig.bat'
            ServiceSetupScript = 'setupWindowsAgent.ps1'; ServiceConfigDir = 'conf\windowsAgent'
            DefaultSubPath = 'striim\Agent'
        }
    }
    return [pscustomobject]@{
        NodeType = 'N'; ProfileName = 'Node'; ServiceName = 'Striim'
        ConfigFile = 'conf\startUp.properties'
        WrapperConfRelPath = $script:WrapperConfRelPaths['N']
        JksFile = 'conf\sks.jks'; PwdFile = 'conf\sksKey.pwd'; KeystoreScript = 'bin\sksConfig.bat'
        ServiceSetupScript = 'setupWindowsService.ps1'; ServiceConfigDir = 'conf\windowsService'
        DefaultSubPath = 'striim'
    }
}

function Get-FixedDriveRoots {
    $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction SilentlyContinue)
    return @($disks | ForEach-Object { $_.DeviceID + '\' })
}

function Get-CandidateInstallPaths {
    param(
        [Parameter(Mandatory)][string[]]$DriveRoots,
        [string]$CurrentDirectory,
        [string]$ScriptDirectory
    )
    $candidates = New-Object System.Collections.ArrayList
    foreach ($root in $DriveRoots) {
        foreach ($sub in @('striim\Agent', 'striim', 'agent', 'Striim Agent')) {
            [void]$candidates.Add((Join-Path $root $sub))
        }
    }
    foreach ($extra in @($CurrentDirectory, $ScriptDirectory)) {
        if (-not [string]::IsNullOrWhiteSpace($extra)) { [void]$candidates.Add($extra) }
    }
    $seen = @{}
    $unique = New-Object System.Collections.ArrayList
    foreach ($c in $candidates) {
        $key = $c.TrimEnd('\').ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            [void]$unique.Add($c)
        }
    }
    return @($unique)
}

function Get-PlatformJarVersion {
    # Version may carry a hotfix letter suffix (Platform-5.4.0.2A.jar) - keep it,
    # since release URLs and display use the full string.
    param([Parameter(Mandatory)][string]$JarFileName)
    if ($JarFileName -match '^Platform-(\d+(\.\d+)*[A-Za-z]*)\.jar$') { return $Matches[1] }
    return $null
}

function Test-StriimInstallDir {
    # A path counts as an install when lib\ holds a Platform jar, or when conf markers
    # (conf\agent.conf / conf\startUp.properties) exist ALONGSIDE a lib\ directory.
    # conf remnants WITHOUT lib\ are NOT an install: the wizard goes to the fresh-install
    # interview instead of a maintenance menu it cannot version (field request).
    param([Parameter(Mandatory)][string]$Path)
    $result = [pscustomobject]@{ IsInstall = $false; Type = $null; Version = $null; Path = $Path }
    if (-not (Test-Path $Path -PathType Container)) { return $result }
    $agentConf = Join-Path $Path 'conf\agent.conf'
    $nodeProps = Join-Path $Path 'conf\startUp.properties'
    $libPath = Join-Path $Path 'lib'
    $hasLib = Test-Path $libPath -PathType Container
    $jar = $null
    if ($hasLib) {
        # Use Where-Object + -match (case-insensitive) instead of -Filter to avoid
        # case-sensitivity differences between Windows PowerShell 5.1 and pwsh 7.
        $jar = Get-ChildItem -Path $libPath -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^platform-\d' } |
            Select-Object -First 1
    }
    if ($jar) { $result.Version = Get-PlatformJarVersion -JarFileName $jar.Name }
    if (Test-Path $agentConf)      { $result.Type = 'A' }
    elseif (Test-Path $nodeProps)  { $result.Type = 'N' }
    elseif ($jar) {
        # Jar but no conf: type from the directory name as a best guess.
        $result.Type = if ((Split-Path $Path -Leaf) -imatch 'agent') { 'A' } else { 'N' }
    }
    $result.IsInstall = ($null -ne $jar) -or (($null -ne $result.Type) -and $hasLib)
    return $result
}

function ConvertFrom-ServicePathName {
    # Win32_Service.PathName is either "quoted exe" args or unquoted-exe args.
    param([Parameter(Mandatory)][string]$PathName)
    if ($PathName -match '^"([^"]+)"') { return $Matches[1] }
    return ($PathName -split '\s+')[0]
}

function Find-InstallRootFromPath {
    # Walk up parent dirs from a wrapper exe/path until Test-StriimInstallDir passes.
    param([Parameter(Mandatory)][string]$StartPath)
    $dir = $StartPath
    if ($dir -match '\.[A-Za-z0-9]+$') { $dir = Split-Path -Parent $dir }
    while (-not [string]::IsNullOrEmpty($dir)) {
        if ((Test-StriimInstallDir -Path $dir).IsInstall) { return $dir }
        $parent = Split-Path -Parent $dir
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $dir) { return $null }
        $dir = $parent
    }
    return $null
}

function Find-StriimInstalls {
    # Read-only, no admin. Three layers, cheapest-and-most-reliable first:
    # 1) SCM service PathName, 2) candidate path list on all fixed drives + CWD + script dir,
    # 3) shallow one-level *striim* scan of each drive root. No recursive walking.
    $found = New-Object System.Collections.ArrayList
    $seen = @{}
    $addInstall = {
        param($info, $serviceState)
        $key = $info.Path.TrimEnd('\').ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            [void]$found.Add([pscustomobject]@{
                Path = $info.Path; Type = $info.Type; Version = $info.Version; ServiceState = $serviceState
            })
        }
    }

    # Layer 1: Service Control Manager
    $services = @(Get-CimInstance Win32_Service -Filter "Name='Striim Agent' OR Name='Striim'" -ErrorAction SilentlyContinue)
    foreach ($svc in $services) {
        if ([string]::IsNullOrWhiteSpace($svc.PathName)) { continue }
        $exe = ConvertFrom-ServicePathName -PathName $svc.PathName
        $root = Find-InstallRootFromPath -StartPath $exe
        if ($root) { & $addInstall (Test-StriimInstallDir -Path $root) $svc.State }
    }

    # Layer 2: candidate paths on every fixed drive + CWD + script dir
    $roots = @(Get-FixedDriveRoots)
    $candidates = Get-CandidateInstallPaths -DriveRoots $roots -CurrentDirectory (Get-Location).Path -ScriptDirectory $script:ScriptDir
    foreach ($candidate in $candidates) {
        $info = Test-StriimInstallDir -Path $candidate
        if ($info.IsInstall) { & $addInstall $info $null }
    }

    # Layer 3: shallow drive-root scan (one level deep only)
    foreach ($root in $roots) {
        $dirs = @(Get-ChildItem -Path $root -Directory -Filter '*striim*' -ErrorAction SilentlyContinue)
        foreach ($d in $dirs) {
            $info = Test-StriimInstallDir -Path $d.FullName
            if ($info.IsInstall) { & $addInstall $info $null }
        }
    }

    # Fill in service state for installs found by path
    foreach ($install in $found) {
        if ($null -eq $install.ServiceState) {
            $artifacts = Get-ProfileArtifacts -NodeType $install.Type
            $svc = Get-Service -Name $artifacts.ServiceName -ErrorAction SilentlyContinue
            if ($svc) { $install.ServiceState = [string]$svc.Status } else { $install.ServiceState = 'not registered' }
        }
    }

    # Deduplicate: if path A is a proper ancestor of path B and both are the same install type,
    # drop A (the more specific child path is the real install root).
    # This prevents C:\striim from appearing alongside C:\striim\Agent as a second entry.
    $deduped = New-Object System.Collections.ArrayList
    foreach ($a in $found) {
        $aLower = $a.Path.TrimEnd('\').ToLowerInvariant()
        $dominated = $false
        foreach ($b in $found) {
            if ($a.Path -ieq $b.Path) { continue }
            $bLower = $b.Path.TrimEnd('\').ToLowerInvariant()
            if ($a.Type -eq $b.Type -and $bLower.StartsWith($aLower + '\')) {
                $dominated = $true; break
            }
        }
        if (-not $dominated) { [void]$deduped.Add($a) }
    }
    return @($deduped)
}

function Select-StriimInstall {
    param([Parameter(Mandatory)][object[]]$Installs)
    if (@($Installs).Count -eq 1) { return $Installs[0] }
    return Show-PickList -Title 'Multiple Striim installs found - pick one:' -Items $Installs -DisplayWith {
        param($i)
        $typeName = if ($i.Type -eq 'A') { 'Agent' } else { 'Node' }
        $ver = if ($i.Version) { $i.Version } else { 'unknown version' }
        '{0}  ({1}, {2}, service: {3})' -f $i.Path, $typeName, $ver, $i.ServiceState
    }
}

function Find-StriimConfigBackups {
    # Read-only scan of <fixed drive>:\striim_backups\*\ for completed config backups.
    # backup-manifest.txt is written LAST by Backup-StriimConfig, so its presence marks a
    # complete backup; the conf file must match the profile being installed (agent vs node).
    param([Parameter(Mandatory)][ValidateSet('A', 'N')][string]$NodeType)
    $artifacts = Get-ProfileArtifacts -NodeType $NodeType
    $found = New-Object System.Collections.ArrayList
    foreach ($root in @(Get-FixedDriveRoots)) {
        $backupRoot = Join-Path $root 'striim_backups'
        if (-not (Test-Path $backupRoot -PathType Container)) { continue }
        foreach ($dir in @(Get-ChildItem -Path $backupRoot -Directory -ErrorAction SilentlyContinue)) {
            $manifest = Join-Path $dir.FullName 'backup-manifest.txt'
            if (-not (Test-Path $manifest)) { continue }
            $confPath = Join-Path $dir.FullName $artifacts.ConfigFile
            if (-not (Test-Path $confPath)) { continue }
            [void]$found.Add([pscustomobject]@{
                Path        = $dir.FullName
                Name        = $dir.Name
                When        = $dir.LastWriteTime
                Source      = [string](Get-Content -Path $manifest -TotalCount 1)
                ConfigPath  = $confPath
                HasKeystore = (Test-Path (Join-Path $dir.FullName $artifacts.JksFile)) -and
                              (Test-Path (Join-Path $dir.FullName $artifacts.PwdFile))
                JarNames    = @(Get-ChildItem -Path (Join-Path $dir.FullName 'lib') -Filter '*.jar' -File -ErrorAction SilentlyContinue |
                                  ForEach-Object { $_.Name })
            })
        }
    }
    return @($found | Sort-Object When -Descending)
}
#endregion Detect

#region Interview
function Get-SystemSpecs {
    $ram = $null; $cores = $null
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs) { $ram = [math]::Round([double]$cs.TotalPhysicalMemory / 1GB, 2) }
    $procs = @(Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        $cores = 0
        foreach ($p in $procs) { $cores += $p.NumberOfCores }
    }
    return [pscustomobject]@{ Cores = $cores; RamGB = $ram }
}

function Get-DriveTable {
    $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction SilentlyContinue)
    $systemDrive = $env:SystemDrive
    return @($disks | ForEach-Object {
        [pscustomobject]@{
            Drive       = $_.DeviceID
            FreeGB      = [math]::Round([double]$_.FreeSpace / 1GB, 1)
            TotalGB     = [math]::Round([double]$_.Size / 1GB, 1)
            PercentFree = if ($_.Size) { [math]::Round(([double]$_.FreeSpace / [double]$_.Size) * 100, 1) } else { 0 }
            Note        = if ($_.DeviceID -ieq $systemDrive) { '(system)' } else { '' }
        }
    })
}

function Show-DriveTable {
    param([Parameter(Mandatory)][object[]]$Drives)
    Write-Host ''
    Write-Host ('{0,-7} {1,10} {2,10}   {3}' -f 'Drive', 'Free', 'Total', 'Note') -ForegroundColor Cyan
    foreach ($d in $Drives) {
        Write-Host ('{0,-7} {1,7} GB {2,7} GB   {3}' -f $d.Drive, $d.FreeGB, $d.TotalGB, $d.Note)
    }
}

function Show-SystemSnapshot {
    $specs = Get-SystemSpecs
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    Write-Host "`n--- System snapshot ---" -ForegroundColor Cyan
    Write-Host ('  OS:          {0}' -f $(if ($os) { $os.Caption } else { 'unknown' }))
    Write-Host ('  PowerShell:  {0}' -f $PSVersionTable.PSVersion)
    Write-Host ('  CPU cores:   {0}' -f $specs.Cores)
    Write-Host ('  RAM:         {0} GB' -f $specs.RamGB)
    Write-Host ''
    Write-Host '--- Striim agent requirements (for reference) ---' -ForegroundColor Cyan
    Write-Host '  Disk: 500 MB minimum; never let the drive drop below 10% free.'
    Write-Host '  RAM:  256 MB - 1 GB depending on adapters in use.'
    Write-Host '  CPU:  plan +1 core per 2 MSJet instances (N cores ~ 2N MSJet sources).'
    if ($specs.RamGB -and $specs.RamGB -lt 1) {
        Write-Log -Level Warn -Message 'This machine has less than 1 GB RAM - below the comfortable range for most adapters.'
    }
}

function Test-RemoteUrlExists {
    # HTTP HEAD - typo'd versions fail in ~1 second, not after a 10-minute download.
    param([Parameter(Mandatory)][string]$Uri)
    $client = $null
    try {
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(15)
        $request = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Head, $Uri)
        $response = $client.SendAsync($request).Result
        return [bool]$response.IsSuccessStatusCode
    } catch {
        return $false
    } finally {
        if ($client) { $client.Dispose() }
    }
}

function Read-StriimVersion {
    param([Parameter(Mandatory)][ValidateSet('A', 'N')][string]$NodeType)
    while ($true) {
        $raw = Read-Host -Prompt "Striim version to install [$script:DefaultStriimVersion]"
        if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $script:DefaultStriimVersion }
        $raw = $raw.Trim()
        $gate = Test-StriimVersionSupported -VersionString $raw
        if (-not $gate.Supported) {
            Write-Log -Level Warn -Message $gate.Reason
            continue
        }
        if ($gate.Warning) {
            Write-Log -Level Warn -Message $gate.Warning
            if (-not (Confirm-UserChoice -Prompt 'Continue with this early-5.0.x version anyway?' -DefaultChoice 'n')) { continue }
        }
        $mainEntry = $script:AllDownloads | Where-Object { $_.Category -eq 'MainInstaller' -and $_.NodeType -eq $NodeType } | Select-Object -First 1
        $resolved = Resolve-ManifestEntry -Entry $mainEntry -TargetVersion $raw
        Write-Log -Level Info -Message "Validating release URL: $($resolved.Url)"
        if (Test-RemoteUrlExists -Uri $resolved.Url) {
            Write-Log -Level Success -Message "Version $raw confirmed on the release server."
            return $raw
        }
        Write-Log -Level Warn -Message "Could not confirm $raw on the release server (typo, unreleased version, or no internet)."
        if (Confirm-UserChoice -Prompt 'Use this version anyway (e.g. offline with a pre-staged downloads\ bundle)?' -DefaultChoice 'n') {
            return $raw
        }
    }
}

function Resolve-InstallPathChoice {
    # Bare letter -> <letter>:\striim\Agent (Agent) or <letter>:\striim (Node); otherwise full rooted path.
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][ValidateSet('A', 'N')][string]$NodeType,
        [Parameter(Mandatory)][string]$DefaultPath
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return $DefaultPath }
    $trimmed = $Text.Trim()
    if ($trimmed -match '^([A-Za-z]):?$') {
        $letter = $Matches[1].ToUpper()
        $sub = (Get-ProfileArtifacts -NodeType $NodeType).DefaultSubPath
        return Join-Path "${letter}:\" $sub
    }
    if ($trimmed -match '^[A-Za-z]:\\') { return $trimmed }
    throw "Enter a drive letter (e.g. 'D') or a full path (e.g. 'D:\striim\Agent')."
}

function Read-InstallPath {
    param([Parameter(Mandatory)][ValidateSet('A', 'N')][string]$NodeType)
    $artifacts = Get-ProfileArtifacts -NodeType $NodeType
    $default = Join-Path "$env:SystemDrive\" $artifacts.DefaultSubPath
    $drives = @(Get-DriveTable)
    Show-DriveTable -Drives $drives
    while ($true) {
        $raw = Read-Host -Prompt "Install path [$default]  (pick a letter, e.g. 'D', or type a full path)"
        $resolved = $null
        try {
            $resolved = Resolve-InstallPathChoice -Text $raw -NodeType $NodeType -DefaultPath $default
        } catch {
            Write-Log -Level Warn -Message $_.Exception.Message
            continue
        }
        $letter = $resolved.Substring(0, 1).ToUpper()
        $info = $drives | Where-Object { $_.Drive -ieq "${letter}:" } | Select-Object -First 1
        if (-not $info) {
            Write-Log -Level Warn -Message "Drive ${letter}: is not a fixed local drive."
            continue
        }
        # The 500 MB / 10%-free check runs against the CHOSEN drive.
        if ($info.FreeGB -lt 0.5) {
            Write-Log -Level Warn -Message "Drive ${letter}: has under 500 MB free - below the Striim minimum."
            if (-not (Confirm-UserChoice -Prompt 'Continue anyway?' -DefaultChoice 'n')) { continue }
        } elseif ($info.PercentFree -lt 10) {
            Write-Log -Level Warn -Message "Drive ${letter}: is under 10% free - Striim must never drop below 10% free disk."
            if (-not (Confirm-UserChoice -Prompt 'Continue anyway?' -DefaultChoice 'n')) { continue }
        }
        if ($NodeType -eq 'N' -and $info.FreeGB -lt 15) {
            Write-Log -Level Warn -Message 'Node installs: 15 GB free is recommended (advisory - not blocking).'
        }
        return $resolved
    }
}

$script:JdbcDriverCatalog = @(
    [pscustomobject]@{ Key = 'mariadb';  Label = 'MariaDB (v2.4.3)';                                          Kind = 'Download'; ManifestName = 'mariadb-java-client-2.4.3.jar';                      RequiredFiles = @();                                    PathIsDirectory = $false }
    [pscustomobject]@{ Key = 'mysql';    Label = 'MySQL / MemSQL (Connector/J 8.0.30)';                       Kind = 'Download'; ManifestName = 'mysql-connector-j-8.0.30.zip';                       RequiredFiles = @();                                    PathIsDirectory = $false }
    [pscustomobject]@{ Key = 'oracle';   Label = 'Oracle Instant Client (for OJet)';                          Kind = 'Download'; ManifestName = 'instantclient-basic-windows.x64-21.6.0.0.0dbru.zip'; RequiredFiles = @();                                    PathIsDirectory = $false }
    [pscustomobject]@{ Key = 'postgres'; Label = 'PostgreSQL (v42.2.27)';                                     Kind = 'Download'; ManifestName = 'postgresql-42.2.27.jar';                             RequiredFiles = @();                                    PathIsDirectory = $false }
    [pscustomobject]@{ Key = 'nonstop';  Label = 'HP NonStop (manual path to t4sqlmx.jar)';                   Kind = 'Manual';   ManifestName = $null;                                               RequiredFiles = @('t4sqlmx.jar');                       PathIsDirectory = $false }
    [pscustomobject]@{ Key = 'teradata'; Label = 'Teradata (manual dir with terajdbc4.jar + tdgssconfig.jar)'; Kind = 'Manual';  ManifestName = $null;                                               RequiredFiles = @('terajdbc4.jar', 'tdgssconfig.jar'); PathIsDirectory = $true }
    [pscustomobject]@{ Key = 'vertica';  Label = 'Vertica (manual path to vertica-jdbc-*.jar)';               Kind = 'Manual';   ManifestName = $null;                                               RequiredFiles = @('vertica-jdbc-*.jar');                PathIsDirectory = $false }
)

function Test-ClusterReachability {
    # servernode.address may be a comma-separated list (HA clusters) - reachable when ANY
    # listed address answers on the auth port. Raw TcpClient with a 5 s cap per address:
    # Test-NetConnection has no timeout and hangs ~21 s+ per unreachable host.
    param(
        [Parameter(Mandatory)][string]$ServerAddress,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 5000
    )
    foreach ($addr in @($ServerAddress -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $task = $client.ConnectAsync($addr, $Port)
            if ($task.Wait($TimeoutMs) -and $client.Connected) { return $true }
        } catch {
            # Connection refused / DNS failure surfaces as AggregateException - just not reachable.
        } finally {
            $client.Dispose()
        }
    }
    return $false
}

function Read-ClusterSettings {
    # Optional -Defaults (from a prior config backup or the live config) prefill the
    # prompts; Enter accepts the bracketed value, typing replaces it.
    param([object]$Defaults = $null)
    $defCluster = if ($Defaults) { [string]$Defaults.ClusterName } else { '' }
    $defServer  = if ($Defaults) { [string]$Defaults.ServerAddress } else { '' }
    $defHttps   = if ($Defaults -and -not $Defaults.HttpsEnabled) { 'n' } else { 'y' }
    $clusterName = ''
    while ([string]::IsNullOrWhiteSpace($clusterName)) { $clusterName = Read-PromptWithDefault -Prompt 'Cluster name' -Default $defCluster }
    $serverAddress = ''
    while ([string]::IsNullOrWhiteSpace($serverAddress)) { $serverAddress = Read-PromptWithDefault -Prompt 'Striim server node address (hostname or IP)' -Default $defServer }
    $https = Confirm-UserChoice -Prompt 'Is HTTPS enabled on the cluster?' -DefaultChoice $defHttps
    $port = if ($https) { 9081 } else { 9080 }
    # Immediate, non-blocking reachability probe - surface firewall problems NOW.
    $reachable = Test-ClusterReachability -ServerAddress $serverAddress.Trim() -Port $port
    if ($reachable) {
        Write-Log -Level Success -Message "Cluster auth port $port on $serverAddress is reachable."
    } else {
        Write-Log -Level Warn -Message "Cannot reach $serverAddress on auth port $port from this host right now. Fix your firewall/VPN - you can continue anyway. (FYI for your network team: the agent also needs inbound TCP 5701 (Hazelcast) and outbound TCP 49152-65535.)"
    }
    return [pscustomobject]@{
        ClusterName   = $clusterName.Trim()
        ServerAddress = $serverAddress.Trim()
        HttpsEnabled  = $https
        AuthPort      = $port
        Reachable     = $reachable
    }
}

function Read-ManualDriverPath {
    # Validated immediately at interview time (spec 2.2.8) - not at execute time.
    param([Parameter(Mandatory)][object]$Driver)
    while ($true) {
        $what = if ($Driver.PathIsDirectory) { 'directory containing' } else { 'full path to' }
        $raw = Read-Host -Prompt ("[{0}] Enter the {1} {2} (or 'skip')" -f $Driver.Label, $what, ($Driver.RequiredFiles -join ' + '))
        if ($raw.Trim().ToLower() -eq 'skip') { return $null }
        $candidate = $raw.Trim().Trim('"')
        if ($Driver.PathIsDirectory) {
            $allFound = $true
            foreach ($req in $Driver.RequiredFiles) {
                if (-not (Test-Path (Join-Path $candidate $req))) { $allFound = $false }
            }
            if ($allFound) { return $candidate }
            Write-Log -Level Warn -Message "Could not find $($Driver.RequiredFiles -join ' and ') in '$candidate'."
        } else {
            $pattern = $Driver.RequiredFiles[0]
            if ((Test-Path $candidate -PathType Leaf) -and ((Split-Path $candidate -Leaf) -like $pattern)) { return $candidate }
            Write-Log -Level Warn -Message "'$candidate' does not exist or does not match $pattern."
        }
    }
}

function Read-JdbcDriverSelection {
    # One multi-select checklist replaces the OG loop-menu.
    Write-Host "`nJDBC drivers to install into lib\:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $script:JdbcDriverCatalog.Count; $i++) {
        Write-Host ('  [{0}] {1}' -f ($i + 1), $script:JdbcDriverCatalog[$i].Label)
    }
    $indexes = @()
    while ($true) {
        $raw = Read-Host -Prompt "Select drivers (e.g. '1,4'), 'all', or Enter for none"
        try {
            $indexes = ConvertTo-SelectionIndexes -Text $raw -OptionCount $script:JdbcDriverCatalog.Count
            break
        } catch {
            Write-Log -Level Warn -Message $_.Exception.Message
        }
    }
    $selection = New-Object System.Collections.ArrayList
    foreach ($idx in $indexes) {
        $driver = $script:JdbcDriverCatalog[$idx - 1]
        $manualPath = $null
        if ($driver.Kind -eq 'Manual') {
            $manualPath = Read-ManualDriverPath -Driver $driver
            if ($null -eq $manualPath) {
                Write-Log -Level Info -Message "Skipping $($driver.Label)."
                continue
            }
        }
        [void]$selection.Add([pscustomobject]@{
            Key = $driver.Key; Label = $driver.Label; Kind = $driver.Kind
            ManifestName = $driver.ManifestName; ManualPath = $manualPath
        })
    }
    return @($selection)
}

function Read-OptionalSecurePassword {
    param([Parameter(Mandatory)][string]$Prompt)
    Write-Host "$Prompt (press Enter to skip)" -ForegroundColor Yellow
    $secure = Read-Host -AsSecureString
    if ($secure.Length -eq 0) { return $null }
    return $secure
}

function Read-NodeLicenseSettings {
    # Node profile only: startUp.properties required props the Agent flow never needs.
    # Optional -Defaults (from a prior config backup) prefill each prompt.
    param([System.Collections.IDictionary]$Defaults = $null)
    $values = [ordered]@{}
    foreach ($prop in @('CompanyName', 'LicenceKey', 'ProductKey')) {
        $def = if ($Defaults -and $Defaults.Contains($prop)) { [string]$Defaults[$prop] } else { '' }
        $v = ''
        while ([string]::IsNullOrWhiteSpace($v)) { $v = Read-PromptWithDefault -Prompt "$prop (required for Node)" -Default $def }
        $values[$prop] = $v.Trim()
    }
    return $values
}

function Get-BackupConfigDefaults {
    # Interview default values held in a backed-up (or live) config file.
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][ValidateSet('A', 'N')][string]$NodeType
    )
    if ($NodeType -eq 'A') {
        return [pscustomobject]@{
            ClusterName   = [string](Get-ConfigProperty -ConfigPath $ConfigPath -PropertyName 'striim.cluster.clusterName')
            ServerAddress = [string](Get-ConfigProperty -ConfigPath $ConfigPath -PropertyName 'striim.node.servernode.address')
            HttpsEnabled  = ((Get-ConfigProperty -ConfigPath $ConfigPath -PropertyName 'striim.cluster.https.enabled') -ne 'false')
            MemMax        = [string](Get-ConfigProperty -ConfigPath $ConfigPath -PropertyName 'MEM_MAX')
            MemMin        = [string](Get-ConfigProperty -ConfigPath $ConfigPath -PropertyName 'MEM_MIN')
            NodeLicense   = $null
        }
    }
    $license = [ordered]@{}
    foreach ($prop in @('CompanyName', 'LicenceKey', 'ProductKey')) {
        $v = [string](Get-ConfigProperty -ConfigPath $ConfigPath -PropertyName $prop)
        if (-not [string]::IsNullOrWhiteSpace($v)) { $license[$prop] = $v }
    }
    return [pscustomobject]@{
        ClusterName   = [string](Get-ConfigProperty -ConfigPath $ConfigPath -PropertyName 'WAClusterName')
        ServerAddress = ''
        HttpsEnabled  = $true
        MemMax        = [string](Get-ConfigProperty -ConfigPath $ConfigPath -PropertyName 'MEM_MAX')
        MemMin        = [string](Get-ConfigProperty -ConfigPath $ConfigPath -PropertyName 'MEM_MIN')
        NodeLicense   = $license
    }
}

function Select-StriimConfigBackup {
    # Prior uninstall/reinstall/upgrade backups (spec 2.7) seed a new install: cluster settings
    # become interview defaults; keystore + log4j config + non-default jars are restored after extraction.
    param([Parameter(Mandatory)][ValidateSet('A', 'N')][string]$NodeType)
    $backups = @(Find-StriimConfigBackups -NodeType $NodeType)
    if ($backups.Count -eq 0) {
        Write-Log -Level Info -Message 'No prior config backups found (searched <drive>:\striim_backups\ on all fixed drives).'
        return $null
    }
    $fresh = [pscustomobject]@{
        Path = $null; Name = '(none - answer everything fresh)'; When = $null
        Source = ''; ConfigPath = $null; HasKeystore = $false; JarNames = @()
    }
    $picked = Show-PickList -Title 'Prior Striim config backups found under striim_backups\ - restore settings from one?' `
        -Items (@($backups) + @($fresh)) -DisplayWith {
        param($b)
        if ($null -eq $b.Path) { return $b.Name }
        $parts = @('config')
        if ($b.HasKeystore) { $parts += 'keystore' }
        if (@($b.JarNames).Count -gt 0) { $parts += "$(@($b.JarNames).Count) extra jar(s)" }
        '{0}  ({1})  {2}' -f $b.Name, ($parts -join ' + '), $b.Source
    }
    if ($null -eq $picked.Path) { return $null }
    return $picked
}

function Read-InstallInterview {
    # All user decisions, collected once, in spec 2.2 order. No admin required.
    Show-SystemSnapshot
    $profile = Show-PickList -Title 'Install profile:' -Items @(
        [pscustomobject]@{ NodeType = 'A'; Label = 'Striim Forwarding Agent (default)' },
        [pscustomobject]@{ NodeType = 'N'; Label = 'Striim Node' }
    ) -DisplayWith { param($i) $i.Label }
    $nodeType = $profile.NodeType
    $targetVersion = Read-StriimVersion -NodeType $nodeType
    $installPath = Read-InstallPath -NodeType $nodeType
    $restoreBackup = Select-StriimConfigBackup -NodeType $nodeType
    $backupDefaults = $null
    if ($restoreBackup) { $backupDefaults = Get-BackupConfigDefaults -ConfigPath $restoreBackup.ConfigPath -NodeType $nodeType }
    $cluster = Read-ClusterSettings -Defaults $backupDefaults
    # The keystore is bound to its cluster: restore it only while the cluster name still matches.
    $restoreKeystore = $false
    if ($restoreBackup -and $restoreBackup.HasKeystore) {
        if ($cluster.ClusterName -eq [string]$backupDefaults.ClusterName) {
            $restoreKeystore = $true
        } else {
            Write-Log -Level Warn -Message "Cluster name differs from the backup's ('$($backupDefaults.ClusterName)') - the backed-up keystore belongs to that cluster and will NOT be restored; a new one will be generated."
        }
    }
    $nodeLicense = $null
    if ($nodeType -eq 'N') {
        $licenseDefaults = if ($backupDefaults) { $backupDefaults.NodeLicense } else { $null }
        $nodeLicense = Read-NodeLicenseSettings -Defaults $licenseDefaults
    }
    $memMaxDefault = if ($backupDefaults) { [string]$backupDefaults.MemMax } else { '' }
    $memMax = (Read-PromptWithDefault -Prompt 'MEM_MAX tuning value (e.g. 2048m; Enter to skip)' -Default $memMaxDefault).Trim()
    $memMin = if ($backupDefaults) { [string]$backupDefaults.MemMin } else { '' }
    $integratedSecurity = Confirm-UserChoice -Prompt 'Use SQL Server Integrated Security (NT auth, places sqljdbc_auth.dll in System32)?' -DefaultChoice 'n'
    $drivers = @()
    if ($nodeType -eq 'A') {
        if ($restoreBackup -and @($restoreBackup.JarNames).Count -gt 0) {
            Write-Log -Level Info -Message "Backed-up driver jars ($(@($restoreBackup.JarNames) -join ', ')) will be restored automatically - select below only drivers you want ADDED or refreshed."
        }
        $drivers = Read-JdbcDriverSelection
    }
    $installService = Confirm-UserChoice -Prompt 'Register Striim as a Windows service?' -DefaultChoice 'y'
    $keystorePassword = $null; $sysPassword = $null
    if ($restoreKeystore) {
        Write-Log -Level Info -Message 'Keystore will be restored from the backup - skipping the keystore password prompts.'
    } else {
        Write-Host "`nKeystore setup (optional - skip either to do keystore config interactively at the end):" -ForegroundColor Cyan
        $keystorePassword = Read-OptionalSecurePassword -Prompt 'Agent keystore password'
        $sysPassword = Read-OptionalSecurePassword -Prompt "Cluster 'sys' user password"
    }
    return [pscustomobject]@{
        NodeType           = $nodeType
        Version            = $targetVersion
        InstallPath        = $installPath
        ClusterName        = $cluster.ClusterName
        ServerAddress      = $cluster.ServerAddress
        HttpsEnabled       = $cluster.HttpsEnabled
        AuthPort           = $cluster.AuthPort
        ClusterReachable   = $cluster.Reachable
        NodeLicense        = $nodeLicense
        MemMax             = $memMax
        MemMin             = $memMin
        IntegratedSecurity = $integratedSecurity
        Drivers            = @($drivers)
        InstallService     = $installService
        KeystorePassword   = $keystorePassword
        SysPassword        = $sysPassword
        RestoreFrom        = $(if ($restoreBackup) { $restoreBackup.Path } else { $null })
        RestoreKeystore    = $restoreKeystore
    }
}
#endregion Interview

#region Plan
function ConvertTo-PlainText {
    param([Parameter(Mandatory)][securestring]$Secure)
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function New-InstallPlan {
    # Pure: derives the "will do" card from interview answers PLUS probe results.
    # Only missing things get install actions; present things become "verify only" or are omitted.
    param(
        [Parameter(Mandatory)][object]$Interview,
        [Parameter(Mandatory)][object]$Probes,
        [ValidateSet('Install', 'Drivers', 'Reconfigure', 'Reinstall', 'Upgrade', 'Service')][string]$Mode = 'Install',
        # Pre-removal backup decision (Reinstall/Upgrade) - built by New-ConfigBackupChoice.
        [object]$Backup = $null
    )
    $artifacts = Get-ProfileArtifacts -NodeType $Interview.NodeType
    $mainZip = "Striim_$(if ($Interview.NodeType -eq 'A') { 'Agent_' })$($Interview.Version).zip"
    $actions = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $needs = [pscustomobject]@{
        Java17   = (-not $Probes.Java17Resolvable)
        VcRedist = (-not $Probes.VcRedistInstalled)
        OleDb    = (-not $Probes.OleDb.Present)
    }
    $cachedNote = if ($Probes.CachedFiles -contains $mainZip) { 'cached: yes' } else { 'cached: no' }
    $add = { param($desc) [void]$actions.Add([pscustomobject]@{ Order = $actions.Count + 1; Description = $desc }) }

    if ($Mode -in @('Install', 'Reinstall', 'Upgrade')) {
        if ($Backup -and $Backup.DoBackup) {
            & $add "Back up config, keystore, log4j, and non-default jars -> $($Backup.BackupDir)"
        }
        if ($Mode -eq 'Upgrade') {
            & $add "Stop + deregister '$($artifacts.ServiceName)' service (the wrapper is version-specific)"
        }
        if ($Mode -in @('Reinstall', 'Upgrade')) {
            & $add "Clean existing files under $($Interview.InstallPath) (preserving downloads\ and scripts)"
        }
        & $add "Download $mainZip  ($cachedNote)"
        if ($needs.Java17) { & $add 'Download + silently install Microsoft Build of OpenJDK 17  (missing)' }
        else { & $add 'Verify Java 17 (already resolvable)  (present)' }
        if ($needs.VcRedist) { & $add 'Install Visual C++ 2015-2019 Redistributable x64 14.29 (MSJet requires the 2015-2019 line)  (missing)' }
        if ($needs.OleDb) { & $add 'Install Microsoft OLE DB Driver for SQL Server  (missing)' }
        else { & $add "Verify MS OLE DB Driver $($Probes.OleDb.Version)  (present)" }
        & $add "Extract $($artifacts.ProfileName) -> $($Interview.InstallPath)"
        if ($Interview.IntegratedSecurity) { & $add "Place sqljdbc_auth.dll into C:\Windows\System32 (from Striim's lib\)" }
        & $add "Add $($Interview.InstallPath)\lib to the system PATH"
        $httpsLabel = if ($Interview.HttpsEnabled) { 'HTTPS' } else { 'HTTP' }
        & $add "Write $($artifacts.ConfigFile) (cluster=$($Interview.ClusterName), server=$($Interview.ServerAddress), $httpsLabel)"
        if ($Interview.RestoreFrom) {
            $restoreWhat = if ($Interview.RestoreKeystore) { 'keystore, log4j config, and non-default jars' } else { 'log4j config and non-default jars' }
            & $add "Restore $restoreWhat from $($Interview.RestoreFrom)"
        }
        if (@($Interview.Drivers).Count -gt 0) {
            & $add "Install JDBC drivers: $(@($Interview.Drivers | ForEach-Object { $_.Label }) -join ', ')"
        }
        if ($Interview.InstallService) { & $add "Register '$($artifacts.ServiceName)' Windows service" }
        $pwNote = if ($Interview.RestoreKeystore) { 'restored from backup - generation will be skipped' }
                  elseif ($Interview.KeystorePassword -and $Interview.SysPassword) { 'passwords provided' }
                  else { 'interactive at the end' }
        & $add "Generate keystore via $(Split-Path $artifacts.KeystoreScript -Leaf)  ($pwNote)"
    } elseif ($Mode -eq 'Drivers') {
        & $add "Install JDBC drivers: $(@($Interview.Drivers | ForEach-Object { $_.Label }) -join ', ')"
        & $add "Restart '$($artifacts.ServiceName)' service if registered"
    } elseif ($Mode -eq 'Reconfigure') {
        & $add "Rewrite $($artifacts.ConfigFile) (cluster=$($Interview.ClusterName), server=$($Interview.ServerAddress))"
        & $add "Restart '$($artifacts.ServiceName)' service if registered"
    }

    if (-not $Interview.ClusterReachable) {
        [void]$warnings.Add("cluster auth port $($Interview.AuthPort) on $($Interview.ServerAddress) was unreachable from this host")
    }
    if ($Interview.IntegratedSecurity) {
        $dllPreInstall = @(
            (Join-Path $script:ScriptDir 'sqljdbc_auth.dll'),
            (Join-Path $script:DownloadDir 'sqljdbc_auth.dll')
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $dllPreInstall) {
            [void]$warnings.Add("sqljdbc_auth.dll not found next to the script or in downloads\ - the step will also check Striim's lib\ after extraction, but place the DLL next to this script now to be safe")
        }
    }
    if ($Probes.OleDb.Present -and -not $Probes.OleDb.KnownGood) {
        [void]$warnings.Add("OLE DB Driver $($Probes.OleDb.Version) is installed but not in the known-good list ($($script:KnownGoodOleDbVersions -join ', ')) - proceeding anyway")
    }
    return [pscustomobject]@{
        PlanFormatVersion = 1
        Mode              = $Mode
        CreatedUtc        = (Get-Date).ToUniversalTime().ToString('o')
        Interview         = $Interview
        Needs             = $needs
        Actions           = @($actions)
        Warnings          = @($warnings)
        Backup            = $Backup
    }
}

function Show-PlanReview {
    param([Parameter(Mandatory)][object]$Plan)
    $artifacts = Get-ProfileArtifacts -NodeType $Plan.Interview.NodeType
    Write-Host ''
    Write-Host ('+' + ('-' * 72)) -ForegroundColor Cyan
    Write-Host ("| {0} PLAN - Striim {1} {2} -> {3}" -f $Plan.Mode.ToUpper(), $artifacts.ProfileName, $Plan.Interview.Version, $Plan.Interview.InstallPath) -ForegroundColor White
    foreach ($action in $Plan.Actions) {
        Write-Host ('| {0,2}. {1}' -f $action.Order, $action.Description)
    }
    foreach ($warning in $Plan.Warnings) {
        Write-Host ("| Warning: $warning") -ForegroundColor Yellow
    }
    Write-Host ('+' + ('-' * 72)) -ForegroundColor Cyan
}

function ConvertTo-PlanDocument {
    # Serializable copy: SecureStrings -> DPAPI strings (user-scoped; readable only by the
    # same user's elevated process, useless to anyone else or any other machine).
    param([Parameter(Mandatory)][object]$Plan)
    $iv = $Plan.Interview
    $ksEnc = $null; $sysEnc = $null
    if ($iv.KeystorePassword) { $ksEnc = ConvertFrom-SecureString -SecureString $iv.KeystorePassword }
    if ($iv.SysPassword) { $sysEnc = ConvertFrom-SecureString -SecureString $iv.SysPassword }
    $interviewDoc = [pscustomobject]@{
        NodeType = $iv.NodeType; Version = $iv.Version; InstallPath = $iv.InstallPath
        ClusterName = $iv.ClusterName; ServerAddress = $iv.ServerAddress
        HttpsEnabled = $iv.HttpsEnabled; AuthPort = $iv.AuthPort; ClusterReachable = $iv.ClusterReachable
        NodeLicense = $iv.NodeLicense; MemMax = $iv.MemMax; MemMin = $iv.MemMin; IntegratedSecurity = $iv.IntegratedSecurity
        Drivers = @($iv.Drivers); InstallService = $iv.InstallService
        KeystorePasswordEnc = $ksEnc; SysPasswordEnc = $sysEnc
        RestoreFrom = $iv.RestoreFrom; RestoreKeystore = [bool]$iv.RestoreKeystore
    }
    $uninstallDoc = if ($Plan.PSObject.Properties['Uninstall']) { $Plan.Uninstall } else { $null }
    $backupDoc = if ($Plan.PSObject.Properties['Backup']) { $Plan.Backup } else { $null }
    $serviceDoc = if ($Plan.PSObject.Properties['Service']) { $Plan.Service } else { $null }
    return [pscustomobject]@{
        PlanFormatVersion = $Plan.PlanFormatVersion; Mode = $Plan.Mode; CreatedUtc = $Plan.CreatedUtc
        Interview = $interviewDoc; Needs = $Plan.Needs; Actions = @($Plan.Actions); Warnings = @($Plan.Warnings)
        Uninstall = $uninstallDoc; Backup = $backupDoc; Service = $serviceDoc
    }
}

function ConvertFrom-PlanDocument {
    param([Parameter(Mandatory)][object]$Document)
    $iv = $Document.Interview
    $ks = $null; $sys = $null
    if ($iv.KeystorePasswordEnc) { $ks = ConvertTo-SecureString -String $iv.KeystorePasswordEnc }
    if ($iv.SysPasswordEnc) { $sys = ConvertTo-SecureString -String $iv.SysPasswordEnc }
    $interview = [pscustomobject]@{
        NodeType = $iv.NodeType; Version = $iv.Version; InstallPath = $iv.InstallPath
        ClusterName = $iv.ClusterName; ServerAddress = $iv.ServerAddress
        HttpsEnabled = [bool]$iv.HttpsEnabled; AuthPort = [int]$iv.AuthPort; ClusterReachable = [bool]$iv.ClusterReachable
        NodeLicense = $iv.NodeLicense; MemMax = $iv.MemMax; MemMin = $iv.MemMin; IntegratedSecurity = [bool]$iv.IntegratedSecurity
        Drivers = @($iv.Drivers); InstallService = [bool]$iv.InstallService
        KeystorePassword = $ks; SysPassword = $sys
        RestoreFrom = $iv.RestoreFrom; RestoreKeystore = [bool]$iv.RestoreKeystore
    }
    $uninstall = if ($Document.PSObject.Properties['Uninstall']) { $Document.Uninstall } else { $null }
    $backup = if ($Document.PSObject.Properties['Backup']) { $Document.Backup } else { $null }
    $service = if ($Document.PSObject.Properties['Service']) { $Document.Service } else { $null }
    return [pscustomobject]@{
        PlanFormatVersion = $Document.PlanFormatVersion; Mode = $Document.Mode; CreatedUtc = $Document.CreatedUtc
        Interview = $interview; Needs = $Document.Needs; Actions = @($Document.Actions); Warnings = @($Document.Warnings)
        Uninstall = $uninstall; Backup = $backup; Service = $service
    }
}

function Save-PlanFile {
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$Path
    )
    ConvertTo-PlanDocument -Plan $Plan | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding UTF8
}

function Read-PlanFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "Plan file not found: $Path" }
    $doc = Get-Content -Raw -Path $Path | ConvertFrom-Json
    return ConvertFrom-PlanDocument -Document $doc
}

function Invoke-ElevatedExecution {
    # The single UAC prompt. The elevated process skips straight to Execute via -PlanFile.
    param([Parameter(Mandatory)][string]$PlanPath)
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -PlanFile "{1}"' -f $script:ScriptPath, $PlanPath
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -PassThru
    $process.WaitForExit()
    return $process.ExitCode
}
#endregion Plan

#region ExecuteSteps
function Get-PlanDownloadList {
    # Everything this plan needs from the network, resolved against the manifest.
    param([Parameter(Mandatory)][object]$Plan)
    $iv = $Plan.Interview
    $all = Get-ManifestFiles -NodeType $iv.NodeType -TargetVersion $iv.Version
    $wanted = New-Object System.Collections.ArrayList
    if ($Plan.Mode -eq 'Drivers') {
        # Maintenance "Add drivers" needs only the selected driver jars - never the install bundle.
        foreach ($f in $all) {
            if ($f.Category -eq 'Driver' -and @($iv.Drivers | Where-Object { $_.ManifestName -eq $f.Name }).Count -gt 0) {
                [void]$wanted.Add($f)
            }
        }
        return @($wanted)
    }
    foreach ($f in $all) {
        $include = switch ($f.Category) {
            'MainInstaller'   { $true }
            'ServiceInstaller' { [bool]$iv.InstallService }
            'Java'            { [bool]$Plan.Needs.Java17 }
            'Patch'           { $true }
            'Prereq'          {
                if ($f.Name -eq 'vc_redist.x64.exe') { [bool]$Plan.Needs.VcRedist }
                elseif ($f.Name -eq 'msoledbsql.msi') { [bool]$Plan.Needs.OleDb }
                else { $false }
            }
            'Driver'          { @($iv.Drivers | Where-Object { $_.ManifestName -eq $f.Name }).Count -gt 0 }
            default           { $false }
        }
        if ($include) { [void]$wanted.Add($f) }
    }
    return @($wanted)
}

function New-DownloadBatchStep {
    # One critical step: all downloads run as a single batch immediately after plan approval
    # (approval was the consent - no per-file prompts).
    param([Parameter(Mandatory)][object]$Plan)
    $files = Get-PlanDownloadList -Plan $Plan
    # GetNewClosure() binds the block to a fresh dynamic module where $script: resolves to
    # an EMPTY module scope (field bug: Join-Path got a null Path) - capture locals instead.
    $downloadDir = $script:DownloadDir
    return New-InstallStep -Name "Download required files ($(@($files).Count) item(s))" -Critical -Test {
        $missing = @($files | Where-Object { -not (Test-Path (Join-Path $downloadDir $_.Name)) })
        $missing.Count -eq 0
    }.GetNewClosure() -Action {
        foreach ($f in $files) {
            $target = Join-Path $downloadDir $f.Name
            if (-not (Get-RemoteFile -Uri $f.Url -OutFile $target -Sha256 $f.Sha256)) {
                throw "Failed to download $($f.Name) from $($f.Url)"
            }
        }
    }.GetNewClosure()
}

function Get-JavaMajorVersion {
    param([AllowEmptyString()][string]$VersionString)
    if ([string]::IsNullOrWhiteSpace($VersionString)) { return 0 }
    if ($VersionString -match '^1\.(\d+)') { return [int]$Matches[1] }   # legacy 1.8.0_x -> 8
    if ($VersionString -match '^(\d+)') { return [int]$Matches[1] }      # modern 17.0.x -> 17
    return 0
}

function Get-JavaVersionFromOutput {
    param([Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Output)
    foreach ($line in $Output) {
        if ($line -match 'version "([^"]+)"') { return $Matches[1] }
    }
    return $null
}

function Get-JavaVersionProbeOutput {
    # 'java -version' prints its banner to STDERR. Under this script's
    # $ErrorActionPreference = 'Stop', a 2>&1 merge turns the first stderr line into a
    # TERMINATING NativeCommandError on Windows PowerShell 5.1 - the banner itself became
    # the step-failure message (field bug: "[ERROR] openjdk version ..."). Probe with EAP
    # relaxed and unwrap ErrorRecords back into plain text.
    param([Parameter(Mandatory)][string]$JavaExe)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        return @(& $JavaExe -version 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
        })
    } catch {
        return @()
    } finally {
        $ErrorActionPreference = $old
    }
}

function Find-JavaInstallations {
    # PATH + JAVA_HOME + JDK registry keys. The old draft only checked PATH - insufficient.
    $findings = New-Object System.Collections.ArrayList
    # 1) PATH
    $javaCmd = Get-Command java -ErrorAction SilentlyContinue
    if ($javaCmd) {
        $versionString = Get-JavaVersionFromOutput -Output @(Get-JavaVersionProbeOutput -JavaExe $javaCmd.Source)
        if ($versionString) {
            [void]$findings.Add([pscustomobject]@{ Source = 'PATH'; Version = $versionString; Major = (Get-JavaMajorVersion -VersionString $versionString); Path = $javaCmd.Source })
        }
    }
    # 2) JAVA_HOME
    if ($env:JAVA_HOME) {
        $javaExe = Join-Path $env:JAVA_HOME 'bin\java.exe'
        if (Test-Path $javaExe) {
            $versionString = Get-JavaVersionFromOutput -Output @(Get-JavaVersionProbeOutput -JavaExe $javaExe)
            if ($versionString) {
                [void]$findings.Add([pscustomobject]@{ Source = 'JAVA_HOME'; Version = $versionString; Major = (Get-JavaMajorVersion -VersionString $versionString); Path = $env:JAVA_HOME })
            }
        }
    }
    # 3) Registry (Microsoft JDK, Eclipse Adoptium, JavaSoft)
    foreach ($regRoot in @('HKLM:\SOFTWARE\Microsoft\JDK', 'HKLM:\SOFTWARE\Eclipse Adoptium\JDK', 'HKLM:\SOFTWARE\JavaSoft\JDK', 'HKLM:\SOFTWARE\JavaSoft\Java Development Kit')) {
        if (Test-Path $regRoot) {
            foreach ($child in @(Get-ChildItem -Path $regRoot -ErrorAction SilentlyContinue)) {
                [void]$findings.Add([pscustomobject]@{ Source = 'Registry'; Version = $child.PSChildName; Major = (Get-JavaMajorVersion -VersionString $child.PSChildName); Path = $regRoot })
            }
        }
    }
    return ,@($findings)
}

function Test-Java17Resolvable {
    # Pass when a JDK 17 is resolvable by the agent: PATH or JAVA_HOME (registry alone is not enough).
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)
    return @($Findings | Where-Object { $_.Major -eq 17 -and $_.Source -in @('PATH', 'JAVA_HOME') }).Count -gt 0
}

function Update-SessionEnvironment {
    # Re-read machine env into this session so Verify reports the truth without "restart your terminal".
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machinePath, $userPath) | Where-Object { $_ }) -join ';'
    $javaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine')
    if ($javaHome) { $env:JAVA_HOME = $javaHome }
}

function Install-Java17 {
    # Microsoft Build of OpenJDK 17 MSI, fully silent. FeatureEnvironment + FeatureJavaHome set
    # PATH and JAVA_HOME machine-wide with no clicking.
    $msiPath = Join-Path $script:DownloadDir 'microsoft-jdk-17-windows-x64.msi'
    if (-not (Test-Path $msiPath)) { throw "Java MSI not found at $msiPath (download step should have fetched it)." }
    $msiArgs = '/i "{0}" /qn ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJavaHome' -f $msiPath
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru
    $meaning = Get-ExitCodeMeaning -Code $process.ExitCode
    if ($meaning.Result -eq 'Fail') {
        $hint = if ($meaning.Hint) { " $($meaning.Hint)" } else { '' }
        throw "Java 17 MSI failed: $($meaning.Message).$hint"
    }
    if ($meaning.Result -eq 'PassWithWarning') { Write-Log -Level Warn -Message "Java 17: $($meaning.Message). $($meaning.Hint)" }
    Update-SessionEnvironment
}

function Show-JavaCoexistenceWarning {
    # If another Java (8/11) sits earlier on PATH, say exactly which Java the agent will resolve.
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)
    $pathJava = $Findings | Where-Object { $_.Source -eq 'PATH' } | Select-Object -First 1
    if ($pathJava -and $pathJava.Major -ne 17) {
        $era = if ($pathJava.Major -eq 11) { ' (Java 11 - an early-5.0.x leftover; the Java-17 line is required)' } else { '' }
        Write-Log -Level Warn -Message "PATH resolves java to $($pathJava.Version)$era at $($pathJava.Path). The agent will use whatever 'java' resolves first; ensure JAVA_HOME points at JDK 17 or reorder PATH so JDK 17 wins."
    }
}

function New-Java17Step {
    param([Parameter(Mandatory)][object]$Plan)
    return New-InstallStep -Name 'Java 17 (Microsoft Build of OpenJDK)' -Critical -Test {
        $findings = Find-JavaInstallations
        Test-Java17Resolvable -Findings $findings
    } -Action {
        $before = Find-JavaInstallations
        foreach ($f in $before) { Write-Log -Level Info -Message "Found Java: $($f.Version) via $($f.Source) ($($f.Path))" }
        Install-Java17
        Show-JavaCoexistenceWarning -Findings (Find-JavaInstallations)
    }
}

function Test-VcRedistInstalled {
    # Registry, not WMI: instant and side-effect-free (Win32_Product triggers MSI repair storms).
    # MSJet wants the VC++ 2015-2019 runtime line, >= 14.28.29914 (OG checker's pin). The 14.x
    # runtime upgrades in place, so a 2015-2022 (14.30+) install REPLACES 2015-2019 and the
    # 2015-2019 installer refuses to downgrade - warn but PASS in that case (warn, not block,
    # same policy as the OLE DB known-good check).
    $key = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
    try {
        $props = Get-ItemProperty -Path $key -ErrorAction Stop
        if ([int]$props.Installed -ne 1) { return $false }
        $v = [version](([string]$props.Version).TrimStart('v', 'V'))
        if ($v -ge [version]'14.30') {
            Write-Log -Level Warn -Message "VC++ 2015-2022 runtime $v is installed; Striim MSJet expects the 2015-2019 line (14.28.29914 - 14.29.x). Continuing - if MSJet later reports native DLL errors, uninstall 'Microsoft Visual C++ 2015-2022 Redistributable (x64)' via Settings > Apps and re-run this wizard to install the 2015-2019 runtime."
            return $true
        }
        return ($v -ge [version]'14.28.29914')
    } catch {
        return $false
    }
}

function Test-OleDbVersionKnownGood {
    param([Parameter(Mandatory)][string]$VersionString)
    return [bool]($script:KnownGoodOleDbVersions -contains $VersionString)
}

function Get-OleDbDriverInfo {
    # Uninstall registry keys (64- and 32-bit views), DisplayName match - never Win32_Product.
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($key in @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            $displayName = if ($props.PSObject.Properties['DisplayName']) { [string]$props.DisplayName } else { '' }
            if ($displayName -like '*Microsoft OLE DB Driver*SQL Server*') {
                $ver = if ($props.PSObject.Properties['DisplayVersion']) { [string]$props.DisplayVersion } else { '' }
                return [pscustomobject]@{
                    Present   = $true
                    Version   = $ver
                    KnownGood = (Test-OleDbVersionKnownGood -VersionString $ver)
                }
            }
        }
    }
    return [pscustomobject]@{ Present = $false; Version = $null; KnownGood = $false }
}

function Install-VcRedist {
    $exe = Join-Path $script:DownloadDir 'vc_redist.x64.exe'
    if (-not (Test-Path $exe)) { throw "vc_redist.x64.exe not found in $script:DownloadDir." }
    $process = Start-Process -FilePath $exe -ArgumentList '/install /quiet /norestart' -Wait -PassThru
    $meaning = Get-ExitCodeMeaning -Code $process.ExitCode
    if ($meaning.Result -eq 'Fail') { throw "VC++ Redistributable failed: $($meaning.Message). $($meaning.Hint)" }
    if ($meaning.Result -eq 'PassWithWarning') { Write-Log -Level Warn -Message "VC++ Redistributable: $($meaning.Message). $($meaning.Hint)" }
}

function Install-OleDbDriver {
    $msi = Join-Path $script:DownloadDir 'msoledbsql.msi'
    if (-not (Test-Path $msi)) { throw "msoledbsql.msi not found in $script:DownloadDir." }
    # IACCEPTMSOLEDBSQLLICENSETERMS=YES is required for a silent msoledbsql install.
    $msiArgs = '/i "{0}" /qn IACCEPTMSOLEDBSQLLICENSETERMS=YES' -f $msi
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru
    $meaning = Get-ExitCodeMeaning -Code $process.ExitCode
    if ($meaning.Result -eq 'Fail') { throw "OLE DB Driver install failed: $($meaning.Message). $($meaning.Hint)" }
    if ($meaning.Result -eq 'PassWithWarning') { Write-Log -Level Warn -Message "OLE DB Driver: $($meaning.Message). $($meaning.Hint)" }
}

function Expand-StriimArchive {
    # Striim zips wrap everything in one top-level folder - flatten it. Preserved names
    # (downloads\, logs\) and loose files (this script, plan file) are never clobbered away.
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$PreserveNames = @('downloads', 'logs')
    )
    if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Force -Path $Destination | Out-Null }
    Expand-Archive -Path $ZipPath -DestinationPath $Destination -Force
    $subDirs = @(Get-ChildItem -Path $Destination -Directory -Force | Where-Object { $PreserveNames -notcontains $_.Name })
    if ($subDirs.Count -eq 1) {
        $nested = $subDirs[0]
        Get-ChildItem -Path $nested.FullName -Force | Move-Item -Destination $Destination -Force
        Remove-Item -Path $nested.FullName -Force
    }
}

function Install-SqljdbcAuthDll {
    # Striim 5.x ships sqljdbc_auth.dll inside its own lib\ (extracted before this step
    # runs); a copy beside the script and downloads\ are kept as fallbacks. Never downloaded.
    param([Parameter(Mandatory)][string]$InstallPath)
    $source = @(
        (Join-Path $InstallPath 'lib\sqljdbc_auth.dll'),
        (Join-Path $script:ScriptDir 'sqljdbc_auth.dll'),
        (Join-Path $script:DownloadDir 'sqljdbc_auth.dll')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $source) { throw "sqljdbc_auth.dll not found in $InstallPath\lib\, next to the script, or in downloads\." }
    Copy-Item -Path $source -Destination 'C:\Windows\System32\sqljdbc_auth.dll' -Force
}

function Update-PathValue {
    # Pure: case-insensitive compare with trailing-backslash trimming to avoid duplicate entries.
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$CurrentPath,
        [Parameter(Mandatory)][string]$NewEntry
    )
    $entries = @($CurrentPath -split ';' | Where-Object { $_ -ne '' })
    $normalizedNew = $NewEntry.TrimEnd('\')
    foreach ($entry in $entries) {
        if ($entry.TrimEnd('\') -ieq $normalizedNew) { return ($entries -join ';') }
    }
    return ((@($entries) + $NewEntry) -join ';')
}

function Add-MachinePathEntry {
    # Machine-scope write requires elevation (we are elevated during Execute).
    param([Parameter(Mandatory)][string]$Entry)
    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $updated = Update-PathValue -CurrentPath $current -NewEntry $Entry
    if ($updated -ne $current) {
        [Environment]::SetEnvironmentVariable('Path', $updated, 'Machine')
    }
    Update-SessionEnvironment
}

function Get-SystemProbes {
    # Read-only pre-elevation probes feeding New-InstallPlan (spec 2.3: plan = answers + probes).
    $cached = @()
    if (Test-Path $script:DownloadDir) {
        $cached = @(Get-ChildItem -Path $script:DownloadDir -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    }
    return [pscustomobject]@{
        Java17Resolvable  = (Test-Java17Resolvable -Findings (Find-JavaInstallations))
        VcRedistInstalled = (Test-VcRedistInstalled)
        OleDb             = (Get-OleDbDriverInfo)
        CachedFiles       = $cached
    }
}

function New-VcRedistStep {
    return New-InstallStep -Name 'Visual C++ 2015-2019 Redistributable (x64)' -Test {
        Test-VcRedistInstalled
    } -Action {
        Install-VcRedist
    }
}

function New-OleDbStep {
    return New-InstallStep -Name 'Microsoft OLE DB Driver for SQL Server' -Test {
        $info = Get-OleDbDriverInfo
        if ($info.Present -and -not $info.KnownGood) {
            Write-Log -Level Warn -Message "OLE DB Driver $($info.Version) present but not in the known-good list ($($script:KnownGoodOleDbVersions -join ', ')) - continuing (warn, not block)."
        }
        $info.Present
    } -Action {
        Install-OleDbDriver
    }
}

function New-ExtractStep {
    param([Parameter(Mandatory)][object]$Plan)
    $iv = $Plan.Interview
    $mainZipName = if ($iv.NodeType -eq 'A') { "Striim_Agent_$($iv.Version).zip" } else { "Striim_$($iv.Version).zip" }
    $downloadDir = $script:DownloadDir   # $script: is unreachable inside GetNewClosure blocks
    return New-InstallStep -Name "Extract Striim -> $($iv.InstallPath)" -Critical -Test {
        (Test-StriimInstallDir -Path $iv.InstallPath).IsInstall
    }.GetNewClosure() -Action {
        $zip = Join-Path $downloadDir $mainZipName
        if (-not (Test-Path $zip)) { throw "$mainZipName not found in $downloadDir." }
        Expand-StriimArchive -ZipPath $zip -Destination $iv.InstallPath
    }.GetNewClosure()
}

function New-AuthDllStep {
    param([Parameter(Mandatory)][object]$Plan)
    $iv = $Plan.Interview
    return New-InstallStep -Name 'Place sqljdbc_auth.dll into System32 (Integrated Security)' -Test {
        Test-Path 'C:\Windows\System32\sqljdbc_auth.dll'
    } -Action {
        Install-SqljdbcAuthDll -InstallPath $iv.InstallPath
    }.GetNewClosure()
}

function New-PathStep {
    param([Parameter(Mandatory)][object]$Plan)
    $libPath = Join-Path $Plan.Interview.InstallPath 'lib'
    return New-InstallStep -Name "Add $libPath to the system PATH" -Test {
        $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        (Update-PathValue -CurrentPath $machine -NewEntry $libPath) -eq $machine
    }.GetNewClosure() -Action {
        Add-MachinePathEntry -Entry $libPath
    }.GetNewClosure()
}

function Get-ConfigProperty {
    # Field lore: split on the FIRST = only; commented lines do not count as values.
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$PropertyName
    )
    if (-not (Test-Path $ConfigPath)) { return $null }
    $line = Get-Content $ConfigPath | Where-Object {
        $_ -match "^\s*$([regex]::Escape($PropertyName))\s*=" -and -not $_.TrimStart().StartsWith('#')
    } | Select-Object -First 1
    if ($line) { return $line.Split('=', 2)[1].Trim() }
    return $null
}

function Update-ConfigContent {
    # Pure: set/uncomment each property in place; append when absent. Interview already
    # collected the values, so this is non-interactive (unlike the OG's prompt-per-property).
    param(
        # AllowEmptyString is LOAD-BEARING: Mandatory validates EVERY array element, and any
        # blank line in the config file is an empty string (field bug: binding error at the
        # config-write step on Striim's own template). AllowEmptyCollection covers empty files.
        [Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Properties
    )
    $result = New-Object System.Collections.ArrayList
    foreach ($l in $Lines) { [void]$result.Add($l) }
    foreach ($name in $Properties.Keys) {
        $value = $Properties[$name]
        $pattern = "^#?\s*$([regex]::Escape($name))\s*="
        $found = $false
        for ($i = 0; $i -lt $result.Count; $i++) {
            if ($result[$i] -match $pattern) {
                $result[$i] = "$name=$value"
                $found = $true
                break
            }
        }
        if (-not $found) { [void]$result.Add("$name=$value") }
    }
    return @($result)
}

function Set-ConfigFileProperties {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Properties
    )
    if (-not (Test-Path $ConfigPath)) { throw "Configuration file not found: $ConfigPath" }
    $updated = Update-ConfigContent -Lines @(Get-Content $ConfigPath) -Properties $Properties
    Set-Content -Path $ConfigPath -Value $updated
}

function Write-AgentConfig {
    # Required/optional props carried from the OG:
    #   Agent: striim.cluster.clusterName, striim.node.servernode.address (+ striim.cluster.https.enabled, MEM_MAX)
    #   Node:  CompanyName, LicenceKey, ProductKey, WAClusterName (+ MEM_MAX)
    param([Parameter(Mandatory)][object]$Plan)
    $iv = $Plan.Interview
    $artifacts = Get-ProfileArtifacts -NodeType $iv.NodeType
    $configPath = Join-Path $iv.InstallPath $artifacts.ConfigFile
    $props = [ordered]@{}
    if ($iv.NodeType -eq 'A') {
        $props['striim.cluster.clusterName'] = $iv.ClusterName
        $props['striim.node.servernode.address'] = $iv.ServerAddress
        $props['striim.cluster.https.enabled'] = if ($iv.HttpsEnabled) { 'true' } else { 'false' }
    } else {
        $props['CompanyName'] = $iv.NodeLicense.CompanyName
        $props['LicenceKey']  = $iv.NodeLicense.LicenceKey
        $props['ProductKey']  = $iv.NodeLicense.ProductKey
        $props['WAClusterName'] = $iv.ClusterName
    }
    if (-not [string]::IsNullOrWhiteSpace($iv.MemMax)) { $props['MEM_MAX'] = $iv.MemMax }
    if (-not [string]::IsNullOrWhiteSpace($iv.MemMin)) { $props['MEM_MIN'] = $iv.MemMin }
    Set-ConfigFileProperties -ConfigPath $configPath -Properties $props
    # Keep wrapper.conf (yajsw service JVM args) in lockstep so the service does not silently override
    # agent.conf at JVM start. No-op (warn) when wrapper.conf is absent (no service wrapper installed).
    if (Resolve-WrapperConfPath -InstallPath $iv.InstallPath -NodeType $iv.NodeType) {
        $fieldByKey = @{ MEM_MAX = $iv.MemMax; MEM_MIN = $iv.MemMin; ClusterName = $iv.ClusterName; ServerAddress = $iv.ServerAddress }
        foreach ($entry in $script:WrapperPropertyMap) {
            $val = [string]$fieldByKey[$entry.Key]
            if ([string]::IsNullOrWhiteSpace($val)) { continue }   # never write a blank arg
            Set-WrapperProperty -InstallPath $iv.InstallPath -NodeType $iv.NodeType -MapEntry $entry -NewValue $val
        }
    } else {
        Write-Log -Level Info -Message 'No wrapper.conf (Windows service wrapper) present - skipped JVM-arg sync; agent.conf is authoritative.'
    }
}

function Test-AgentConfigWritten {
    # Required props present and non-empty - this is also the Verify-mode check.
    param([Parameter(Mandatory)][object]$Plan)
    $iv = $Plan.Interview
    $artifacts = Get-ProfileArtifacts -NodeType $iv.NodeType
    $configPath = Join-Path $iv.InstallPath $artifacts.ConfigFile
    if (-not (Test-Path $configPath)) { return $false }
    $required = if ($iv.NodeType -eq 'A') {
        @('striim.cluster.clusterName', 'striim.node.servernode.address')
    } else {
        @('CompanyName', 'LicenceKey', 'ProductKey', 'WAClusterName')
    }
    foreach ($prop in $required) {
        if ([string]::IsNullOrWhiteSpace((Get-ConfigProperty -ConfigPath $configPath -PropertyName $prop))) { return $false }
    }
    return $true
}

function New-ConfigStep {
    param([Parameter(Mandatory)][object]$Plan)
    $artifacts = Get-ProfileArtifacts -NodeType $Plan.Interview.NodeType
    return New-InstallStep -Name "Write $($artifacts.ConfigFile)" -Critical -Test {
        Test-AgentConfigWritten -Plan $Plan
    }.GetNewClosure() -Action {
        Write-AgentConfig -Plan $Plan
    }.GetNewClosure()
}

function Get-ServiceWrapperZipPath {
    # The yajsw wrapper zip (Category 'ServiceInstaller') for this profile/version - shared by
    # Install-StriimService and Uninstall-StriimWindowsService so both extract the same file.
    param([Parameter(Mandatory)][object]$Interview)
    $zipName = if ($Interview.NodeType -eq 'A') { "Striim_windowsAgent_$($Interview.Version).zip" } else { "Striim_windowsService_$($Interview.Version).zip" }
    return Join-Path $script:DownloadDir $zipName
}

function Install-StriimService {
    # yajsw setup scripts require the CURRENT LOCATION to be their folder when invoked (field lore).
    # Always deregister any existing registration first (no-op if none) - a stale service left over
    # from a prior attempt (e.g. one with no extracted ServiceConfigDir) must not block a fresh
    # setupWindowsAgent.ps1/setupWindowsService.ps1 run, and yajsw's installer can fail outright if a
    # service by that name already exists.
    param([Parameter(Mandatory)][object]$Plan)
    Uninstall-StriimWindowsService -Plan $Plan
    $iv = $Plan.Interview
    $artifacts = Get-ProfileArtifacts -NodeType $iv.NodeType
    $zipPath = Get-ServiceWrapperZipPath -Interview $iv
    if (-not (Test-Path $zipPath)) { throw "$(Split-Path $zipPath -Leaf) not found in $script:DownloadDir." }
    $serviceConfigDir = Join-Path $iv.InstallPath $artifacts.ServiceConfigDir
    if (Test-Path $serviceConfigDir) { Remove-Item -Path $serviceConfigDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $serviceConfigDir | Out-Null
    Expand-StriimArchive -ZipPath $zipPath -Destination $serviceConfigDir -PreserveNames @()
    $setupScript = Join-Path $serviceConfigDir $artifacts.ServiceSetupScript
    if (-not (Test-Path $setupScript)) { throw "Setup script $($artifacts.ServiceSetupScript) not found after extraction." }
    Push-Location $serviceConfigDir
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setupScript
        if ($LASTEXITCODE -ne 0) { throw "Service setup script exited with code $LASTEXITCODE." }
    } finally {
        Pop-Location
    }
}

function New-ServiceStep {
    # Test must not trust bare existence: a service registered by a prior, broken attempt (e.g. one
    # whose ServiceConfigDir was never extracted) still shows up in Get-Service, but its wrapper exe
    # is missing and it can never start. Confirm the exe the SCM points at is actually on disk too.
    param([Parameter(Mandatory)][object]$Plan)
    $artifacts = Get-ProfileArtifacts -NodeType $Plan.Interview.NodeType
    return New-InstallStep -Name "Register '$($artifacts.ServiceName)' Windows service" -Test {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$($artifacts.ServiceName)'" -ErrorAction SilentlyContinue
        if ($null -eq $svc) { return $false }
        Test-Path (ConvertFrom-ServicePathName -PathName $svc.PathName)
    }.GetNewClosure() -Action {
        Install-StriimService -Plan $Plan
    }.GetNewClosure()
}

function Invoke-KeystoreConfig {
    # .bat files run via cmd /c with the working directory set to their folder - direct
    # invocation from PowerShell is unreliable (field lore).
    # Passwords provided -> automatic flags; skipped -> interactive final step.
    param([Parameter(Mandatory)][object]$Plan)
    $iv = $Plan.Interview
    $artifacts = Get-ProfileArtifacts -NodeType $iv.NodeType
    $batPath = Join-Path $iv.InstallPath $artifacts.KeystoreScript
    if (-not (Test-Path $batPath)) { throw "Keystore script not found: $batPath" }
    Push-Location $iv.InstallPath
    try {
        if ($iv.KeystorePassword -and $iv.SysPassword) {
            $ksPlain = ConvertTo-PlainText -Secure $iv.KeystorePassword
            $sysPlain = ConvertTo-PlainText -Secure $iv.SysPassword
            try {
                & cmd.exe /c "`"$batPath`" `"$ksPlain`" `"$sysPlain`""
            } finally {
                $ksPlain = $null; $sysPlain = $null
            }
        } else {
            Write-Log -Level Info -Message 'One final step needs your input: keystore configuration.'
            & cmd.exe /c "`"$batPath`""
        }
        if ($LASTEXITCODE -ne 0) { throw "Keystore script exited with code $LASTEXITCODE." }
    } finally {
        Pop-Location
    }
}

function Test-KeystoreFilesExist {
    param([Parameter(Mandatory)][object]$Plan)
    $iv = $Plan.Interview
    $artifacts = Get-ProfileArtifacts -NodeType $iv.NodeType
    return (Test-Path (Join-Path $iv.InstallPath $artifacts.JksFile)) -and
           (Test-Path (Join-Path $iv.InstallPath $artifacts.PwdFile))
}

function New-KeystoreStep {
    param([Parameter(Mandatory)][object]$Plan)
    $artifacts = Get-ProfileArtifacts -NodeType $Plan.Interview.NodeType
    return New-InstallStep -Name "Generate keystore via $(Split-Path $artifacts.KeystoreScript -Leaf)" -Test {
        Test-KeystoreFilesExist -Plan $Plan
    }.GetNewClosure() -Action {
        Invoke-KeystoreConfig -Plan $Plan
    }.GetNewClosure()
}

function Get-RestorableBackupFiles {
    # Relative paths a restore copies back: the keystore pair (only while the cluster still
    # matches - it is bound to its cluster), the backed-up log4j*.properties logging config,
    # and every backed-up lib\ jar. The main conf file (agent.conf/startUp.properties) is
    # NOT copied: the wizard rewrites it from interview answers the backup already prefilled.
    # log4j IS copied - it has no interview to regenerate from, and is cluster-independent so
    # it restores regardless of keystore/cluster match.
    param(
        [Parameter(Mandatory)][string]$BackupDir,
        [Parameter(Mandatory)][ValidateSet('A', 'N')][string]$NodeType,
        [bool]$IncludeKeystore = $true
    )
    $artifacts = Get-ProfileArtifacts -NodeType $NodeType
    $files = New-Object System.Collections.ArrayList
    if ($IncludeKeystore) {
        foreach ($relative in @($artifacts.JksFile, $artifacts.PwdFile)) {
            if (Test-Path (Join-Path $BackupDir $relative)) { [void]$files.Add($relative) }
        }
    }
    foreach ($relative in @(Get-Log4jConfigFiles -RootPath $BackupDir)) {
        [void]$files.Add($relative)
    }
    foreach ($jar in @(Get-ChildItem -Path (Join-Path $BackupDir 'lib') -Filter '*.jar' -File -ErrorAction SilentlyContinue)) {
        [void]$files.Add("lib\$($jar.Name)")
    }
    return @($files)
}

function New-RestoreBackupStep {
    # Runs after the config write; a restored keystore makes New-KeystoreStep's Test pass,
    # so generation is skipped and the agent keeps its cluster identity.
    param([Parameter(Mandatory)][object]$Plan)
    $iv = $Plan.Interview
    $what = if ($iv.RestoreKeystore) { 'keystore, log4j config, and non-default jars' } else { 'log4j config and non-default jars' }
    return New-InstallStep -Name "Restore $what from $($iv.RestoreFrom)" -Test {
        $files = @(Get-RestorableBackupFiles -BackupDir $iv.RestoreFrom -NodeType $iv.NodeType -IncludeKeystore $iv.RestoreKeystore)
        @($files | Where-Object { -not (Test-Path (Join-Path $iv.InstallPath $_)) }).Count -eq 0
    }.GetNewClosure() -Action {
        foreach ($relative in @(Get-RestorableBackupFiles -BackupDir $iv.RestoreFrom -NodeType $iv.NodeType -IncludeKeystore $iv.RestoreKeystore)) {
            Copy-Item -Path (Join-Path $iv.RestoreFrom $relative) -Destination (Join-Path $iv.InstallPath $relative) -Force
        }
    }.GetNewClosure()
}

function Install-JdbcDriver {
    param(
        [Parameter(Mandatory)][object]$Driver,    # interview selection entry: Key/Kind/ManifestName/ManualPath
        [Parameter(Mandatory)][string]$InstallPath
    )
    $libPath = Join-Path $InstallPath 'lib'
    switch ($Driver.Key) {
        'mariadb' {
            Copy-Item -Path (Join-Path $script:DownloadDir 'mariadb-java-client-2.4.3.jar') -Destination $libPath -Force
        }
        'postgres' {
            Copy-Item -Path (Join-Path $script:DownloadDir 'postgresql-42.2.27.jar') -Destination $libPath -Force
        }
        'mysql' {
            # The zip nests the jar: mysql-connector-j-8.0.30\mysql-connector-java-8.0.30.jar
            $zip = Join-Path $script:DownloadDir 'mysql-connector-j-8.0.30.zip'
            $temp = Join-Path $script:DownloadDir 'mysql-temp'
            if (Test-Path $temp) { Remove-Item $temp -Recurse -Force }
            Expand-Archive -Path $zip -DestinationPath $temp -Force
            $jar = Join-Path $temp 'mysql-connector-j-8.0.30\mysql-connector-java-8.0.30.jar'
            if (-not (Test-Path $jar)) { throw 'mysql-connector-java-8.0.30.jar not found inside the connector zip.' }
            Copy-Item -Path $jar -Destination $libPath -Force
            Remove-Item $temp -Recurse -Force
        }
        'oracle' {
            # Instant Client extracts beside the install; NATIVE_LIBS points at the client dir.
            $zip = Join-Path $script:DownloadDir 'instantclient-basic-windows.x64-21.6.0.0.0dbru.zip'
            $targetDir = Join-Path $InstallPath 'oracle_instant_client'
            Expand-Archive -Path $zip -DestinationPath $targetDir -Force
            $clientDir = Get-ChildItem -Path $targetDir -Directory | Select-Object -First 1
            if (-not $clientDir) { throw 'Could not determine the Instant Client directory after extraction.' }
            Set-ConfigFileProperties -ConfigPath (Join-Path $InstallPath 'conf\agent.conf') -Properties ([ordered]@{ 'NATIVE_LIBS' = $clientDir.FullName })
        }
        'nonstop' {
            Copy-Item -Path $Driver.ManualPath -Destination $libPath -Force
        }
        'teradata' {
            Copy-Item -Path (Join-Path $Driver.ManualPath 'terajdbc4.jar') -Destination $libPath -Force
            Copy-Item -Path (Join-Path $Driver.ManualPath 'tdgssconfig.jar') -Destination $libPath -Force
        }
        'vertica' {
            Copy-Item -Path $Driver.ManualPath -Destination $libPath -Force
        }
        default { throw "Unknown JDBC driver key '$($Driver.Key)'." }
    }
}

function Test-JdbcDriverInstalled {
    param(
        [Parameter(Mandatory)][object]$Driver,
        [Parameter(Mandatory)][string]$InstallPath
    )
    $libPath = Join-Path $InstallPath 'lib'
    switch ($Driver.Key) {
        'mariadb'  { return (Test-Path (Join-Path $libPath 'mariadb-java-client-2.4.3.jar')) }
        'postgres' { return (Test-Path (Join-Path $libPath 'postgresql-42.2.27.jar')) }
        'mysql'    { return (Test-Path (Join-Path $libPath 'mysql-connector-java-8.0.30.jar')) }
        'oracle'   {
            $native = Get-ConfigProperty -ConfigPath (Join-Path $InstallPath 'conf\agent.conf') -PropertyName 'NATIVE_LIBS'
            return (-not [string]::IsNullOrWhiteSpace($native)) -and (Test-Path $native)
        }
        'nonstop'  { return (Test-Path (Join-Path $libPath 't4sqlmx.jar')) }
        'teradata' { return (Test-Path (Join-Path $libPath 'terajdbc4.jar')) -and (Test-Path (Join-Path $libPath 'tdgssconfig.jar')) }
        'vertica'  { return @(Get-ChildItem -Path $libPath -Filter 'vertica-jdbc-*.jar' -ErrorAction SilentlyContinue).Count -gt 0 }
        default    { return $false }
    }
}

function Get-JdbcDriverSteps {
    param([Parameter(Mandatory)][object]$Plan)
    $iv = $Plan.Interview
    $steps = New-Object System.Collections.ArrayList
    foreach ($driver in @($iv.Drivers)) {
        $d = $driver
        [void]$steps.Add((New-InstallStep -Name "Install JDBC driver: $($d.Label)" -Test {
            Test-JdbcDriverInstalled -Driver $d -InstallPath $iv.InstallPath
        }.GetNewClosure() -Action {
            Install-JdbcDriver -Driver $d -InstallPath $iv.InstallPath
        }.GetNewClosure()))
    }
    return @($steps)
}

function Get-PatchSteps {
    # Generic version-gated "replace jar in lib\" step type. The manifest carries no Patch
    # entries today (4.2.0.20 fixes were dropped with 4.x), but 5.x field patches will happen
    # again and must not repeat the OG's manifest-without-application gap.
    param(
        [Parameter(Mandatory)][string]$TargetVersion,
        [Parameter(Mandatory)][ValidateSet('A', 'N')][string]$NodeType,
        [Parameter(Mandatory)][string]$LibPath,
        [object[]]$ManifestEntries = $script:AllDownloads
    )
    $patches = Get-ManifestFiles -NodeType $NodeType -TargetVersion $TargetVersion -Categories @('Patch') -ManifestEntries $ManifestEntries
    $steps = New-Object System.Collections.ArrayList
    $downloadDir = $script:DownloadDir   # $script: is unreachable inside GetNewClosure blocks
    foreach ($patch in $patches) {
        $p = $patch
        [void]$steps.Add((New-InstallStep -Name "Apply patch: $($p.Name) -> $($p.TargetFile)" -Test {
            $target = Join-Path $LibPath $p.TargetFile
            $source = Join-Path $downloadDir $p.Name
            (Test-Path $target) -and (Test-Path $source) -and
                ((Get-FileHash $target -Algorithm SHA256).Hash -eq (Get-FileHash $source -Algorithm SHA256).Hash)
        }.GetNewClosure() -Action {
            $source = Join-Path $downloadDir $p.Name
            if (-not (Test-Path $source)) {
                if (-not (Get-RemoteFile -Uri $p.Url -OutFile $source -Sha256 $p.Sha256)) { throw "Failed to download patch $($p.Name)." }
            }
            Copy-Item -Path $source -Destination (Join-Path $LibPath $p.TargetFile) -Force
        }.GetNewClosure()))
    }
    return @($steps)
}

function New-ScriptCopyStep {
    # OG behavior: the script copies itself into the install dir so future maintenance runs work from there.
    param([Parameter(Mandatory)][object]$Plan)
    $sourcePath = $script:ScriptPath   # $script: is unreachable inside GetNewClosure blocks
    $target = Join-Path $Plan.Interview.InstallPath (Split-Path $sourcePath -Leaf)
    return New-InstallStep -Name 'Copy installer script into the install directory' -Test {
        (Test-Path $target) -and ((Get-Item $target).Length -eq (Get-Item $sourcePath).Length)
    }.GetNewClosure() -Action {
        Copy-Item -Path $sourcePath -Destination $target -Force
    }.GetNewClosure()
}

function Get-InstallSteps {
    # The full install step list in execution order. The engine's Tests make this idempotent:
    # present things report "already present" instead of redoing work.
    param([Parameter(Mandatory)][object]$Plan)
    $iv = $Plan.Interview
    $steps = New-Object System.Collections.ArrayList
    [void]$steps.Add((New-DownloadBatchStep -Plan $Plan))
    [void]$steps.Add((New-Java17Step -Plan $Plan))
    [void]$steps.Add((New-VcRedistStep))
    [void]$steps.Add((New-OleDbStep))
    [void]$steps.Add((New-ExtractStep -Plan $Plan))
    [void]$steps.Add((New-ScriptCopyStep -Plan $Plan))
    if ($iv.IntegratedSecurity) { [void]$steps.Add((New-AuthDllStep -Plan $Plan)) }
    [void]$steps.Add((New-PathStep -Plan $Plan))
    [void]$steps.Add((New-ConfigStep -Plan $Plan))
    if ($iv.RestoreFrom) { [void]$steps.Add((New-RestoreBackupStep -Plan $Plan)) }
    foreach ($s in (Get-JdbcDriverSteps -Plan $Plan)) { [void]$steps.Add($s) }
    foreach ($s in (Get-PatchSteps -TargetVersion $iv.Version -NodeType $iv.NodeType -LibPath (Join-Path $iv.InstallPath 'lib'))) { [void]$steps.Add($s) }
    if ($iv.InstallService) { [void]$steps.Add((New-ServiceStep -Plan $Plan)) }
    [void]$steps.Add((New-KeystoreStep -Plan $Plan))   # last: may be interactive if passwords were skipped
    return @($steps)
}
#endregion ExecuteSteps

#region Verify
function Get-VerifySteps {
    # Every requirement as a Test-only step (spec 2.6); also reachable via maintenance [1].
    param([Parameter(Mandatory)][object]$Plan)
    $iv = $Plan.Interview
    $artifacts = Get-ProfileArtifacts -NodeType $iv.NodeType
    $steps = New-Object System.Collections.ArrayList
    if ($iv.InstallService) {
        [void]$steps.Add((New-InstallStep -Name "Windows service '$($artifacts.ServiceName)' registered" -Test {
            $null -ne (Get-Service -Name $artifacts.ServiceName -ErrorAction SilentlyContinue)
        }.GetNewClosure()))
    }
    [void]$steps.Add((New-InstallStep -Name 'Java 17 resolvable (PATH and JAVA_HOME)' -Test {
        $findings = Find-JavaInstallations
        $pathOk = @($findings | Where-Object { $_.Source -eq 'PATH' -and $_.Major -eq 17 }).Count -gt 0
        $homeOk = @($findings | Where-Object { $_.Source -eq 'JAVA_HOME' -and $_.Major -eq 17 }).Count -gt 0
        $pathOk -and $homeOk
    }))
    if ($iv.IntegratedSecurity) {
        [void]$steps.Add((New-InstallStep -Name 'sqljdbc_auth.dll in System32' -Test {
            Test-Path 'C:\Windows\System32\sqljdbc_auth.dll'
        }))
    }
    [void]$steps.Add((New-InstallStep -Name "Required config props non-empty in $($artifacts.ConfigFile)" -Test {
        Test-AgentConfigWritten -Plan $Plan
    }.GetNewClosure()))
    [void]$steps.Add((New-InstallStep -Name "Cluster auth port $($iv.AuthPort) reachable" -Test {
        Test-ClusterReachability -ServerAddress $iv.ServerAddress -Port $iv.AuthPort
    }.GetNewClosure()))
    [void]$steps.Add((New-InstallStep -Name 'Install drive has >= 10% free disk' -Test {
        $letter = $iv.InstallPath.Substring(0, 1).ToUpper()
        $drive = Get-DriveTable | Where-Object { $_.Drive -ieq "${letter}:" } | Select-Object -First 1
        $null -ne $drive -and $drive.PercentFree -ge 10
    }.GetNewClosure()))
    return @($steps)
}

function Show-SummaryCard {
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [object[]]$VerifyResults = @()
    )
    Write-Host ("`n" + ('=' * 74)) -ForegroundColor Cyan
    Write-Host ' INSTALL SUMMARY' -ForegroundColor White
    Write-Host ('=' * 74) -ForegroundColor Cyan
    foreach ($r in $Results) {
        $tag, $color = switch ($r.Status) {
            'Fixed'          { '[DONE]', 'Green' }
            'AlreadyPresent' { '[OK]  ', 'Green' }
            'Passed'         { '[PASS]', 'Green' }
            'Skipped'        { '[SKIP]', 'Yellow' }
            default          { '[FAIL]', 'Red' }
        }
        Write-Host (' {0} {1}' -f $tag, $r.Name) -ForegroundColor $color
    }
    if (@($VerifyResults).Count -gt 0) {
        Write-Host "`n Verification:" -ForegroundColor Cyan
        foreach ($r in $VerifyResults) {
            $tag = if ($r.Status -eq 'Passed') { '[PASS]' } else { '[FAIL]' }
            $color = if ($r.Status -eq 'Passed') { 'Green' } else { 'Red' }
            Write-Host (' {0} {1}' -f $tag, $r.Name) -ForegroundColor $color
        }
    }
    if ($script:WarningsCollected.Count -gt 0) {
        Write-Host "`n Warnings:" -ForegroundColor Yellow
        foreach ($w in @($script:WarningsCollected | Select-Object -Unique)) { Write-Host "  - $w" -ForegroundColor Yellow }
    }
    if ($script:TranscriptPath) {
        Write-Host "`n Transcript (send this file to Striim support if anything failed):" -ForegroundColor Cyan
        Write-Host "  $script:TranscriptPath"
    }
}

function Show-NextSteps {
    param([Parameter(Mandatory)][object]$Plan)
    $artifacts = Get-ProfileArtifacts -NodeType $Plan.Interview.NodeType
    Write-Host "`n Next steps:" -ForegroundColor Cyan
    Write-Host ("  Start the service:   Start-Service '{0}'" -f $artifacts.ServiceName)
    Write-Host ("  Stop the service:    Stop-Service '{0}'" -f $artifacts.ServiceName)
    Write-Host ("  Agent logs:          {0}\logs\" -f $Plan.Interview.InstallPath)
    Write-Host ("  In the Striim console: once started, the agent appears under Monitor > Agents for cluster '{0}'." -f $Plan.Interview.ClusterName)
    if ($script:TranscriptPath) { Write-Host ("  Install transcript:  {0}" -f $script:TranscriptPath) }
}
#endregion Verify

#region SettingsProfile
# wrapper.conf (the yajsw Windows-service JVM-arg file) silently overrides agent.conf at JVM start.
# This region gives a unified read/write view over both files so the wizard can keep them in lockstep.

# EXPECTED locations, not verified at runtime - treated as a fast-path hint only. The Node path is an
# UNVERIFIED placeholder; Resolve-WrapperConfPath falls back to a -Recurse search if the hint misses.
# Verify on a real install: Get-ChildItem -Path <InstallPath> -Recurse -Filter wrapper.conf | % FullName
$script:WrapperConfRelPaths = @{
    A = 'conf\windowsAgent\yajsw_agent\conf\wrapper.conf'   # VERIFIED (Agent)
    N = 'conf\windowsService\yajsw\conf\wrapper.conf'        # UNVERIFIED placeholder (Node)
}

# One row per setting that lives in BOTH files. Kind drives parse/emit:
#   Flag  - value is glued to the flag (-Xmx4096m): read = strip Flag; write = Flag + value.
#   DProp - -D<key>=<value>: read = text after first '='; write = -D<key>=<value>.
# deploymentGroups is intentionally excluded (agent.conf 'Agents' vs wrapper 'agent' is by design).
$script:WrapperPropertyMap = @(
    [pscustomobject]@{ Key = 'MEM_MAX';       Label = 'Max heap (MEM_MAX)';     AgentProp = 'MEM_MAX';                        Match = '^-Xmx';                                 Kind = 'Flag';  Flag = '-Xmx' }
    [pscustomobject]@{ Key = 'MEM_MIN';       Label = 'Min heap (MEM_MIN)';     AgentProp = 'MEM_MIN';                        Match = '^-Xms';                                 Kind = 'Flag';  Flag = '-Xms' }
    [pscustomobject]@{ Key = 'ClusterName';   Label = 'Cluster name';           AgentProp = 'striim.cluster.clusterName';     Match = '^-Dstriim\.cluster\.clusterName=';      Kind = 'DProp'; DKey = 'striim.cluster.clusterName' }
    [pscustomobject]@{ Key = 'ServerAddress'; Label = 'Server address';         AgentProp = 'striim.node.servernode.address'; Match = '^-Dstriim\.node\.servernode\.address='; Kind = 'DProp'; DKey = 'striim.node.servernode.address' }
)

function Resolve-WrapperConfPath {
    # Discovery order (design "Discovery order at runtime"): hint -> -Recurse search of the profile's
    # ServiceConfigDir (mirrors Uninstall-StriimWindowsService) -> prefer the file naming the service,
    # then shallowest. Returns $null when no wrapper.conf exists (the no-service-wrapper case).
    param(
        [Parameter(Mandatory)][string]$InstallPath,
        [Parameter(Mandatory)][ValidateSet('A', 'N')][string]$NodeType
    )
    $hint = Join-Path $InstallPath $script:WrapperConfRelPaths[$NodeType]
    if (Test-Path $hint) { return $hint }
    $artifacts = Get-ProfileArtifacts -NodeType $NodeType
    $serviceConfigDir = Join-Path $InstallPath $artifacts.ServiceConfigDir
    if (-not (Test-Path $serviceConfigDir)) { return $null }
    $hits = @(Get-ChildItem -Path $serviceConfigDir -Recurse -Filter 'wrapper.conf' -File -ErrorAction SilentlyContinue)
    if ($hits.Count -eq 0) { return $null }
    if ($hits.Count -eq 1) { return $hits[0].FullName }
    $named = @($hits | Where-Object {
        Select-String -Path $_.FullName -Pattern '^\s*wrapper\.ntservice\.name\s*=' -Quiet -ErrorAction SilentlyContinue
    })
    $pool = if ($named.Count -gt 0) { $named } else { $hits }
    return ($pool | Sort-Object { ($_.FullName -split '[\\/]').Count } | Select-Object -First 1).FullName
}

function Get-WrapperProperty {
    # Returns: $null  = wrapper.conf absent OR the arg line is absent (no conflict).
    #          ''     = arg present but blank (a blank -D arg DOES clobber agent.conf -> conflict).
    #          string = the extracted value.
    # SENTINEL DISCIPLINE: $null and '' are different. Never test with IsNullOrEmpty/IsNullOrWhiteSpace.
    param(
        [Parameter(Mandatory)][string]$InstallPath,
        [Parameter(Mandatory)][ValidateSet('A', 'N')][string]$NodeType,
        [Parameter(Mandatory)][object]$MapEntry
    )
    $path = Resolve-WrapperConfPath -InstallPath $InstallPath -NodeType $NodeType
    if (-not $path) { return $null }
    $argValue = $null
    foreach ($raw in Get-Content -Path $path) {
        if ($raw.TrimStart().StartsWith('#')) { continue }
        if ($raw -notmatch '^\s*wrapper\.java\.additional\.\d+\s*=') { continue }
        $arg = ($raw -split '=', 2)[1].Trim()
        if ($arg -match $MapEntry.Match) { $argValue = $arg; break }
    }
    if ($null -eq $argValue) { return $null }
    if ($MapEntry.Kind -eq 'Flag') {
        return ($argValue -replace ('^' + [regex]::Escape($MapEntry.Flag)), '')
    }
    # DProp: everything after the first '=' inside the arg (may be '').
    $eq = $argValue.IndexOf('=')
    if ($eq -lt 0) { return '' }
    return $argValue.Substring($eq + 1)
}

function Set-WrapperProperty {
    # Line-level read-modify-write of the single matched wrapper.java.additional.* arg; every other
    # line is left exactly as-is (preserves backslash escapes/quotes elsewhere, e.g. java.library.path).
    # No-op + one Warn when wrapper.conf is absent. Append (before 'include =') only if the arg is missing.
    param(
        [Parameter(Mandatory)][string]$InstallPath,
        [Parameter(Mandatory)][ValidateSet('A', 'N')][string]$NodeType,
        [Parameter(Mandatory)][object]$MapEntry,
        [Parameter(Mandatory)][AllowEmptyString()][string]$NewValue
    )
    $path = Resolve-WrapperConfPath -InstallPath $InstallPath -NodeType $NodeType
    if (-not $path) {
        Write-Log -Level Warn -Message "wrapper.conf not found under $InstallPath - skipped syncing $($MapEntry.Key) (no Windows service wrapper installed)."
        return
    }
    $newArg = if ($MapEntry.Kind -eq 'Flag') { "$($MapEntry.Flag)$NewValue" } else { "-D$($MapEntry.DKey)=$NewValue" }
    $lines = @(Get-Content -Path $path)
    $found = $false
    $maxIndex = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].TrimStart().StartsWith('#')) { continue }
        if ($lines[$i] -match '^(?<pre>\s*wrapper\.java\.additional\.(?<n>\d+)\s*)(?<sep>=\s*)(?<arg>.*)$') {
            $n = [int]$Matches['n']
            if ($n -gt $maxIndex) { $maxIndex = $n }
            if ($Matches['arg'].Trim() -match $MapEntry.Match) {
                $lines[$i] = "$($Matches['pre'])$($Matches['sep'])$newArg"
                $found = $true
                break
            }
        }
    }
    if (-not $found) {
        $newLine = "wrapper.java.additional.$($maxIndex + 1) = $newArg"
        $includeIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*include\s*=') { $includeIdx = $i; break }
        }
        if ($includeIdx -ge 0) {
            $lines = @($lines[0..($includeIdx - 1)]) + $newLine + @($lines[$includeIdx..($lines.Count - 1)])
        } else {
            $lines = @($lines) + $newLine
        }
    }
    # UTF-8 WITHOUT BOM: yajsw/Java read this file and a BOM can break the first directive. WriteAllLines
    # emits CRLF (Environment.NewLine) on Windows, matching the original file's line endings. Cast to
    # [string[]] so the object[] from Get-Content binds to the (string, string[], Encoding) overload.
    [System.IO.File]::WriteAllLines($path, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
}

function ConvertFrom-HeapSize {
    # JVM heap string -> bytes for the MEM_MIN <= MEM_MAX guard. Suffixes k/m/g (case-insensitive);
    # bare number = bytes. $null when unparseable/blank (caller then skips the comparison).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $v = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }
    if ($v -match '^(?<n>\d+)(?<u>[kKmMgG]?)$') {
        $n = [int64]$Matches['n']
        switch ($Matches['u'].ToLower()) {
            'k' { return $n * 1KB }
            'm' { return $n * 1MB }
            'g' { return $n * 1GB }
            default { return $n }
        }
    }
    return $null
}

function Test-HeapOrder {
    # True when MemMin <= MemMax, or when either is blank/unparseable (nothing to enforce - the
    # design says only validate when MEM_MIN was collected and is non-blank).
    param(
        [AllowEmptyString()][string]$MemMin,
        [AllowEmptyString()][string]$MemMax
    )
    $min = ConvertFrom-HeapSize -Value $MemMin
    $max = ConvertFrom-HeapSize -Value $MemMax
    if ($null -eq $min -or $null -eq $max) { return $true }
    return ($min -le $max)
}

function Read-SettingsProfile {
    # Merged agent.conf + wrapper.conf view, one row per mapped setting, with a conflict flag.
    param(
        [Parameter(Mandatory)][string]$InstallPath,
        [Parameter(Mandatory)][ValidateSet('A', 'N')][string]$NodeType
    )
    $artifacts = Get-ProfileArtifacts -NodeType $NodeType
    $configPath = Join-Path $InstallPath $artifacts.ConfigFile
    # File-absent short-circuit: decide presence ONCE here; do not infer it from Get-WrapperProperty's
    # $null (that same value also means "line not found in an existing file").
    $wrapperPresent = [bool](Resolve-WrapperConfPath -InstallPath $InstallPath -NodeType $NodeType)
    $result = New-Object System.Collections.ArrayList
    foreach ($entry in $script:WrapperPropertyMap) {
        $agentVal = [string](Get-ConfigProperty -ConfigPath $configPath -PropertyName $entry.AgentProp)
        $wrapperVal = if ($wrapperPresent) { Get-WrapperProperty -InstallPath $InstallPath -NodeType $NodeType -MapEntry $entry } else { $null }
        $hasConflict = $false
        if ($null -ne $wrapperVal) {
            if ($wrapperVal -eq '') { $hasConflict = $true }                       # blank arg clobbers agent.conf
            elseif ($wrapperVal.Trim() -ne $agentVal.Trim()) { $hasConflict = $true } # differing non-blank value
        }
        [void]$result.Add([pscustomobject]@{
            Key = $entry.Key; Label = $entry.Label
            AgentValue = $agentVal; WrapperValue = $wrapperVal; HasConflict = $hasConflict
        })
    }
    return @($result)
}

function Read-SettingsInterview {
    # Conflict-aware replacement for Read-ClusterSettings in the [3] flow. agent.conf is the bracketed
    # default (Enter accepts, resolving any wrapper conflict on write). wrapper.conf is surfaced only
    # where it conflicts. MEM_MIN is shown only when it conflicts. Preserves the reachability probe.
    param(
        [Parameter(Mandatory)][object]$Install,
        [Parameter(Mandatory)][object]$Defaults
    )
    $byKey = @{}
    foreach ($e in @(Read-SettingsProfile -InstallPath $Install.Path -NodeType $Install.Type)) { $byKey[$e.Key] = $e }
    $showConflict = {
        param($entry)
        if ($entry -and $entry.HasConflict) {
            $av = if ([string]::IsNullOrEmpty($entry.AgentValue)) { '(blank)' } else { $entry.AgentValue }
            $wv = if ($entry.WrapperValue -eq '') { '(blank - will be synced)' } else { $entry.WrapperValue }
            Write-Host ("  agent.conf:   {0}" -f $av)
            Write-Host ("  wrapper.conf: {0}  <- conflict" -f $wv) -ForegroundColor Yellow
        }
    }

    Write-Host "`n--- Connection settings ---" -ForegroundColor Cyan
    & $showConflict $byKey['ClusterName']
    $clusterName = ''
    while ([string]::IsNullOrWhiteSpace($clusterName)) { $clusterName = Read-PromptWithDefault -Prompt 'Cluster name' -Default ([string]$Defaults.ClusterName) }
    & $showConflict $byKey['ServerAddress']
    $serverAddress = ''
    while ([string]::IsNullOrWhiteSpace($serverAddress)) { $serverAddress = Read-PromptWithDefault -Prompt 'Striim server node address (hostname or IP)' -Default ([string]$Defaults.ServerAddress) }
    $defHttps = if (-not $Defaults.HttpsEnabled) { 'n' } else { 'y' }
    $https = Confirm-UserChoice -Prompt 'Is HTTPS enabled on the cluster?' -DefaultChoice $defHttps
    $port = if ($https) { 9081 } else { 9080 }

    Write-Host "`n--- JVM / Memory ---" -ForegroundColor Cyan
    & $showConflict $byKey['MEM_MAX']
    $memMax = Read-PromptWithDefault -Prompt 'Max heap (MEM_MAX)' -Default ([string]$Defaults.MemMax)
    $memMin = [string]$Defaults.MemMin
    $minEntry = $byKey['MEM_MIN']
    if ($minEntry -and $minEntry.HasConflict) {
        & $showConflict $minEntry
        $memMin = Read-PromptWithDefault -Prompt 'Min heap (MEM_MIN)' -Default ([string]$Defaults.MemMin)
    }
    # Cross-field guard - never write a config that crashes the JVM at startup.
    while (-not (Test-HeapOrder -MemMin $memMin -MemMax $memMax)) {
        Write-Log -Level Warn -Message "MEM_MIN ($memMin) must be <= MEM_MAX ($memMax). Re-enter both."
        $memMax = Read-PromptWithDefault -Prompt 'Max heap (MEM_MAX)' -Default ([string]$memMax)
        $memMin = Read-PromptWithDefault -Prompt 'Min heap (MEM_MIN)' -Default ([string]$memMin)
    }

    # Reachability probe - preserved from Read-ClusterSettings (design Section 2 "Reachability probe").
    $reachable = Test-ClusterReachability -ServerAddress $serverAddress.Trim() -Port $port
    if ($reachable) {
        Write-Log -Level Success -Message "Cluster auth port $port on $serverAddress is reachable."
    } else {
        Write-Log -Level Warn -Message "Cannot reach $serverAddress on auth port $port from this host right now. Fix your firewall/VPN - you can continue anyway. (FYI for your network team: the agent also needs inbound TCP 5701 (Hazelcast) and outbound TCP 49152-65535.)"
    }
    return [pscustomobject]@{
        ClusterName = $clusterName.Trim(); ServerAddress = $serverAddress.Trim()
        HttpsEnabled = $https; AuthPort = $port; ClusterReachable = $reachable
        MemMax = $memMax.Trim(); MemMin = $memMin.Trim()
    }
}
#endregion SettingsProfile

#region Maintenance
function Clear-InstallDirectory {
    # Clean-reinstall clearing ALWAYS preserves downloads\, logs\, and the script files themselves (field lore).
    param([Parameter(Mandatory)][string]$Path)
    $preserveDirs = @('downloads', 'logs')
    $preserveFiles = @((Split-Path $script:ScriptPath -Leaf), 'msjetchecker.ps1', 'install-plan.json')
    Get-ChildItem -Path $Path -Force | Where-Object {
        if ($_.PSIsContainer) { $preserveDirs -notcontains $_.Name }
        else { $preserveFiles -notcontains $_.Name }
    } | Remove-Item -Recurse -Force
}

function ConvertTo-InterviewFromInstall {
    # Rebuild an interview skeleton from a detected install so maintenance flows reuse the plan machinery.
    param([Parameter(Mandatory)][object]$Install)
    $artifacts = Get-ProfileArtifacts -NodeType $Install.Type
    $version = $Install.Version
    if ([string]::IsNullOrWhiteSpace([string]$version)) {
        # Conf-only detection (no lib\Platform-*.jar) leaves Version null - the manifest needs a real one.
        Write-Log -Level Warn -Message "Could not detect the installed Striim version under $($Install.Path) (no Platform-*.jar in lib\). Please confirm it."
        $version = Read-StriimVersion -NodeType $Install.Type
    }
    $configPath = Join-Path $Install.Path $artifacts.ConfigFile
    $clusterName = ''; $serverAddress = ''; $httpsEnabled = $true; $nodeLicense = $null
    if ($Install.Type -eq 'A') {
        $clusterName = [string](Get-ConfigProperty -ConfigPath $configPath -PropertyName 'striim.cluster.clusterName')
        $serverAddress = [string](Get-ConfigProperty -ConfigPath $configPath -PropertyName 'striim.node.servernode.address')
        $httpsEnabled = ((Get-ConfigProperty -ConfigPath $configPath -PropertyName 'striim.cluster.https.enabled') -ne 'false')
    } else {
        $clusterName = [string](Get-ConfigProperty -ConfigPath $configPath -PropertyName 'WAClusterName')
        # Carry the license over when complete; flows that need it ask when any prop is missing.
        $license = [ordered]@{}
        foreach ($prop in @('CompanyName', 'LicenceKey', 'ProductKey')) {
            $v = [string](Get-ConfigProperty -ConfigPath $configPath -PropertyName $prop)
            if (-not [string]::IsNullOrWhiteSpace($v)) { $license[$prop] = $v }
        }
        if ($license.Count -eq 3) { $nodeLicense = $license }
    }
    $authPort = if ($httpsEnabled) { 9081 } else { 9080 }
    $reachable = $false
    if (-not [string]::IsNullOrWhiteSpace($serverAddress)) {
        $reachable = Test-ClusterReachability -ServerAddress $serverAddress -Port $authPort
    }
    return [pscustomobject]@{
        NodeType = $Install.Type
        Version = $version
        InstallPath = $Install.Path
        ClusterName = $clusterName
        ServerAddress = $serverAddress
        HttpsEnabled = $httpsEnabled
        AuthPort = $authPort
        ClusterReachable = $reachable
        NodeLicense = $nodeLicense
        MemMax = [string](Get-ConfigProperty -ConfigPath $configPath -PropertyName 'MEM_MAX')
        MemMin = [string](Get-ConfigProperty -ConfigPath $configPath -PropertyName 'MEM_MIN')
        IntegratedSecurity = (Test-Path 'C:\Windows\System32\sqljdbc_auth.dll')
        Drivers = @()
        InstallService = ($Install.ServiceState -ne 'not registered')
        KeystorePassword = $null
        SysPassword = $null
        RestoreFrom = $null
        RestoreKeystore = $false
    }
}

function Invoke-MaintenanceVerify {
    # Maintenance [1]: run every Test, change nothing.
    param([Parameter(Mandatory)][object]$Install)
    $interview = ConvertTo-InterviewFromInstall -Install $Install
    $plan = [pscustomobject]@{
        PlanFormatVersion = 1; Mode = 'Install'; CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Interview = $interview
        Needs = [pscustomobject]@{ Java17 = $false; VcRedist = $false; OleDb = $false }
        Actions = @(); Warnings = @()
    }
    $results = Invoke-StepList -Steps (Get-VerifySteps -Plan $plan) -Mode Verify
    Show-SummaryCard -Results $results
    Show-NextSteps -Plan $plan
}

function Invoke-MaintenanceAddDrivers {
    # Maintenance [2]: driver checklist -> mini-plan -> review -> elevate -> execute (same engine).
    param([Parameter(Mandatory)][object]$Install)
    $interview = ConvertTo-InterviewFromInstall -Install $Install
    $interview.Drivers = @(Read-JdbcDriverSelection)
    if (@($interview.Drivers).Count -eq 0) { Write-Log -Level Info -Message 'No drivers selected.'; return }
    $plan = New-InstallPlan -Interview $interview -Probes (Get-SystemProbes) -Mode 'Drivers'
    Show-PlanReview -Plan $plan
    if (Confirm-UserChoice -Prompt 'Proceed?' -DefaultChoice 'y') { Invoke-PlanHandoff -Plan $plan }
}

function Invoke-MaintenanceUpdateSettings {
    # Maintenance [3]: conflict-aware settings update. Shows agent.conf + wrapper.conf, defaults to
    # agent.conf on Enter, rewrites BOTH files (Write-AgentConfig now syncs wrapper.conf), restarts.
    param([Parameter(Mandatory)][object]$Install)
    $interview = ConvertTo-InterviewFromInstall -Install $Install
    $settings = Read-SettingsInterview -Install $Install -Defaults $interview
    $interview.ClusterName = $settings.ClusterName
    $interview.ServerAddress = $settings.ServerAddress
    $interview.HttpsEnabled = $settings.HttpsEnabled
    $interview.AuthPort = $settings.AuthPort
    $interview.ClusterReachable = $settings.ClusterReachable
    $interview.MemMax = $settings.MemMax
    $interview.MemMin = $settings.MemMin
    if ($Install.Type -eq 'N') { $interview.NodeLicense = Read-NodeLicenseSettings }
    $plan = New-InstallPlan -Interview $interview -Probes (Get-SystemProbes) -Mode 'Reconfigure'
    Show-PlanReview -Plan $plan
    if (Confirm-UserChoice -Prompt 'Proceed?' -DefaultChoice 'y') { Invoke-PlanHandoff -Plan $plan }
}

function Get-StriimServiceCim {
    # Win32_Service gives State + StartName (account) + ProcessId; fall back to DisplayName because SCM
    # may store yajsw's internal name as Name. Returns $null when not registered.
    param([Parameter(Mandatory)][string]$ServiceName)
    $svc = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
    if ($null -eq $svc) { $svc = Get-CimInstance Win32_Service -Filter "DisplayName='$ServiceName'" -ErrorAction SilentlyContinue }
    return $svc
}

function Invoke-MaintenanceManageService {
    # Maintenance [4]: live service status + Start/Stop/Restart. Actions ride the plan engine
    # (Mode='Service') through the single-UAC Invoke-PlanHandoff - the script param() block has no
    # command passthrough, so bare 'Start-Process -Verb RunAs -Command' would lose all script functions.
    param([Parameter(Mandatory)][object]$Install)
    $artifacts = Get-ProfileArtifacts -NodeType $Install.Type
    $serviceName = $artifacts.ServiceName
    while ($true) {
        $svc = Get-StriimServiceCim -ServiceName $serviceName
        $state = if ($svc) { $svc.State } else { 'not registered' }
        Write-Host "`n--- Service: $serviceName ---" -ForegroundColor Cyan
        Write-Host ("  Status:  {0}" -f $state)
        if ($svc) {
            Write-Host ("  Account: {0}" -f $svc.StartName)
            if ($state -eq 'Running') { Write-Host ("  PID:     {0}" -f $svc.ProcessId) }
        }
        Write-Host ''
        Write-Host '  [1] Start'
        Write-Host '  [2] Stop'
        Write-Host '  [3] Restart'
        Write-Host '  [0] Back'
        $choice = (Read-Host -Prompt 'Select').Trim()
        # switch-as-expression so the 'continue' below sits in the while body, not inside the switch
        # (continue/break inside a switch nested in a loop is ambiguous in PowerShell).
        $action = switch ($choice) {
            '1' { 'Start' }
            '2' { 'Stop' }
            '3' { 'Restart' }
            '0' { return }
            default { $null }
        }
        if ($null -eq $action) { Write-Log -Level Warn -Message 'Invalid selection.'; continue }
        # Guard conditions - no plan spawned when the action is a no-op or the state is transitional.
        if ($null -eq $svc) { Write-Log -Level Warn -Message "Service '$serviceName' is not registered - nothing to $action."; continue }
        # Win32_Service.State uses space-separated values ('Start Pending'), not the Get-Service enum.
        if ($state -in @('Start Pending', 'Stop Pending', 'Pause Pending', 'Continue Pending')) {
            Write-Log -Level Warn -Message "Service is in a transitional state ($state) - try again in a moment."; continue
        }
        if ($action -eq 'Start' -and $state -eq 'Running') { Write-Log -Level Info -Message 'Service is already running.'; continue }
        if ($action -eq 'Stop' -and $state -eq 'Stopped') { Write-Log -Level Info -Message 'Service is already stopped.'; continue }

        $interview = ConvertTo-InterviewFromInstall -Install $Install
        $plan = [pscustomobject]@{
            PlanFormatVersion = 1; Mode = 'Service'; CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
            Interview = $interview
            Needs = [pscustomobject]@{ Java17 = $false; VcRedist = $false; OleDb = $false }
            Actions = @(); Warnings = @()
            Service = [pscustomobject]@{ ServiceAction = $action }
        }
        Invoke-PlanHandoff -Plan $plan
    }
}

function New-ConfigBackupChoice {
    # Shared pre-removal backup decision for the destructive maintenance flows (spec 2.7 item 2).
    # -Required (Upgrade) skips the prompt: the backup is the carrier of the restored settings.
    param(
        [Parameter(Mandatory)][object]$Install,
        [Parameter(Mandatory)][string]$FlowName,
        [switch]$Required
    )
    $artifacts = Get-ProfileArtifacts -NodeType $Install.Type
    $drive = [System.IO.Path]::GetPathRoot($Install.Path)   # e.g. 'C:\'
    $backupRoot = Join-Path $drive 'striim_backups'
    $versionLabel = if ([string]::IsNullOrWhiteSpace([string]$Install.Version)) { 'unknown' } else { $Install.Version }
    $backupDir = Join-Path $backupRoot ('{0}_{1}_{2}' -f $FlowName, $versionLabel, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $doBackup = $true
    if ($Required) {
        Write-Log -Level Info -Message "Config, keystore, and non-default lib\ jars will be backed up to $backupDir first."
    } else {
        $doBackup = Confirm-UserChoice -Prompt "Back up $($artifacts.ConfigFile | Split-Path -Leaf), the keystore pair, log4j config, and non-default lib\ jars to $backupDir first?" -DefaultChoice 'y'
    }
    return [pscustomobject]@{
        DoBackup = $doBackup; BackupRoot = $backupRoot; BackupDir = $backupDir
        InstallPath = $Install.Path; NodeType = $Install.Type
    }
}

function Invoke-MaintenanceCleanReinstall {
    # Maintenance [4]: full interview (the wizard pre-fills nothing risky), purge-first plan, same engine.
    # The purge destroys conf + keystore, so the same pre-removal backup as uninstall is offered first;
    # the interview then offers prior backups (including older ones) as the seed for the new install.
    param([Parameter(Mandatory)][object]$Install)
    Write-Log -Level Warn -Message "Clean reinstall clears $($Install.Path) except downloads\, logs\, and scripts."
    if (-not (Confirm-UserChoice -Prompt 'Continue with a clean reinstall?' -DefaultChoice 'n')) { return }
    $backup = New-ConfigBackupChoice -Install $Install -FlowName 'reinstall'
    $interview = Read-InstallInterview
    $plan = New-InstallPlan -Interview $interview -Probes (Get-SystemProbes) -Mode 'Reinstall' -Backup $backup
    Show-PlanReview -Plan $plan
    if (Confirm-UserChoice -Prompt 'Proceed?' -DefaultChoice 'y') { Invoke-PlanHandoff -Plan $plan }
}

function Invoke-MaintenanceUpgrade {
    # Maintenance [5]: the official upgrade procedure as one plan - settings are read from the
    # live config BEFORE anything is touched, then: mandatory backup -> stop + deregister the old
    # service (the wrapper is version-specific) -> purge -> install the new version -> restore
    # keystore + log4j config + non-default jars. Cluster identity is preserved by construction.
    param([Parameter(Mandatory)][object]$Install)
    $interview = ConvertTo-InterviewFromInstall -Install $Install
    $artifacts = Get-ProfileArtifacts -NodeType $Install.Type
    $installedVersion = $interview.Version
    Write-Host ("`nInstalled version: {0}. Enter the version to upgrade to." -f $installedVersion) -ForegroundColor Cyan
    $targetVersion = Read-StriimVersion -NodeType $Install.Type
    $current = ConvertTo-StriimVersion -VersionString $interview.Version
    $target = ConvertTo-StriimVersion -VersionString $targetVersion
    if ($current -and $target -and $target -le $current) {
        Write-Log -Level Warn -Message "Target $targetVersion is not newer than the installed $($interview.Version)."
        if (-not (Confirm-UserChoice -Prompt 'Continue anyway (effectively a reinstall at that version)?' -DefaultChoice 'n')) { return }
    }
    if ($Install.Type -eq 'N' -and $null -eq $interview.NodeLicense) {
        Write-Log -Level Warn -Message 'Node license properties are incomplete in the current config - please confirm them.'
        $interview.NodeLicense = Read-NodeLicenseSettings
    }
    $backup = New-ConfigBackupChoice -Install $Install -FlowName 'upgrade' -Required
    $interview.Version = $targetVersion
    $interview.RestoreFrom = $backup.BackupDir
    $interview.RestoreKeystore = (Test-Path (Join-Path $Install.Path $artifacts.JksFile)) -and
                                 (Test-Path (Join-Path $Install.Path $artifacts.PwdFile))
    if (-not $interview.RestoreKeystore) {
        Write-Log -Level Warn -Message 'No keystore pair found in the current install - a new keystore will be generated interactively at the end.'
    }
    $plan = New-InstallPlan -Interview $interview -Probes (Get-SystemProbes) -Mode 'Upgrade' -Backup $backup
    Show-PlanReview -Plan $plan
    if (Confirm-UserChoice -Prompt "Upgrade from $installedVersion to $targetVersion now?" -DefaultChoice 'y') { Invoke-PlanHandoff -Plan $plan }
}

function Remove-PathEntry {
    # Pure: removal counterpart of Update-PathValue - same normalization (case-insensitive
    # compare with trailing-backslash trimming), so the entry is matched however it was written.
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$CurrentPath,
        [Parameter(Mandatory)][string]$Entry
    )
    $normalized = $Entry.TrimEnd('\')
    $kept = @($CurrentPath -split ';' | Where-Object {
        $_ -ne '' -and $_.TrimEnd('\') -ine $normalized
    })
    return ($kept -join ';')
}

function Remove-MachinePathEntry {
    # Machine-scope write requires elevation (we are elevated during Execute). Mirrors Add-MachinePathEntry.
    param([Parameter(Mandatory)][string]$Entry)
    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $updated = Remove-PathEntry -CurrentPath $current -Entry $Entry
    if ($updated -ne $current) {
        [Environment]::SetEnvironmentVariable('Path', $updated, 'Machine')
    }
    Update-SessionEnvironment
}

# "Non-default" jars = the user-added driver set Install-JdbcDriver can place (spec 2.7 item 2).
# Default Striim jars (Platform-<ver>.jar and the bundled third-party set) are not backed up.
$script:NonDefaultJarPatterns = @(
    'mariadb-java-client-*.jar', 'postgresql-*.jar', 'mysql-connector-*.jar',
    'ojdbc*.jar', 't4sqlmx*.jar', 'terajdbc4.jar', 'tdgssconfig.jar', 'vertica-jdbc-*.jar'
)

function Get-NonDefaultLibJars {
    param([Parameter(Mandatory)][string]$LibPath)
    if (-not (Test-Path $LibPath)) { return @() }
    $result = New-Object System.Collections.ArrayList
    foreach ($jar in @(Get-ChildItem -Path $LibPath -Filter '*.jar' -File -ErrorAction SilentlyContinue)) {
        foreach ($pattern in $script:NonDefaultJarPatterns) {
            if ($jar.Name -like $pattern) { [void]$result.Add($jar); break }
        }
    }
    return @($result)
}

function Get-Log4jConfigFiles {
    # Customer-customizable logging config to preserve across uninstall/reinstall/upgrade:
    # every conf\log4j*.properties (agent: log4j.agent.properties; node: log4j.console/server/
    # upgrade.properties). The *.distribute shipped templates are EXCLUDED - only live
    # .properties files are matched. Returns relative paths (conf\<name>) so a live install
    # (backup source) and a backup dir (restore source) enumerate identically.
    param([Parameter(Mandatory)][string]$RootPath)
    $confDir = Join-Path $RootPath 'conf'
    if (-not (Test-Path $confDir -PathType Container)) { return @() }
    return @(Get-ChildItem -Path $confDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'log4j*' -and $_.Extension -eq '.properties' } |
        ForEach-Object { "conf\$($_.Name)" })
}

function Backup-StriimConfig {
    # Spec 2.7 item 2: pre-removal backup of agent.conf/startUp.properties, the keystore pair
    # (aks.jks+aksKey.pwd / sks.*, per Get-ProfileArtifacts), the log4j*.properties logging
    # config, and non-default jars in lib\.
    # backup-manifest.txt is written LAST - its presence is the step's completion marker.
    param(
        [Parameter(Mandatory)][string]$InstallPath,
        [Parameter(Mandatory)][ValidateSet('A', 'N')][string]$NodeType,
        [Parameter(Mandatory)][string]$BackupDir
    )
    $artifacts = Get-ProfileArtifacts -NodeType $NodeType
    New-Item -ItemType Directory -Force -Path (Join-Path $BackupDir 'conf') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $BackupDir 'lib') | Out-Null
    $copied = New-Object System.Collections.ArrayList
    foreach ($relative in @($artifacts.ConfigFile, $artifacts.JksFile, $artifacts.PwdFile)) {
        $source = Join-Path $InstallPath $relative
        if (Test-Path $source) {
            Copy-Item -Path $source -Destination (Join-Path $BackupDir $relative) -Force
            [void]$copied.Add($relative)
        } else {
            Write-Log -Level Warn -Message "Backup: $relative not found under $InstallPath - skipped."
        }
    }
    foreach ($relative in @(Get-Log4jConfigFiles -RootPath $InstallPath)) {
        Copy-Item -Path (Join-Path $InstallPath $relative) -Destination (Join-Path $BackupDir $relative) -Force
        [void]$copied.Add($relative)
    }
    foreach ($jar in @(Get-NonDefaultLibJars -LibPath (Join-Path $InstallPath 'lib'))) {
        Copy-Item -Path $jar.FullName -Destination (Join-Path $BackupDir 'lib') -Force
        [void]$copied.Add("lib\$($jar.Name)")
    }
    Set-Content -Path (Join-Path $BackupDir 'backup-manifest.txt') -Value (
        @("Backed up from $InstallPath on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") + @($copied))
    return $BackupDir
}

function Start-UninstallTranscript {
    # The install dir (the normal transcript home) is about to be deleted - the uninstall
    # transcript lives beside the backup dir instead (spec 2.7 item 9 still reports its path).
    param([Parameter(Mandatory)][string]$BackupRoot)
    if (-not (Test-Path $BackupRoot)) { New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null }
    $script:TranscriptPath = Join-Path $BackupRoot ('uninstall-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Start-Transcript -Path $script:TranscriptPath -Append | Out-Null
    Write-Log -Level Info -Message "Transcript started: $script:TranscriptPath"
    return $script:TranscriptPath
}

function Stop-StriimServiceForce {
    # Spec 2.7 item 3: Stop-Service with a 30 s timeout, then force-kill the yajsw wrapper
    # java process (identified by the install path appearing in its command line).
    param(
        [Parameter(Mandatory)][string]$ServiceName,
        [Parameter(Mandatory)][string]$InstallPath,
        [int]$TimeoutSeconds = 30
    )
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $svc) { return }
    if ($svc.Status -ne 'Stopped') {
        try {
            Stop-Service -Name $ServiceName -Force -ErrorAction Stop
            $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($TimeoutSeconds))
        } catch {
            Write-Log -Level Warn -Message "Service '$ServiceName' did not stop within $TimeoutSeconds s - force-killing the wrapper java process."
        }
    }
    $svc.Refresh()
    if ($svc.Status -ne 'Stopped') {
        $escaped = [regex]::Escape($InstallPath)
        $wrappers = @(Get-CimInstance Win32_Process -Filter "Name = 'java.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match $escaped })
        foreach ($proc in $wrappers) {
            Write-Log -Level Warn -Message "Killing wrapper process PID $($proc.ProcessId)."
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
}

function Uninstall-StriimWindowsService {
    # Spec 2.7 item 4. yajsw bats require cwd = their folder and run via cmd /c (field lore,
    # same pattern as Invoke-KeystoreConfig). Agent: conf\windowsAgent\yajsw_agent\bat\
    # uninstallService.bat; Node: the equivalent under conf\windowsService - found by a
    # recursive search of the profile's ServiceConfigDir so yajsw layout drift cannot break it.
    # Fallback: sc.exe delete. Removal is confirmed via Get-Service.
    param([Parameter(Mandatory)][object]$Plan)
    $iv = $Plan.Interview
    $artifacts = Get-ProfileArtifacts -NodeType $iv.NodeType
    $serviceName = $artifacts.ServiceName
    if ($null -eq (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) { return }

    $serviceConfigDir = Join-Path $iv.InstallPath $artifacts.ServiceConfigDir
    $bat = $null
    if (Test-Path $serviceConfigDir) {
        $bat = Get-ChildItem -Path $serviceConfigDir -Recurse -Filter 'uninstallService.bat' -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }
    if (-not $bat) {
        # ServiceConfigDir missing/empty (e.g. a prior attempt registered the service but never
        # extracted its wrapper) - the SCM's real service name doesn't always match $serviceName
        # (see Get-StriimServiceCim's DisplayName fallback), so a raw sc.exe delete below can miss
        # it; re-extract the wrapper so its own uninstallService.bat can find and remove it correctly.
        $zipPath = Get-ServiceWrapperZipPath -Interview $iv
        if (Test-Path $zipPath) {
            if (Test-Path $serviceConfigDir) { Remove-Item -Path $serviceConfigDir -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $serviceConfigDir | Out-Null
            Expand-StriimArchive -ZipPath $zipPath -Destination $serviceConfigDir -PreserveNames @()
            $bat = Get-ChildItem -Path $serviceConfigDir -Recurse -Filter 'uninstallService.bat' -ErrorAction SilentlyContinue |
                Select-Object -First 1
        }
    }
    if ($bat) {
        Push-Location $bat.DirectoryName
        try {
            & cmd.exe /c "`"$($bat.FullName)`""
            if ($LASTEXITCODE -ne 0) {
                Write-Log -Level Warn -Message "uninstallService.bat exited with code $LASTEXITCODE - falling back to sc.exe delete."
            }
        } finally {
            Pop-Location
        }
    } else {
        Write-Log -Level Warn -Message "uninstallService.bat not found under $serviceConfigDir - falling back to sc.exe delete."
    }
    if ($null -ne (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
        & sc.exe delete "$serviceName" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "sc.exe delete '$serviceName' failed with code $LASTEXITCODE." }
    }
    # SCM removal can lag a beat after delete - poll briefly before declaring success.
    for ($i = 0; $i -lt 10; $i++) {
        if ($null -eq (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) { return }
        Start-Sleep -Milliseconds 500
    }
    throw "Service '$serviceName' is still registered after deregistration attempts."
}

function Remove-StriimInstallDirectory {
    # Spec 2.7 item 5: the backup dir lives OUTSIDE the install dir (<drive>:\striim_backups\)
    # so it survives by construction; downloads\ is optionally relocated next to the backup dir
    # (its parent is being deleted) before the tree goes.
    param([Parameter(Mandatory)][object]$Plan)
    $iv = $Plan.Interview
    $un = $Plan.Uninstall
    if (-not (Test-Path $iv.InstallPath)) { return }
    if ($un.KeepDownloads) {
        $downloads = Join-Path $iv.InstallPath 'downloads'
        if (Test-Path $downloads) {
            $dest = "$($un.BackupDir)_downloads"
            New-Item -ItemType Directory -Force -Path $un.BackupRoot | Out-Null
            if (Test-Path $dest) { Remove-Item -Path $dest -Recurse -Force }
            Move-Item -Path $downloads -Destination $dest
            Write-Log -Level Info -Message "downloads\ kept at $dest (reusable for a future install)."
        }
    }
    Remove-Item -Path $iv.InstallPath -Recurse -Force
}

function New-UninstallStepList {
    # Spec 2.7 as a step list on the section-3 engine - same objects, loop, and failure menu.
    param([Parameter(Mandatory)][object]$Plan)
    $iv = $Plan.Interview
    $un = $Plan.Uninstall
    $artifacts = Get-ProfileArtifacts -NodeType $iv.NodeType
    $libPath = Join-Path $iv.InstallPath 'lib'
    $steps = New-Object System.Collections.ArrayList

    if ($un.DoBackup) {
        [void]$steps.Add((New-InstallStep -Name "Back up config, keystore, log4j, and non-default jars -> $($un.BackupDir)" -Test {
            Test-Path (Join-Path $un.BackupDir 'backup-manifest.txt')
        }.GetNewClosure() -Action {
            Backup-StriimConfig -InstallPath $iv.InstallPath -NodeType $iv.NodeType -BackupDir $un.BackupDir | Out-Null
        }.GetNewClosure()))
    }

    [void]$steps.Add((New-InstallStep -Name "Stop '$($artifacts.ServiceName)' service" -Test {
        $svc = Get-Service -Name $artifacts.ServiceName -ErrorAction SilentlyContinue
        ($null -eq $svc) -or ($svc.Status -eq 'Stopped')
    }.GetNewClosure() -Action {
        Stop-StriimServiceForce -ServiceName $artifacts.ServiceName -InstallPath $iv.InstallPath
    }.GetNewClosure()))

    [void]$steps.Add((New-InstallStep -Name "Deregister '$($artifacts.ServiceName)' Windows service" -Critical -Test {
        $null -eq (Get-Service -Name $artifacts.ServiceName -ErrorAction SilentlyContinue)
    }.GetNewClosure() -Action {
        Uninstall-StriimWindowsService -Plan $Plan
    }.GetNewClosure()))

    $removeName = if ($un.KeepDownloads) { "Remove $($iv.InstallPath) (keeping downloads\ beside the backup dir)" }
                  else { "Remove $($iv.InstallPath)" }
    [void]$steps.Add((New-InstallStep -Name $removeName -Critical -Test {
        -not (Test-Path $iv.InstallPath)
    }.GetNewClosure() -Action {
        Remove-StriimInstallDirectory -Plan $Plan
    }.GetNewClosure()))

    [void]$steps.Add((New-InstallStep -Name "Remove $libPath from the system PATH" -Test {
        $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        (Remove-PathEntry -CurrentPath $machine -Entry $libPath) -eq $machine
    }.GetNewClosure() -Action {
        Remove-MachinePathEntry -Entry $libPath
    }.GetNewClosure()))

    if ($un.RemoveAuthDll) {
        [void]$steps.Add((New-InstallStep -Name 'Remove sqljdbc_auth.dll from C:\Windows\System32' -Test {
            -not (Test-Path 'C:\Windows\System32\sqljdbc_auth.dll')
        } -Action {
            Remove-Item -Path 'C:\Windows\System32\sqljdbc_auth.dll' -Force
        }))
    }
    return @($steps)
}

function Show-UninstallScopeCard {
    # Spec 2.7 item 1: exactly what will be removed vs. kept, shown BEFORE the default-No confirm.
    param([Parameter(Mandatory)][object]$Plan)
    $iv = $Plan.Interview
    $un = $Plan.Uninstall
    $artifacts = Get-ProfileArtifacts -NodeType $iv.NodeType
    $libPath = Join-Path $iv.InstallPath 'lib'
    Write-Host ''
    Write-Host ('+' + ('-' * 72)) -ForegroundColor Cyan
    Write-Host ("| UNINSTALL PLAN - Striim {0} {1} at {2}" -f $artifacts.ProfileName, $iv.Version, $iv.InstallPath) -ForegroundColor White
    Write-Host '| Will REMOVE:' -ForegroundColor Red
    Write-Host ("|   - Windows service '{0}' (stopped, then deregistered)" -f $artifacts.ServiceName)
    Write-Host ("|   - {0} (entire directory)" -f $iv.InstallPath)
    Write-Host ("|   - {0} entry on the machine PATH" -f $libPath)
    if ($un.RemoveAuthDll) { Write-Host '|   - C:\Windows\System32\sqljdbc_auth.dll' }
    Write-Host '| Will KEEP:' -ForegroundColor Green
    if ($un.DoBackup) { Write-Host ("|   - Backup of config, keystore, log4j, and non-default jars -> {0}" -f $un.BackupDir) }
    if ($un.KeepDownloads) { Write-Host ("|   - downloads\ cache -> {0}_downloads" -f $un.BackupDir) }
    if (-not $un.RemoveAuthDll) { Write-Host '|   - C:\Windows\System32\sqljdbc_auth.dll (other SQL tooling may use it)' }
    Write-Host '|   - Shared components: Java 17, VC++ redistributable, MS OLE DB driver (manual removal hints in the summary)'
    Write-Host ('+' + ('-' * 72)) -ForegroundColor Cyan
}

function Show-UninstallSummary {
    # Spec 2.7 items 8-9: what was kept, the deliberate leave-behinds with one-line manual
    # removal hints, the backup location, and the transcript path.
    param([Parameter(Mandatory)][object]$Plan)
    $un = $Plan.Uninstall
    Write-Host "`n Kept on this machine:" -ForegroundColor Cyan
    if ($un.DoBackup) { Write-Host ("  Backup:    {0}" -f $un.BackupDir) }
    if ($un.KeepDownloads) { Write-Host ("  Downloads: {0}_downloads" -f $un.BackupDir) }
    Write-Host "`n Shared components deliberately left in place (other software may depend on them):" -ForegroundColor Cyan
    Write-Host '  - Java 17 (Microsoft Build of OpenJDK): Settings > Apps > "Microsoft Build of OpenJDK 17" > Uninstall'
    Write-Host '  - Visual C++ 2015-2019 Redistributable (x64): Settings > Apps > "Microsoft Visual C++ 2015-2019 Redistributable (x64)" > Uninstall'
    Write-Host '  - Microsoft OLE DB Driver for SQL Server: Settings > Apps > "Microsoft OLE DB Driver for SQL Server" > Uninstall'
    if ($script:TranscriptPath) {
        Write-Host ("`n Uninstall transcript: {0}" -f $script:TranscriptPath) -ForegroundColor Cyan
    }
}

function Invoke-MaintenanceUninstall {
    # Maintenance [6]: all questions are answered unelevated, then the plan rides the same
    # Invoke-PlanHandoff single-UAC handoff (spec 2.4) as every other elevated flow.
    param([Parameter(Mandatory)][object]$Install)
    $interview = ConvertTo-InterviewFromInstall -Install $Install
    $artifacts = Get-ProfileArtifacts -NodeType $Install.Type
    $drive = [System.IO.Path]::GetPathRoot($Install.Path)   # e.g. 'C:\'
    $backupRoot = Join-Path $drive 'striim_backups'
    $backupDir = Join-Path $backupRoot ('uninstall_{0}_{1}' -f $Install.Version, (Get-Date -Format 'yyyyMMdd-HHmmss'))

    $doBackup = Confirm-UserChoice -Prompt "Back up $($artifacts.ConfigFile | Split-Path -Leaf), the keystore pair, and non-default lib\ jars to $backupDir first?" -DefaultChoice 'y'
    $keepDownloads = $false
    if (Test-Path (Join-Path $Install.Path 'downloads')) {
        $keepDownloads = Confirm-UserChoice -Prompt 'Keep the downloads\ cache (useful for a future reinstall; it will move next to the backup dir)?' -DefaultChoice 'y'
    }
    $removeAuthDll = $false
    if (Test-Path 'C:\Windows\System32\sqljdbc_auth.dll') {
        $removeAuthDll = Confirm-UserChoice -Prompt 'Also remove sqljdbc_auth.dll from System32? Other SQL tooling on this box may use it.' -DefaultChoice 'n'
    }

    $plan = [pscustomobject]@{
        PlanFormatVersion = 1; Mode = 'Uninstall'; CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Interview = $interview
        Needs = [pscustomobject]@{ Java17 = $false; VcRedist = $false; OleDb = $false }
        Actions = @(); Warnings = @()
        Uninstall = [pscustomobject]@{
            ServiceName = $artifacts.ServiceName
            DoBackup = $doBackup; KeepDownloads = $keepDownloads; RemoveAuthDll = $removeAuthDll
            BackupRoot = $backupRoot; BackupDir = $backupDir
        }
    }
    Show-UninstallScopeCard -Plan $plan
    if (-not (Confirm-UserChoice -Prompt "Remove this Striim $($artifacts.ProfileName) and its Windows service?" -DefaultChoice 'n')) {
        Write-Log -Level Info -Message 'Uninstall cancelled. Nothing was changed.'
        return
    }
    Invoke-PlanHandoff -Plan $plan
}

function Show-MaintenanceMenu {
    param([Parameter(Mandatory)][object]$Install)
    $typeName = if ($Install.Type -eq 'A') { 'Agent' } else { 'Node' }
    $verLabel = if ($Install.Version) { $Install.Version } else { '(version unknown - no Platform jar in lib\)' }
    while ($true) {
        Write-Host ("`nExisting Striim $typeName $verLabel at $($Install.Path) (service: $($Install.ServiceState))") -ForegroundColor Cyan
        Write-Host '  [1] Verify install health'
        Write-Host '  [2] Add/refresh JDBC drivers'
        Write-Host '  [3] Update Striim settings'
        Write-Host '  [4] Manage service'
        Write-Host '  [5] Clean reinstall'
        Write-Host '  [6] Upgrade version'
        Write-Host '  [7] Uninstall'
        Write-Host '  [8] New install (full interview - another path, or over this install)'
        Write-Host '  [0] Exit'
        $choice = (Read-Host -Prompt 'Select').Trim()
        switch ($choice) {
            '1' { Invoke-MaintenanceVerify -Install $Install }
            '2' { Invoke-MaintenanceAddDrivers -Install $Install }
            '3' { Invoke-MaintenanceUpdateSettings -Install $Install }
            '4' { Invoke-MaintenanceManageService -Install $Install }
            '5' { Invoke-MaintenanceCleanReinstall -Install $Install }
            '6' { Invoke-MaintenanceUpgrade -Install $Install; return }
            '7' { Invoke-MaintenanceUninstall -Install $Install; return }
            '8' { Invoke-FreshInstallFlow -ExistingInstall $Install; return }
            '0' { return }
            default { Write-Log -Level Warn -Message 'Invalid selection.' }
        }
    }
}
#endregion Maintenance

#region Main
function Get-ConfigBackupSteps {
    # 0-or-1 step: the pre-removal backup carried in the plan's Backup section
    # (same Test/Action as the uninstall flow's backup step - manifest marks completion).
    param(
        [Parameter(Mandatory)][object]$Plan,
        [switch]$Critical
    )
    if (-not ($Plan.PSObject.Properties['Backup'] -and $Plan.Backup -and $Plan.Backup.DoBackup)) { return @() }
    $bk = $Plan.Backup
    return @(New-InstallStep -Name "Back up config, keystore, log4j, and non-default jars -> $($bk.BackupDir)" -Critical:$Critical -Test {
        Test-Path (Join-Path $bk.BackupDir 'backup-manifest.txt')
    }.GetNewClosure() -Action {
        Backup-StriimConfig -InstallPath $bk.InstallPath -NodeType $bk.NodeType -BackupDir $bk.BackupDir | Out-Null
    }.GetNewClosure())
}

function Get-ExecutionSteps {
    # Maintenance flows are smaller step lists on the same engine, same logging, same failure menu.
    param([Parameter(Mandatory)][object]$Plan)
    $iv = $Plan.Interview
    $artifacts = Get-ProfileArtifacts -NodeType $iv.NodeType
    switch ($Plan.Mode) {
        'Install' { return @(Get-InstallSteps -Plan $Plan) }
        'Reinstall' {
            $steps = New-Object System.Collections.ArrayList
            foreach ($s in (Get-ConfigBackupSteps -Plan $Plan)) { [void]$steps.Add($s) }
            [void]$steps.Add((New-InstallStep -Name "Clean $($iv.InstallPath) (preserving downloads\ and scripts)" -Critical -Test {
                -not (Test-StriimInstallDir -Path $iv.InstallPath).IsInstall
            }.GetNewClosure() -Action {
                Clear-InstallDirectory -Path $iv.InstallPath
            }.GetNewClosure()))
            foreach ($s in (Get-InstallSteps -Plan $Plan)) { [void]$steps.Add($s) }
            return @($steps)
        }
        'Upgrade' {
            $steps = New-Object System.Collections.ArrayList
            # Backup first (Critical - it carries the keystore + jars the restore step copies back).
            foreach ($s in (Get-ConfigBackupSteps -Plan $Plan -Critical)) { [void]$steps.Add($s) }
            [void]$steps.Add((New-InstallStep -Name "Stop '$($artifacts.ServiceName)' service" -Test {
                $svc = Get-Service -Name $artifacts.ServiceName -ErrorAction SilentlyContinue
                ($null -eq $svc) -or ($svc.Status -eq 'Stopped')
            }.GetNewClosure() -Action {
                Stop-StriimServiceForce -ServiceName $artifacts.ServiceName -InstallPath $iv.InstallPath
            }.GetNewClosure()))
            # The yajsw wrapper is version-specific: deregister now, New-ServiceStep re-registers
            # the new version's wrapper later in the install step list.
            [void]$steps.Add((New-InstallStep -Name "Deregister '$($artifacts.ServiceName)' Windows service (old wrapper)" -Critical -Test {
                $null -eq (Get-Service -Name $artifacts.ServiceName -ErrorAction SilentlyContinue)
            }.GetNewClosure() -Action {
                Uninstall-StriimWindowsService -Plan $Plan
            }.GetNewClosure()))
            [void]$steps.Add((New-InstallStep -Name "Clean $($iv.InstallPath) (preserving downloads\ and scripts)" -Critical -Test {
                -not (Test-StriimInstallDir -Path $iv.InstallPath).IsInstall
            }.GetNewClosure() -Action {
                Clear-InstallDirectory -Path $iv.InstallPath
            }.GetNewClosure()))
            foreach ($s in (Get-InstallSteps -Plan $Plan)) { [void]$steps.Add($s) }
            return @($steps)
        }
        'Drivers' {
            $steps = New-Object System.Collections.ArrayList
            [void]$steps.Add((New-DownloadBatchStep -Plan $Plan))
            foreach ($s in (Get-JdbcDriverSteps -Plan $Plan)) { [void]$steps.Add($s) }
            # Do-once restart: a running service must still be restarted to pick up new jars,
            # so the Test only passes when no service is registered or the Action already ran.
            $restartState = @{ Done = $false }
            [void]$steps.Add((New-InstallStep -Name "Restart '$($artifacts.ServiceName)' service" -Test {
                $restartState.Done -or ($null -eq (Get-Service -Name $artifacts.ServiceName -ErrorAction SilentlyContinue))
            }.GetNewClosure() -Action {
                Restart-Service -Name $artifacts.ServiceName -Force
                $restartState.Done = $true
            }.GetNewClosure()))
            return @($steps)
        }
        'Uninstall' { return @(New-UninstallStepList -Plan $Plan) }
        'Reconfigure' {
            $steps = New-Object System.Collections.ArrayList
            [void]$steps.Add((New-ConfigStep -Plan $Plan))
            # Do-once restart: a running service must still be restarted to load the new config,
            # so the Test only passes when no service is registered or the Action already ran.
            $restartState = @{ Done = $false }
            [void]$steps.Add((New-InstallStep -Name "Restart '$($artifacts.ServiceName)' service" -Test {
                $restartState.Done -or ($null -eq (Get-Service -Name $artifacts.ServiceName -ErrorAction SilentlyContinue))
            }.GetNewClosure() -Action {
                Restart-Service -Name $artifacts.ServiceName -Force
                $restartState.Done = $true
            }.GetNewClosure()))
            return @($steps)
        }
        'Service' {
            # Start/Stop/Restart on the same engine. Stop uses Stop-StriimServiceForce (30s timeout +
            # java.exe force-kill for hung yajsw wrappers) - never bare Stop-Service.
            $action = $Plan.Service.ServiceAction
            $steps = New-Object System.Collections.ArrayList
            if ($action -in @('Stop', 'Restart')) {
                [void]$steps.Add((New-InstallStep -Name "Stop '$($artifacts.ServiceName)' service" -Test {
                    $svc = Get-Service -Name $artifacts.ServiceName -ErrorAction SilentlyContinue
                    ($null -eq $svc) -or ($svc.Status -eq 'Stopped')
                }.GetNewClosure() -Action {
                    Stop-StriimServiceForce -ServiceName $artifacts.ServiceName -InstallPath $iv.InstallPath
                }.GetNewClosure()))
            }
            if ($action -in @('Start', 'Restart')) {
                [void]$steps.Add((New-InstallStep -Name "Start '$($artifacts.ServiceName)' service" -Test {
                    $svc = Get-Service -Name $artifacts.ServiceName -ErrorAction SilentlyContinue
                    ($null -ne $svc) -and ($svc.Status -eq 'Running')
                }.GetNewClosure() -Action {
                    Start-Service -Name $artifacts.ServiceName
                }.GetNewClosure()))
            }
            return @($steps)
        }
    }
    throw "Unknown plan mode '$($Plan.Mode)'."
}

function Invoke-PlanExecution {
    # The Execute + Verify phases. Runs elevated (via -PlanFile relaunch or already-admin).
    param([Parameter(Mandatory)][object]$Plan)
    $iv = $Plan.Interview
    if ($Plan.Mode -eq 'Uninstall') {
        # The install dir is about to be deleted - the transcript lives beside the backup instead.
        Start-UninstallTranscript -BackupRoot $Plan.Uninstall.BackupRoot | Out-Null
    } else {
        if (-not (Test-Path $iv.InstallPath)) { New-Item -ItemType Directory -Force -Path $iv.InstallPath | Out-Null }
        Start-InstallTranscript -InstallPath $iv.InstallPath | Out-Null
    }
    try {
        # Echo interview answers into the transcript - passwords excluded by construction.
        Write-Log -Level Info -Message ("Plan: mode={0} version={1} path={2} cluster={3} server={4}:{5} service={6} integratedSecurity={7} drivers=[{8}]" -f `
            $Plan.Mode, $iv.Version, $iv.InstallPath, $iv.ClusterName, $iv.ServerAddress, $iv.AuthPort, $iv.InstallService, $iv.IntegratedSecurity, (@($iv.Drivers | ForEach-Object { $_.Key }) -join ','))
        foreach ($w in $Plan.Warnings) { Write-Log -Level Warn -Message "Plan warning: $w" }
        $results = Invoke-StepList -Steps (Get-ExecutionSteps -Plan $Plan) -Mode Execute
        if ($Plan.Mode -eq 'Uninstall') {
            # Nothing to verify - the install is gone. Summarize removals and leave-behinds instead.
            Show-SummaryCard -Results $results
            Show-UninstallSummary -Plan $Plan
        } elseif ($Plan.Mode -eq 'Service') {
            # A service action - just report the step outcome; the sub-menu refreshes the live header.
            Show-SummaryCard -Results $results
        } else {
            $verifyResults = Invoke-StepList -Steps (Get-VerifySteps -Plan $Plan) -Mode Verify
            Show-SummaryCard -Results $results -VerifyResults $verifyResults
            Show-NextSteps -Plan $Plan
        }
    } finally {
        Stop-InstallTranscript
    }
}

function Invoke-PlanHandoff {
    # Already elevated -> run in-process. Otherwise serialize (DPAPI) and relaunch once via UAC.
    param([Parameter(Mandatory)][object]$Plan)
    if (Test-IsAdmin) {
        Invoke-PlanExecution -Plan $Plan
        return
    }
    $planPath = Join-Path $script:WorkingDir 'install-plan.json'
    if ($script:WorkingDirFallback) {
        Write-Log -Level Warn -Message "Script directory is not writable ($($script:ScriptDir)); using $($script:WorkingDir) for the plan and downloads."
    }
    Save-PlanFile -Plan $Plan -Path $planPath
    Write-Log -Level Info -Message 'One UAC prompt follows - the elevated process executes the whole plan unattended.'
    try {
        $exitCode = Invoke-ElevatedExecution -PlanPath $planPath
        if ($exitCode -ne 0) {
            Write-Log -Level Warn -Message "Elevated installer exited with code $exitCode. Check the transcript under <install>\logs."
        }
        if (Test-Path $planPath) { Remove-Item -Path $planPath -Force -ErrorAction SilentlyContinue }
    } catch {
        Write-Log -Level Warn -Message "UAC elevation failed: $($_.Exception.Message)"
        Write-Log -Level Warn -Message "Your install plan was saved to: $planPath"
        Write-Log -Level Warn -Message "Open an already-elevated PowerShell prompt and run:"
        Write-Log -Level Warn -Message "  & '$($script:ScriptPath)' -PlanFile '$planPath'"
    }
}

function Invoke-FreshInstallFlow {
    # The fresh-install path: interview -> plan -> review -> handoff. Reached when no install
    # is detected, or explicitly via maintenance [7] (broken install, second copy, new path).
    # -ExistingInstall: the detected install; choosing its path again switches to a purge-first
    # reinstall plan (with the same pre-removal backup offer as maintenance [4]).
    param([object]$ExistingInstall = $null)
    $interview = Read-InstallInterview
    $mode = 'Install'
    $backup = $null
    if ($ExistingInstall -and ($interview.InstallPath.TrimEnd('\') -ieq $ExistingInstall.Path.TrimEnd('\'))) {
        Write-Log -Level Warn -Message 'That path holds the detected install - switching to a clean-reinstall plan (purge first, preserving downloads\, logs\, and scripts).'
        $mode = 'Reinstall'
        $backup = New-ConfigBackupChoice -Install $ExistingInstall -FlowName 'reinstall'
    }
    $plan = New-InstallPlan -Interview $interview -Probes (Get-SystemProbes) -Mode $mode -Backup $backup
    Show-PlanReview -Plan $plan
    if (-not (Confirm-UserChoice -Prompt 'Proceed? (approval covers all listed downloads and installs)' -DefaultChoice 'y')) {
        Write-Log -Level Info -Message 'Stopped at plan review. Nothing was changed.'
        return
    }
    Invoke-PlanHandoff -Plan $plan
}

function Invoke-Main {
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'Striim requires 64-bit Windows. This system is 32-bit.'
    }
    Show-Header

    # Branch 1: offline bundling utility mode.
    if ($DownloadOnly) {
        if ([string]::IsNullOrWhiteSpace($Version)) { throw '-Version is required with -DownloadOnly (e.g. -Version 5.4.0.6).' }
        if (($Agent -and $Node) -or (-not $Agent -and -not $Node)) { throw 'Specify exactly one of -Agent or -Node with -DownloadOnly.' }
        $nodeType = if ($Agent) { 'A' } else { 'N' }
        Invoke-DownloadOnly -NodeType $nodeType -TargetVersion $Version -DownloadDir $script:DownloadDir
        return
    }

    # Branch 2: elevated execution phase - no re-asked questions; plan file deleted on completion.
    if ($PlanFile) {
        if (-not (Test-IsAdmin)) { throw 'The -PlanFile execution phase must run elevated (it is launched by the wizard via UAC).' }
        # Follow the plan file's directory for downloads so the elevated process reuses the working
        # dir the (possibly non-admin) parent chose - otherwise, when this process re-probes and finds
        # its own dir writable, downloads would scatter into e.g. C:\Windows\System32\downloads.
        $script:WorkingDir  = Split-Path -Parent $PlanFile
        $script:DownloadDir = Join-Path $script:WorkingDir 'downloads'
        $plan = Read-PlanFile -Path $PlanFile
        try {
            Invoke-PlanExecution -Plan $plan
        } finally {
            Remove-Item -Path $PlanFile -Force -ErrorAction SilentlyContinue
        }
        Read-Host -Prompt 'Press Enter to close this window' | Out-Null
        return
    }

    # Branch 2b: already elevated and a saved plan exists (e.g. prior UAC-blocked attempt).
    # A prior (possibly non-admin) run may have saved the plan beside the script or in the per-user
    # fallback dir - check both so an elevated resume finds it either way.
    $planCandidates = @(
        (Join-Path $script:WorkingDir 'install-plan.json'),
        (Join-Path $script:ScriptDir 'install-plan.json')
    )
    if ($env:LOCALAPPDATA) { $planCandidates += (Join-Path $env:LOCALAPPDATA 'Striim\installer\install-plan.json') }
    $savedPlanPath = $planCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ((Test-IsAdmin) -and $savedPlanPath) {
        Write-Log -Level Info -Message "Found a saved install plan at: $savedPlanPath"
        if (Confirm-UserChoice -Prompt 'Resume from saved plan?' -DefaultChoice 'y') {
            $plan = Read-PlanFile -Path $savedPlanPath
            try {
                Invoke-PlanExecution -Plan $plan
            } finally {
                Remove-Item -Path $savedPlanPath -Force -ErrorAction SilentlyContinue
            }
            Read-Host -Prompt 'Press Enter to close this window' | Out-Null
            return
        }
        Remove-Item -Path $savedPlanPath -Force -ErrorAction SilentlyContinue
    }

    # Branch 3: detect -> maintenance menu (existing install) or interview -> plan -> execute (fresh).
    $installs = @(Find-StriimInstalls)
    if ($installs.Count -gt 0) {
        $install = Select-StriimInstall -Installs $installs
        Show-MaintenanceMenu -Install $install
        return
    }
    Write-Log -Level Info -Message 'No existing Striim installation detected - starting the install interview.'
    Invoke-FreshInstallFlow
}
#endregion Main

# ---- entry point ----
if (-not $NoRun) {
    try {
        Invoke-Main
    } catch {
        Write-Log -Level Error -Message $_.Exception.Message
        if ($script:TranscriptPath) { Write-Log -Level Info -Message "Transcript: $script:TranscriptPath" }
        Stop-InstallTranscript
        exit 1
    }
}
