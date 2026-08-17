Set-StrictMode -Version Latest

$script:IconExtractorSettingsVersion = 1

function Get-IconExtractorSettingsRoot {
    param([string] $SettingsRootPath)

    if (-not [string]::IsNullOrWhiteSpace($SettingsRootPath)) {
        return [System.IO.Path]::GetFullPath($SettingsRootPath)
    }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA saknas och programinställningarna kan inte sparas.'
    }
    return [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Ikonextraheraren')
}

function Get-DefaultIconLibraryRoot {
    param([string] $SettingsRootPath)

    return Get-IconExtractorSettingsRoot -SettingsRootPath $SettingsRootPath
}

function Get-IconExtractorSettingsPath {
    param([string] $SettingsRootPath)

    return Join-Path (Get-IconExtractorSettingsRoot -SettingsRootPath $SettingsRootPath) 'settings.json'
}

function Read-IconExtractorSettings {
    param([string] $SettingsRootPath)

    $path = Get-IconExtractorSettingsPath -SettingsRootPath $SettingsRootPath
    if (-not [System.IO.File]::Exists($path)) {
        return [pscustomobject]@{
            Version = $script:IconExtractorSettingsVersion
            LibraryRoot = ''
            Warning = ''
        }
    }

    try {
        $settings = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) |
            ConvertFrom-Json -Depth 10
        if ($null -eq $settings -or [int] $settings.Version -ne $script:IconExtractorSettingsVersion) {
            throw 'Inställningsfilens version stöds inte.'
        }
        $savedRoot = [string] $settings.LibraryRoot
        if (-not [string]::IsNullOrWhiteSpace($savedRoot)) {
            $savedRoot = [System.IO.Path]::GetFullPath($savedRoot)
        }
        return [pscustomobject]@{
            Version = $script:IconExtractorSettingsVersion
            LibraryRoot = $savedRoot
            Warning = ''
        }
    } catch {
        return [pscustomobject]@{
            Version = $script:IconExtractorSettingsVersion
            LibraryRoot = ''
            Warning = 'settings.json kunde inte läsas. Den lokala standardplatsen används.'
        }
    }
}

function Write-IconExtractorSettings {
    param(
        [Parameter(Mandatory)] [string] $LibraryRoot,
        [string] $SettingsRootPath
    )

    if ([string]::IsNullOrWhiteSpace($LibraryRoot)) {
        throw 'Biblioteksplatsen får inte vara tom.'
    }
    $resolvedLibraryRoot = [System.IO.Path]::GetFullPath($LibraryRoot)
    $settingsRoot = Get-IconExtractorSettingsRoot -SettingsRootPath $SettingsRootPath
    [void] [System.IO.Directory]::CreateDirectory($settingsRoot)
    $settingsPath = Join-Path $settingsRoot 'settings.json'
    $temporaryPath = Join-Path $settingsRoot ('settings-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $settings = [ordered]@{
        Version = $script:IconExtractorSettingsVersion
        LibraryRoot = $resolvedLibraryRoot
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    }
    try {
        [System.IO.File]::WriteAllText(
            $temporaryPath,
            ($settings | ConvertTo-Json -Depth 5),
            [System.Text.UTF8Encoding]::new($false)
        )
        [System.IO.File]::Move($temporaryPath, $settingsPath, $true)
    } finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
    return Read-IconExtractorSettings -SettingsRootPath $settingsRoot
}

function Resolve-IconLibraryRootSetting {
    param(
        [string] $CommandLineLibraryRoot,
        [string] $SettingsRootPath
    )

    if (-not [string]::IsNullOrWhiteSpace($CommandLineLibraryRoot)) {
        return [pscustomobject]@{
            Root = [System.IO.Path]::GetFullPath($CommandLineLibraryRoot)
            Source = 'CommandLine'
            Warning = ''
        }
    }

    $settings = Read-IconExtractorSettings -SettingsRootPath $SettingsRootPath
    if (-not [string]::IsNullOrWhiteSpace($settings.LibraryRoot)) {
        return [pscustomobject]@{
            Root = [System.IO.Path]::GetFullPath($settings.LibraryRoot)
            Source = 'Saved'
            Warning = [string] $settings.Warning
        }
    }
    return [pscustomobject]@{
        Root = Get-DefaultIconLibraryRoot -SettingsRootPath $SettingsRootPath
        Source = 'Default'
        Warning = [string] $settings.Warning
    }
}
