[CmdletBinding()]
param(
    [ValidateSet('x64', 'x86', 'arm64')]
    [string]$Arch = 'x64',

    [string]$RepoRoot = $PSScriptRoot,

    [string]$DownloadDir = (Join-Path $PSScriptRoot 'downloads'),

    [string]$WorkDir = (Join-Path $PSScriptRoot 'work'),

    [string]$ArtifactDir = (Join-Path $PSScriptRoot 'artifacts'),

    [string]$ChromePlusIniPath,

    [switch]$KeepWorkDir,

    [switch]$SkipArchive,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-RequiredCommand {
    param([string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "Missing required command: $Name"
    }
    return $command.Source
}

function Ensure-Directory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Remove-DirectorySafe {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Invoke-GitHubLatestRelease {
    param([string]$Repository)

    $uri = "https://api.github.com/repos/$Repository/releases/latest"
    return Invoke-RestMethod -Uri $uri
}

function Get-ReleaseAsset {
    param(
        [object]$Release,
        [string[]]$Patterns
    )

    foreach ($pattern in $Patterns) {
        $asset = $Release.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
        if ($asset) {
            return $asset
        }
    }

    $available = ($Release.assets | Select-Object -ExpandProperty name) -join ', '
    throw "No asset matched patterns [$($Patterns -join '; ')] in release $($Release.tag_name). Available assets: $available"
}

function Download-Asset {
    param(
        [object]$Asset,
        [string]$DestinationPath
    )

    if ((Test-Path -LiteralPath $DestinationPath) -and -not $Force) {
        Write-Step "Reusing existing download: $([System.IO.Path]::GetFileName($DestinationPath))"
        return
    }

    Write-Step "Downloading $($Asset.name)"
    Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $DestinationPath
}

function Expand-With7Zip {
    param(
        [string]$SevenZipPath,
        [string]$ArchivePath,
        [string]$DestinationPath
    )

    Ensure-Directory -Path $DestinationPath
    $output = & $SevenZipPath x $ArchivePath "-o$DestinationPath" -y
    if ($LASTEXITCODE -ne 0) {
        throw "7-Zip failed to extract $ArchivePath`n$output"
    }
}

function Find-NestedArchive {
    param([string]$SearchRoot)

    $candidates = Get-ChildItem -LiteralPath $SearchRoot -Recurse -File |
        Where-Object {
            $_.Extension -in '.7z', '.zip' -or $_.Name -match '^chrome\.(7z|zip)$' -or $_.Name -match 'packed'
        } |
        Sort-Object Length -Descending

    if (-not $candidates) {
        throw "Could not find the inner archive after the first extraction in $SearchRoot"
    }

    return $candidates[0].FullName
}

function Find-ChromeRoot {
    param([string]$SearchRoot)

    $chromeExe = Get-ChildItem -LiteralPath $SearchRoot -Recurse -Filter 'chrome.exe' -File | Select-Object -First 1
    if (-not $chromeExe) {
        throw "Could not find chrome.exe under $SearchRoot"
    }

    return $chromeExe.Directory.FullName
}

function Get-ChromePlusPaths {
    param(
        [string]$ExtractRoot,
        [string]$Arch
    )

    $appRoot = Join-Path $ExtractRoot "$Arch\App"
    $versionDll = Join-Path $appRoot 'version.dll'
    $chromeIni = Join-Path $appRoot 'chrome++.ini'

    if (-not (Test-Path -LiteralPath $versionDll)) {
        throw "Chrome++ version.dll not found at $versionDll"
    }

    if (-not (Test-Path -LiteralPath $chromeIni)) {
        throw "Chrome++ config not found at $chromeIni"
    }

    return @{
        VersionDll = $versionDll
        ChromeIni  = $chromeIni
    }
}

function Copy-DirectoryContents {
    param(
        [string]$Source,
        [string]$Destination
    )

    Ensure-Directory -Path $Destination
    Copy-Item -Path (Join-Path $Source '*') -Destination $Destination -Recurse -Force
}

function Copy-ChromePlusFile {
    param(
        [string]$Source,
        [string]$Destination
    )

    try {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    }
    catch {
        $message = $_.Exception.Message
        if ($message -match 'virus' -or $message -match '潜在' -or $message -match '垃圾软件') {
            throw "Windows Security blocked Chrome++ while copying $Source. Add an exclusion for this workspace or restore the file, then rerun the build. Original error: $message"
        }
        throw
    }
}

$sevenZip = Get-RequiredCommand -Name '7z'
Ensure-Directory -Path $DownloadDir
Ensure-Directory -Path $WorkDir
Ensure-Directory -Path $ArtifactDir

$portableRoot = Join-Path $ArtifactDir "ungoogled-chromium-portable-$Arch"
if ((Test-Path -LiteralPath $portableRoot) -and -not $Force) {
    throw "Artifact directory already exists: $portableRoot. Re-run with -Force to replace it."
}

$outerExtractDir = Join-Path $WorkDir "installer-$Arch"
$innerExtractDir = Join-Path $WorkDir "payload-$Arch"
$chromePlusExtractDir = Join-Path $WorkDir "chrome-plus-$Arch"

Remove-DirectorySafe -Path $outerExtractDir
Remove-DirectorySafe -Path $innerExtractDir
Remove-DirectorySafe -Path $chromePlusExtractDir
Remove-DirectorySafe -Path $portableRoot

Write-Step 'Fetching latest release metadata'
$ungoogledRelease = Invoke-GitHubLatestRelease -Repository 'ungoogled-software/ungoogled-chromium-windows'
$chromePlusRelease = Invoke-GitHubLatestRelease -Repository 'Bush2021/chrome_plus'

$ungoogledAsset = Get-ReleaseAsset -Release $ungoogledRelease -Patterns @(
    "_installer_${Arch}\.exe$"
)
$chromePlusAsset = Get-ReleaseAsset -Release $chromePlusRelease -Patterns @(
    '^Chrome\+\+_v.*\.7z$'
)

$ungoogledInstallerPath = Join-Path $DownloadDir $ungoogledAsset.name
$chromePlusArchivePath = Join-Path $DownloadDir $chromePlusAsset.name

Download-Asset -Asset $ungoogledAsset -DestinationPath $ungoogledInstallerPath
Download-Asset -Asset $chromePlusAsset -DestinationPath $chromePlusArchivePath

Write-Step 'Extracting installer (pass 1)'
Expand-With7Zip -SevenZipPath $sevenZip -ArchivePath $ungoogledInstallerPath -DestinationPath $outerExtractDir

$innerArchive = Find-NestedArchive -SearchRoot $outerExtractDir
Write-Step "Extracting nested archive (pass 2): $([System.IO.Path]::GetFileName($innerArchive))"
Expand-With7Zip -SevenZipPath $sevenZip -ArchivePath $innerArchive -DestinationPath $innerExtractDir

$chromeRoot = Find-ChromeRoot -SearchRoot $innerExtractDir
Write-Step "Resolved chrome.exe directory: $chromeRoot"

Write-Step 'Extracting Chrome++ payload'
Expand-With7Zip -SevenZipPath $sevenZip -ArchivePath $chromePlusArchivePath -DestinationPath $chromePlusExtractDir
$chromePlusPaths = Get-ChromePlusPaths -ExtractRoot $chromePlusExtractDir -Arch $Arch

Write-Step 'Assembling portable package'
$appDir = Join-Path $portableRoot 'App'
$dataDir = Join-Path $portableRoot 'Data'
$cacheDir = Join-Path $portableRoot 'Cache'

Ensure-Directory -Path $portableRoot
Copy-DirectoryContents -Source $chromeRoot -Destination $appDir
Ensure-Directory -Path $dataDir
Ensure-Directory -Path $cacheDir

Copy-ChromePlusFile -Source $chromePlusPaths.VersionDll -Destination (Join-Path $appDir 'version.dll')

$chromeIniSource = if ($ChromePlusIniPath) {
    (Resolve-Path -LiteralPath $ChromePlusIniPath).Path
} else {
    $chromePlusPaths.ChromeIni
}
Copy-ChromePlusFile -Source $chromeIniSource -Destination (Join-Path $appDir 'chrome++.ini')

$metadata = [ordered]@{
    build_time_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    arch = $Arch
    ungoogled = [ordered]@{
        repository = 'ungoogled-software/ungoogled-chromium-windows'
        tag = $ungoogledRelease.tag_name
        asset = $ungoogledAsset.name
        published_at = $ungoogledRelease.published_at
    }
    chrome_plus = [ordered]@{
        repository = 'Bush2021/chrome_plus'
        tag = $chromePlusRelease.tag_name
        asset = $chromePlusAsset.name
        published_at = $chromePlusRelease.published_at
    }
}
$metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $portableRoot 'metadata.json') -Encoding UTF8

if (-not $SkipArchive) {
    $archivePath = Join-Path $ArtifactDir "ungoogled-chromium-portable-$Arch-$($ungoogledRelease.tag_name).7z"
    if ((Test-Path -LiteralPath $archivePath) -and $Force) {
        Remove-Item -LiteralPath $archivePath -Force
    }

    Write-Step "Packing archive: $([System.IO.Path]::GetFileName($archivePath))"
    Push-Location $ArtifactDir
    try {
        $output = & $sevenZip a $archivePath ".\$(Split-Path -Leaf $portableRoot)\*" -mx=9
        if ($LASTEXITCODE -ne 0) {
            throw "7-Zip failed to create archive`n$output"
        }
    }
    finally {
        Pop-Location
    }
}

if (-not $KeepWorkDir) {
    Write-Step 'Cleaning temporary files'
    Remove-DirectorySafe -Path $outerExtractDir
    Remove-DirectorySafe -Path $innerExtractDir
    Remove-DirectorySafe -Path $chromePlusExtractDir
}

Write-Step "Done. Portable package available at $portableRoot"
