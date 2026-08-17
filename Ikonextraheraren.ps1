[CmdletBinding()]
param(
    [switch] $SelfTest,
    [switch] $GuiSmokeTest,
    [string] $FilePath,
    [string] $ScreenshotPath,
    [string] $LibraryScreenshotPath,
    [string] $LibraryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDirectory = Split-Path -Parent $PSCommandPath
$corePath = Join-Path $scriptDirectory 'Ikonextraheraren.Core.ps1'

if ($SelfTest) {
    $coreResult = & $corePath -SelfTest
    . $corePath -LibraryOnly
    . (Join-Path $scriptDirectory 'IconLibrary.ps1')
    . (Join-Path $scriptDirectory 'AppSettings.ps1')
    . (Join-Path $scriptDirectory 'IcoExporter.ps1')
    $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $libraryTestRoot = Join-Path $temporaryRoot ('ikonextraheraren-library-test-' + [guid]::NewGuid().ToString('N'))
    $importTestRoot = Join-Path $temporaryRoot ('ikonextraheraren-import-test-' + [guid]::NewGuid().ToString('N'))
    $migrationTestRoot = Join-Path $temporaryRoot ('ikonextraheraren-migration-test-' + [guid]::NewGuid().ToString('N'))
    $legacyImportTestRoot = Join-Path $temporaryRoot ('ikonextraheraren-v1-import-test-' + [guid]::NewGuid().ToString('N'))
    $concurrencyTestRoot = Join-Path $temporaryRoot ('ikonextraheraren-concurrency-test-' + [guid]::NewGuid().ToString('N'))
    $settingsTestRoot = Join-Path $temporaryRoot ('ikonextraheraren-settings-test-' + [guid]::NewGuid().ToString('N'))
    try {
        $icon = [IconResourceReader]::ExtractIcon($coreResult.Testfil, 0, 64)
        try {
            $bitmap = $icon.ToBitmap()
        } finally {
            $icon.Dispose()
        }
        try {
            $memory = [System.IO.MemoryStream]::new()
            try {
                $bitmap.Save($memory, [System.Drawing.Imaging.ImageFormat]::Png)
                $bytes = $memory.ToArray()
            } finally {
                $memory.Dispose()
            }
        } finally {
            $bitmap.Dispose()
        }

        $added = Add-IconLibraryItem -PngBytes $bytes -Name 'Självtest' -SourceFile $coreResult.Testfil -SourceIndex 0 -RootPath $libraryTestRoot
        $duplicate = Add-IconLibraryItem -PngBytes $bytes -Name 'Dublett' -RootPath $libraryTestRoot
        [void] (Update-IconLibraryItemMetadata -Id $added.Item.Id -Tags @('System', 'system', 'Test') -Favorite $true -RootPath $libraryTestRoot)

        $icoPath = Join-Path $libraryTestRoot 'test.ico'
        Save-ExecutableIconAsIco -SourcePath $coreResult.Testfil -IconIndex 0 -Sizes @(16, 24, 32, 48, 64, 128, 256) -DestinationPath $icoPath
        $icoInfo = Get-IcoDirectoryInfo -Path $icoPath
        $icoSizesValid = $true
        foreach ($icoSize in @(16, 24, 32, 48, 64, 128, 256)) {
            $extractedIco = [IconResourceReader]::ExtractIcon($icoPath, 0, $icoSize)
            try {
                $icoSizesValid = $icoSizesValid -and
                    $extractedIco.Width -eq $icoSize -and $extractedIco.Height -eq $icoSize
            } finally {
                $extractedIco.Dispose()
            }
        }
        $icoBytes = [System.IO.File]::ReadAllBytes($icoPath)
        $icoOffsetsValid = @($icoInfo.Entries | Where-Object {
            $_.Offset -lt (6 + (16 * $icoInfo.Count)) -or
            ([long] $_.Offset + [long] $_.Length) -gt $icoBytes.LongLength
        }).Count -eq 0
        $dibHeaderValid = [BitConverter]::ToUInt32($icoBytes, [int] $icoInfo.Entries[0].Offset) -eq 40
        $dibFramesValid = @($icoInfo.Entries | Where-Object Width -LT 256 | Where-Object {
            $maskStride = [int] ([Math]::Ceiling($_.Width / 32.0) * 4)
            $_.Length -ne (40 + ($_.Width * $_.Height * 4) + ($maskStride * $_.Height))
        }).Count -eq 0
        $firstDib = $icoInfo.Entries[0]
        $firstXorOffset = [int] $firstDib.Offset + 40
        $firstXorLength = $firstDib.Width * $firstDib.Height * 4
        $firstMaskOffset = $firstXorOffset + $firstXorLength
        $hasTransparentPixel = $false
        for ($alphaOffset = $firstXorOffset + 3; $alphaOffset -lt $firstMaskOffset; $alphaOffset += 4) {
            if ($icoBytes[$alphaOffset] -eq 0) { $hasTransparentPixel = $true; break }
        }
        $hasAndMask = @($icoBytes[$firstMaskOffset..([int] ($firstDib.Offset + $firstDib.Length - 1))] |
            Where-Object { $_ -ne 0 }).Count -gt 0
        $pngOffset = [int] $icoInfo.Entries[-1].Offset
        $pngSignatureValid = ([BitConverter]::ToString($icoBytes, $pngOffset, 8) -eq '89-50-4E-47-0D-0A-1A-0A')
        $noSizeRejected = $false
        try { [void] (Assert-IcoSizes -Sizes @()) } catch { $noSizeRejected = $true }
        $atomicIcoValid = @(Get-ChildItem -LiteralPath $libraryTestRoot -Filter 'ico-*.tmp').Count -eq 0

        $libraryIcoPath = Join-Path $libraryTestRoot 'bibliotek.ico'
        $libraryImagePath = Get-IconLibraryImagePath -Item $added.Item -RootPath $libraryTestRoot
        Save-PngIconAsIco -SourcePath $libraryImagePath -Sizes @(16, 32, 256) -DestinationPath $libraryIcoPath
        $libraryIcoInfo = Get-IcoDirectoryInfo -Path $libraryIcoPath

        $archivePath = Join-Path $libraryTestRoot 'test.ikonbibliotek'
        $exported = Export-IconLibraryArchive -DestinationPath $archivePath -RootPath $libraryTestRoot
        $imported = Import-IconLibraryArchive -ArchivePath $archivePath -RootPath $importTestRoot
        $importItem = (Read-IconLibraryCatalog -RootPath $importTestRoot).Items[0]
        [void] (Update-IconLibraryItemMetadata -Id $importItem.Id -Tags @('Lokalt') -Favorite $false -RootPath $importTestRoot)
        $reimported = Import-IconLibraryArchive -ArchivePath $archivePath -RootPath $importTestRoot
        $mergedItem = (Read-IconLibraryCatalog -RootPath $importTestRoot).Items[0]
        $importedCount = @($mergedItem).Count

        $migrationAdded = Add-IconLibraryItem -PngBytes $bytes -Name 'Migrering' -RootPath $migrationTestRoot
        $migrationCatalog = Read-IconLibraryCatalog -RootPath $migrationTestRoot
        $migrationCatalog.Version = 1
        $migrationCatalog.Items[0].PSObject.Properties.Remove('Tags')
        $migrationCatalog.Items[0].PSObject.Properties.Remove('Favorite')
        $migrationPaths = Initialize-IconLibrary -RootPath $migrationTestRoot
        [System.IO.File]::WriteAllText(
            $migrationPaths.Database,
            ($migrationCatalog | ConvertTo-Json -Depth 8),
            [System.Text.UTF8Encoding]::new($false)
        )
        $migratedCatalog = Read-IconLibraryCatalog -RootPath $migrationTestRoot

        # Skapa också ett riktigt v1-arkiv genom att nedgradera database.json i
        # en exporterad kopia. Importen ska acceptera detta och skriva v2 lokalt.
        $legacyArchivePath = Join-Path $libraryTestRoot 'legacy.ikonbibliotek'
        [void] (Export-IconLibraryArchive -DestinationPath $legacyArchivePath -RootPath $libraryTestRoot)
        $legacyStream = [System.IO.File]::Open(
            $legacyArchivePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        try {
            $legacyArchive = [System.IO.Compression.ZipArchive]::new(
                $legacyStream,
                [System.IO.Compression.ZipArchiveMode]::Update,
                $false,
                [System.Text.Encoding]::UTF8
            )
            try {
                $legacyEntry = $legacyArchive.GetEntry('database.json')
                $legacyReader = [System.IO.StreamReader]::new($legacyEntry.Open(), [System.Text.Encoding]::UTF8)
                try { $legacyCatalog = $legacyReader.ReadToEnd() | ConvertFrom-Json -Depth 20 }
                finally { $legacyReader.Dispose() }
                $legacyCatalog.Version = 1
                foreach ($legacyItem in @($legacyCatalog.Items)) {
                    $legacyItem.PSObject.Properties.Remove('Tags')
                    $legacyItem.PSObject.Properties.Remove('Favorite')
                }
                $legacyEntry.Delete()
                $replacementEntry = $legacyArchive.CreateEntry(
                    'database.json',
                    [System.IO.Compression.CompressionLevel]::Optimal
                )
                $legacyWriter = [System.IO.StreamWriter]::new(
                    $replacementEntry.Open(),
                    [System.Text.UTF8Encoding]::new($false)
                )
                try { $legacyWriter.Write(($legacyCatalog | ConvertTo-Json -Depth 8)) }
                finally { $legacyWriter.Dispose() }
            } finally {
                $legacyArchive.Dispose()
            }
        } finally {
            $legacyStream.Dispose()
        }
        $legacyImported = Import-IconLibraryArchive -ArchivePath $legacyArchivePath -RootPath $legacyImportTestRoot
        $legacyImportedCatalog = Read-IconLibraryCatalog -RootPath $legacyImportTestRoot

        # Fyra separata PowerShell-processer skriver samtidigt till samma
        # bibliotek. Samtliga unika poster och bildfiler måste finnas kvar.
        $concurrencyPayloads = [System.Collections.Generic.List[string]]::new()
        for ($payloadIndex = 0; $payloadIndex -lt 12; $payloadIndex++) {
            $testBitmap = [System.Drawing.Bitmap]::new(32, 32)
            try {
                $graphics = [System.Drawing.Graphics]::FromImage($testBitmap)
                try {
                    $graphics.Clear([System.Drawing.Color]::FromArgb(
                        255,
                        20 + ($payloadIndex * 15),
                        30 + ($payloadIndex * 11),
                        40 + ($payloadIndex * 9)
                    ))
                } finally {
                    $graphics.Dispose()
                }
                $payloadStream = [System.IO.MemoryStream]::new()
                try {
                    $testBitmap.Save($payloadStream, [System.Drawing.Imaging.ImageFormat]::Png)
                    $concurrencyPayloads.Add([Convert]::ToBase64String($payloadStream.ToArray()))
                } finally {
                    $payloadStream.Dispose()
                }
            } finally {
                $testBitmap.Dispose()
            }
        }

        $libraryScriptPath = Join-Path $scriptDirectory 'IconLibrary.ps1'
        $concurrencyJobs = @()
        try {
            for ($workerIndex = 0; $workerIndex -lt 4; $workerIndex++) {
                $concurrencyJobs += Start-Job -ScriptBlock {
                    param($WorkerIndex, $WorkerCount, $Payloads, $Root, $CoreScript, $LibraryScript)
                    $ErrorActionPreference = 'Stop'
                    . $CoreScript -LibraryOnly
                    . $LibraryScript
                    for ($itemIndex = $WorkerIndex; $itemIndex -lt $Payloads.Count; $itemIndex += $WorkerCount) {
                        $payload = [Convert]::FromBase64String([string] $Payloads[$itemIndex])
                        [void] (Add-IconLibraryItem -PngBytes $payload -Name ('Samtidig {0:D2}' -f $itemIndex) -RootPath $Root)
                    }
                } -ArgumentList $workerIndex, 4, ([string[]] $concurrencyPayloads), $concurrencyTestRoot, $corePath, $libraryScriptPath
            }
            [void] ($concurrencyJobs | Wait-Job -Timeout 60)
            $unfinishedJobs = @($concurrencyJobs | Where-Object State -NE 'Completed')
            if ($unfinishedJobs.Count -gt 0) {
                throw 'Flerprocesstestet hann inte slutföras.'
            }
            [void] ($concurrencyJobs | Receive-Job -ErrorAction Stop)
        } finally {
            foreach ($job in $concurrencyJobs) {
                if ($job.State -notin @('Completed', 'Failed', 'Stopped')) { Stop-Job -Job $job }
                Remove-Job -Job $job -Force
            }
        }
        $concurrencyCatalog = Read-IconLibraryCatalog -RootPath $concurrencyTestRoot
        $concurrencyImageCount = @(Get-ChildItem -LiteralPath (Join-Path $concurrencyTestRoot 'icons') -Filter '*.png').Count
        $concurrencyTempCount = @(Get-ChildItem -LiteralPath $concurrencyTestRoot -Filter 'library-*.tmp').Count

        $defaultSetting = Resolve-IconLibraryRootSetting -SettingsRootPath $settingsTestRoot
        $rememberedRoot = Join-Path $settingsTestRoot 'delat bibliotek'
        [void] (Write-IconExtractorSettings -LibraryRoot $rememberedRoot -SettingsRootPath $settingsTestRoot)
        $rememberedSetting = Resolve-IconLibraryRootSetting -SettingsRootPath $settingsTestRoot
        $overrideRoot = Join-Path $settingsTestRoot 'tillfällig override'
        $overrideSetting = Resolve-IconLibraryRootSetting `
            -CommandLineLibraryRoot $overrideRoot `
            -SettingsRootPath $settingsTestRoot
        $settingsJson = [System.IO.File]::ReadAllText(
            (Get-IconExtractorSettingsPath -SettingsRootPath $settingsTestRoot),
            [System.Text.Encoding]::UTF8
        ) | ConvertFrom-Json
        $settingsTempCount = @(Get-ChildItem -LiteralPath $settingsTestRoot -Filter 'settings-*.tmp').Count

        $searchByName = Test-IconLibraryItemMatch -Item $mergedItem -SearchText 'SJÄLV' -FavoritesOnly $false
        $searchBySource = Test-IconLibraryItemMatch -Item $mergedItem -SearchText 'shell32' -FavoritesOnly $false
        $searchByTag = Test-IconLibraryItemMatch -Item $mergedItem -SearchText 'lokalt' -FavoritesOnly $false
        $emptySearch = -not (Test-IconLibraryItemMatch -Item $mergedItem -SearchText 'ingen-träff-987' -FavoritesOnly $false)
        $favoriteMatch = Test-IconLibraryItemMatch -Item $mergedItem -SearchText '' -FavoritesOnly $true
        $tagLimitSample = Normalize-IconTags -Tags @((1..25 | ForEach-Object { 'Tagg{0:D2}' -f $_ }))
        $tagLengthSample = Normalize-IconTags -Tags @('123456789012345678901234567890EXTRA')
        $checks = [ordered]@{
            LibraryAdd = $added.Added
            DuplicateBlocked = -not $duplicate.Added
            ExportCount = $exported -eq 1
            ImportCount = $imported.Imported -eq 1
            ReimportCount = $reimported.Imported -eq 0
            DuplicateImport = $reimported.Skipped -eq 1
            MetadataMerged = $reimported.Merged -eq 1
            ImportedItemCount = $importedCount -eq 1
            MergedTagCount = @($mergedItem.Tags).Count -eq 3
            MergedFavorite = [bool] $mergedItem.Favorite
            MigratedVersion = $migratedCatalog.Version -eq 2
            MigratedTags = @($migratedCatalog.Items[0].Tags).Count -eq 0
            SearchName = $searchByName
            SearchSource = $searchBySource
            SearchTag = $searchByTag
            EmptySearch = $emptySearch
            FavoriteFilter = $favoriteMatch
            TagLimit = $tagLimitSample.Count -eq 20
            TagLength = $tagLengthSample[0].Length -eq 30
            IcoEntryCount = $icoInfo.Count -eq 7
            IcoSizes = $icoSizesValid
            IcoOffsets = $icoOffsetsValid
            IcoDibFrames = $dibHeaderValid
            IcoDibLengths = $dibFramesValid
            IcoTransparency = $hasTransparentPixel -and $hasAndMask
            IcoPng256 = $pngSignatureValid
            IcoEmptySelection = $noSizeRejected
            IcoAtomicWrite = $atomicIcoValid
            LibraryIco = $libraryIcoInfo.Count -eq 3
            LegacyArchiveImport = $legacyImported.Imported -eq 1
            LegacyArchiveUpgrade = $legacyImportedCatalog.Version -eq 2
            LegacyArchiveTags = @($legacyImportedCatalog.Items[0].Tags).Count -eq 0
            ConcurrentCatalog = @($concurrencyCatalog.Items).Count -eq 12
            ConcurrentImages = $concurrencyImageCount -eq 12
            ConcurrentAtomicWrite = $concurrencyTempCount -eq 0
            SettingsDefault = $defaultSetting.Root -eq [System.IO.Path]::GetFullPath($settingsTestRoot)
            SettingsRemembered = $rememberedSetting.Root -eq [System.IO.Path]::GetFullPath($rememberedRoot)
            SettingsSource = $rememberedSetting.Source -eq 'Saved'
            SettingsCliOverride = $overrideSetting.Root -eq [System.IO.Path]::GetFullPath($overrideRoot) -and
                $overrideSetting.Source -eq 'CommandLine'
            SettingsSchema = [int] $settingsJson.Version -eq 1
            SettingsAtomicWrite = $settingsTempCount -eq 0
        }
        $failedChecks = @($checks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object Key)
        if ($failedChecks.Count -gt 0) {
            throw ('ICO- eller ikonbibliotekets rundresetest misslyckades: ' + ($failedChecks -join ', '))
        }
    } finally {
        foreach ($testPath in @($libraryTestRoot, $importTestRoot, $migrationTestRoot, $legacyImportTestRoot, $concurrencyTestRoot, $settingsTestRoot)) {
            $resolvedTestPath = [System.IO.Path]::GetFullPath($testPath)
            if ($resolvedTestPath.StartsWith($temporaryRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
                [System.IO.Directory]::Exists($resolvedTestPath)) {
                [System.IO.Directory]::Delete($resolvedTestPath, $true)
            }
        }
    }
    [pscustomobject]@{
        Resultat = 'OK'
        Ikonmotor = '{0} ikoner i testfilen' -f $coreResult.AntalIkoner
        Bildexport = 'PNG, JPG och flerbilds-ICO'
        Bibliotek = 'Schema v2, ihågkommen plats, fleranvändarlås, sökning, taggar och favoriter'
    }
    return
}

if (-not $IsWindows) {
    throw 'Ikonextraheraren kräver Windows och PowerShell 7.'
}

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne
    [System.Threading.ApartmentState]::STA) {
    throw 'Starta programmet med pwsh -STA eller använd Starta Ikonextraheraren.cmd.'
}

# Dot-sourcing binder kärnskriptets parametrar i samma scope. Bevara därför
# startparametrarna medan den testade Win32-/bildmotorn laddas.
$requestedGuiSmokeTest = $GuiSmokeTest
$requestedFilePath = $FilePath
. $corePath -LibraryOnly
$GuiSmokeTest = $requestedGuiSmokeTest
$FilePath = $requestedFilePath

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

. (Join-Path $scriptDirectory 'IconLibrary.ps1')
. (Join-Path $scriptDirectory 'AppSettings.ps1')
. (Join-Path $scriptDirectory 'LibraryWindow.ps1')
. (Join-Path $scriptDirectory 'IcoExporter.ps1')
. (Join-Path $scriptDirectory 'IcoExportDialog.ps1')
. (Join-Path $scriptDirectory 'LibrarySettingsDialog.ps1')

function ConvertTo-WpfBitmapSource {
    param([Parameter(Mandatory)] [System.Drawing.Bitmap] $Bitmap)

    $stream = [System.IO.MemoryStream]::new()
    try {
        $Bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $stream.Position = 0
        $source = [System.Windows.Media.Imaging.BitmapImage]::new()
        $source.BeginInit()
        $source.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $source.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat
        $source.StreamSource = $stream
        $source.EndInit()
        $source.Freeze()
        return $source
    } finally {
        $stream.Dispose()
    }
}

function ConvertTo-PngBytes {
    param([Parameter(Mandatory)] [System.Drawing.Bitmap] $Bitmap)

    $stream = [System.IO.MemoryStream]::new()
    try {
        $Bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return $stream.ToArray()
    } finally {
        $stream.Dispose()
    }
}

$xamlPath = Join-Path $scriptDirectory 'MainWindow.xaml'
if (-not (Test-Path -LiteralPath $xamlPath -PathType Leaf)) {
    throw "Gränssnittsfilen saknas: $xamlPath"
}

$xamlText = [System.IO.File]::ReadAllText($xamlPath)
$stringReader = [System.IO.StringReader]::new($xamlText)
$xmlReader = [System.Xml.XmlReader]::Create($stringReader)
try {
    $window = [System.Windows.Markup.XamlReader]::Load($xmlReader)
} finally {
    $xmlReader.Dispose()
    $stringReader.Dispose()
}

$openButton = $window.FindName('OpenButton')
$libraryButton = $window.FindName('LibraryButton')
$librarySettingsButton = $window.FindName('LibrarySettingsButton')
$libraryHeaderCountText = $window.FindName('LibraryHeaderCountText')
$filePathText = $window.FindName('FilePathText')
$fileMetaText = $window.FindName('FileMetaText')
$countBadgeText = $window.FindName('CountBadgeText')
$iconList = $window.FindName('IconList')
$emptyState = $window.FindName('EmptyState')
$previewImage = $window.FindName('PreviewImage')
$selectionTitle = $window.FindName('SelectionTitle')
$selectionMeta = $window.FindName('SelectionMeta')
$sizeCombo = $window.FindName('SizeCombo')
$pngRadio = $window.FindName('PngRadio')
$jpgRadio = $window.FindName('JpgRadio')
$icoRadio = $window.FindName('IcoRadio')
$qualityPanel = $window.FindName('QualityPanel')
$icoHintPanel = $window.FindName('IcoHintPanel')
$qualitySlider = $window.FindName('QualitySlider')
$qualityText = $window.FindName('QualityText')
$saveToLibraryButton = $window.FindName('SaveToLibraryButton')
$exportSelectedButton = $window.FindName('ExportSelectedButton')
$exportAllButton = $window.FindName('ExportAllButton')
$statusText = $window.FindName('StatusText')
$busyProgress = $window.FindName('BusyProgress')

$script:CurrentFile = $null
$script:CurrentIconCount = 0
$script:BitmapCache = @{}
$script:WpfImageCache = @{}
$script:IsBusy = $false
$libraryRootResolution = Resolve-IconLibraryRootSetting -CommandLineLibraryRoot $LibraryRoot
$script:LibraryRoot = (Initialize-IconLibrary -RootPath $libraryRootResolution.Root).Root
$script:LibraryRootSource = $libraryRootResolution.Source
$iconCollection = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
$iconList.ItemsSource = $iconCollection

$getSelectedIndex = {
    if ($null -eq $iconList.SelectedItem) { return $null }
    return [int] $iconList.SelectedItem.Index
}

$getSelectedSize = {
    if ($null -eq $sizeCombo.SelectedItem) { return 64 }
    return [int] $sizeCombo.SelectedItem.Tag
}

$getSelectedFormat = {
    if ($icoRadio.IsChecked -eq $true) { return 'ICO' }
    if ($jpgRadio.IsChecked -eq $true) { return 'JPG' }
    return 'PNG'
}

$pumpDispatcher = {
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    [void] $window.Dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [System.Windows.Threading.DispatcherOperationCallback] {
            param($state)
            $state.Continue = $false
            return $null
        },
        $frame
    )
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

$setBusy = {
    param([bool] $Busy, [string] $Text = 'Redo')

    $script:IsBusy = $Busy
    $window.Cursor = if ($Busy) {
        [System.Windows.Input.Cursors]::Wait
    } else {
        [System.Windows.Input.Cursors]::Arrow
    }
    $openButton.IsEnabled = -not $Busy
    $libraryButton.IsEnabled = -not $Busy
    $exportSelectedButton.IsEnabled = (-not $Busy -and $null -ne $iconList.SelectedItem)
    $saveToLibraryButton.IsEnabled = (-not $Busy -and $null -ne $iconList.SelectedItem)
    $exportAllButton.IsEnabled = (-not $Busy -and $script:CurrentIconCount -gt 0)
    $statusText.Text = $Text
    & $pumpDispatcher
}

$clearLoadedImages = {
    $previewImage.Source = $null
    $iconCollection.Clear()
    $script:WpfImageCache.Clear()
    foreach ($bitmap in @($script:BitmapCache.Values)) {
        if ($null -ne $bitmap) { $bitmap.Dispose() }
    }
    $script:BitmapCache.Clear()
}

$getWpfIconImage = {
    param([int] $Index, [int] $Size)

    $key = '{0}:{1}' -f $Index, $Size
    if ($script:WpfImageCache.ContainsKey($key)) {
        return $script:WpfImageCache[$key]
    }

    $bitmap = Get-IconBitmap -Path $script:CurrentFile -Index $Index -Size $Size -Cache $script:BitmapCache
    $source = ConvertTo-WpfBitmapSource -Bitmap $bitmap
    $script:WpfImageCache[$key] = $source
    return $source
}

$showError = {
    param([string] $Title, [string] $Message)
    [void] [System.Windows.MessageBox]::Show(
        $window,
        $Message,
        $Title,
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    )
}

$updatePreview = {
    if ($script:IsBusy) { return }

    $index = & $getSelectedIndex
    if ($null -eq $index -or [string]::IsNullOrEmpty($script:CurrentFile)) {
        $previewImage.Source = $null
        $selectionTitle.Text = 'Ingen ikon vald'
        $selectionMeta.Text = 'Öppna en fil för att börja'
        $exportSelectedButton.IsEnabled = $false
        $saveToLibraryButton.IsEnabled = $false
        return
    }

    try {
        $size = & $getSelectedSize
        $previewImage.Source = & $getWpfIconImage $index $size
        $selectionTitle.Text = 'Ikon {0}' -f ($index + 1)
        $selectionMeta.Text = '{0} × {0} px  •  {1} av {2}' -f $size, ($index + 1), $script:CurrentIconCount
        $exportSelectedButton.IsEnabled = $true
        $saveToLibraryButton.IsEnabled = $true
        $statusText.Text = 'Ikon {0} vald' -f ($index + 1)
    } catch {
        $statusText.Text = 'Förhandsvisningen kunde inte skapas'
        & $showError 'Fel vid ikonläsning' $_.Exception.Message
    }
}

$resetAfterLoadFailure = {
    & $clearLoadedImages
    $script:CurrentFile = $null
    $script:CurrentIconCount = 0
    $filePathText.Text = 'Ingen EXE- eller DLL-fil vald'
    $fileMetaText.Text = 'Väntar på fil'
    $countBadgeText.Text = '0'
    $emptyState.Visibility = [System.Windows.Visibility]::Visible
    $selectionTitle.Text = 'Ingen ikon vald'
    $selectionMeta.Text = 'Öppna en fil för att börja'
    $exportSelectedButton.IsEnabled = $false
    $saveToLibraryButton.IsEnabled = $false
    $exportAllButton.IsEnabled = $false
}

$loadFile = {
    param([string] $Path)

    $startedLoading = $false
    try {
        $resolvedPath = [System.IO.Path]::GetFullPath($Path)
        $extension = [System.IO.Path]::GetExtension($resolvedPath).ToLowerInvariant()
        if ($extension -notin @('.exe', '.dll')) {
            throw 'Välj en fil med ändelsen .exe eller .dll.'
        }
        if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
            throw 'Filen finns inte längre.'
        }

        & $setBusy $true 'Läser ikonresurser…'
        $count = [IconResourceReader]::GetIconCount($resolvedPath)
        if ($count -lt 1) {
            throw 'Filen innehåller inga ikoner som Windows kan extrahera.'
        }

        $startedLoading = $true
        & $clearLoadedImages
        $script:CurrentFile = $resolvedPath
        $script:CurrentIconCount = $count
        $filePathText.Text = $resolvedPath
        $fileMetaText.Text = '{0} ikon{1}  •  {2}' -f $count, $(if ($count -eq 1) { '' } else { 'er' }), $extension.TrimStart('.').ToUpperInvariant()
        $countBadgeText.Text = [string] $count
        $emptyState.Visibility = [System.Windows.Visibility]::Collapsed

        $busyProgress.IsIndeterminate = $false
        $busyProgress.Minimum = 0
        $busyProgress.Maximum = $count
        $busyProgress.Value = 0
        $busyProgress.Visibility = [System.Windows.Visibility]::Visible

        for ($index = 0; $index -lt $count; $index++) {
            $thumbnail = & $getWpfIconImage $index 64
            $item = [pscustomobject]@{
                Index = $index
                Label = 'Ikon {0}' -f ($index + 1)
                Image = $thumbnail
            }
            $iconCollection.Add($item)
            $busyProgress.Value = $index + 1
            if ($index % 8 -eq 0) {
                $statusText.Text = 'Läser ikon {0} av {1}…' -f ($index + 1), $count
                & $pumpDispatcher
            }
        }

        $busyProgress.Visibility = [System.Windows.Visibility]::Collapsed
        $iconList.SelectedIndex = 0
        $iconList.ScrollIntoView($iconList.SelectedItem)
        & $setBusy $false ('{0} ikoner lästa från {1}' -f $count, [System.IO.Path]::GetFileName($resolvedPath))
        & $updatePreview
    } catch {
        if ($startedLoading) { & $resetAfterLoadFailure }
        $busyProgress.Visibility = [System.Windows.Visibility]::Collapsed
        & $setBusy $false 'Kunde inte öppna filen'
        & $showError 'Kunde inte öppna filen' $_.Exception.Message
    }
}

$chooseFile = {
    if ($script:IsBusy) { return }
    $dialog = [Microsoft.Win32.OpenFileDialog]::new()
    $dialog.Title = 'Välj en fil som innehåller ikoner'
    $dialog.Filter = 'Program och bibliotek (*.exe;*.dll)|*.exe;*.dll|Program (*.exe)|*.exe|Bibliotek (*.dll)|*.dll|Alla filer (*.*)|*.*'
    $dialog.CheckFileExists = $true
    $dialog.Multiselect = $false
    if ($dialog.ShowDialog($window) -eq $true) {
        & $loadFile $dialog.FileName
    }
}

$selectExportFolder = {
    $folderDialogType = 'Microsoft.Win32.OpenFolderDialog' -as [type]
    if ($null -ne $folderDialogType) {
        $dialog = [Microsoft.Win32.OpenFolderDialog]::new()
        $dialog.Title = 'Välj mapp för de exporterade ikonerna'
        $dialog.Multiselect = $false
        if ($dialog.ShowDialog($window) -eq $true) {
            return $dialog.FolderName
        }
        return $null
    }

    # Reservväg för äldre PowerShell 7-versioner som kör på .NET före 8.
    Add-Type -AssemblyName System.Windows.Forms
    $fallback = [System.Windows.Forms.FolderBrowserDialog]::new()
    try {
        $fallback.Description = 'Välj mapp för de exporterade ikonerna'
        if ($fallback.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $fallback.SelectedPath
        }
        return $null
    } finally {
        $fallback.Dispose()
    }
}

$chooseIcoSizes = {
    return Show-IcoSizeDialog -Owner $window -XamlPath (Join-Path $scriptDirectory 'IcoExportWindow.xaml')
}

$exportSelected = {
    if ($script:IsBusy) { return }
    $index = & $getSelectedIndex
    if ($null -eq $index) { return }

    $format = & $getSelectedFormat
    $icoSizes = @()
    if ($format -eq 'ICO') {
        $icoSizes = @(& $chooseIcoSizes)
        if ($icoSizes.Count -eq 0) { return }
    }
    $extension = switch ($format) {
        'PNG' { 'png' }
        'JPG' { 'jpg' }
        'ICO' { 'ico' }
    }
    $size = if ($format -eq 'ICO') { 0 } else { & $getSelectedSize }
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($script:CurrentFile)
    $dialog = [Microsoft.Win32.SaveFileDialog]::new()
    $dialog.Title = 'Exportera vald ikon'
    $dialog.Filter = switch ($format) {
        'PNG' { 'PNG-bild (*.png)|*.png' }
        'JPG' { 'JPEG-bild (*.jpg)|*.jpg' }
        'ICO' { 'Windows-ikon (*.ico)|*.ico' }
    }
    $dialog.DefaultExt = $extension
    $dialog.AddExtension = $true
    $dialog.OverwritePrompt = $true
    $dialog.FileName = if ($format -eq 'ICO') {
        '{0}_ikon_{1:D3}.ico' -f $baseName, ($index + 1)
    } else {
        '{0}_ikon_{1:D3}_{2}x{2}.{3}' -f $baseName, ($index + 1), $size, $extension
    }
    if ($dialog.ShowDialog($window) -ne $true) { return }

    try {
        & $setBusy $true 'Exporterar ikon…'
        if ($format -eq 'ICO') {
            Save-ExecutableIconAsIco -SourcePath $script:CurrentFile -IconIndex $index -Sizes $icoSizes -DestinationPath $dialog.FileName
        } else {
            $bitmap = Get-IconBitmap -Path $script:CurrentFile -Index $index -Size $size -Cache $script:BitmapCache
            Save-IconBitmap -Bitmap $bitmap -Path $dialog.FileName -Format $format -JpegQuality ([int] [Math]::Round($qualitySlider.Value))
        }
        & $setBusy $false ('Sparad: {0}' -f $dialog.FileName)
    } catch {
        & $setBusy $false 'Exporten misslyckades'
        & $showError 'Exportfel' $_.Exception.Message
    }
}

$exportAll = {
    if ($script:IsBusy -or $script:CurrentIconCount -lt 1) { return }
    $format = & $getSelectedFormat
    $icoSizes = @()
    if ($format -eq 'ICO') {
        $icoSizes = @(& $chooseIcoSizes)
        if ($icoSizes.Count -eq 0) { return }
    }
    $folder = & $selectExportFolder
    if ([string]::IsNullOrEmpty($folder)) { return }

    $extension = switch ($format) {
        'PNG' { 'png' }
        'JPG' { 'jpg' }
        'ICO' { 'ico' }
    }
    $size = if ($format -eq 'ICO') { 0 } else { & $getSelectedSize }
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($script:CurrentFile)

    try {
        $busyProgress.IsIndeterminate = $false
        $busyProgress.Minimum = 0
        $busyProgress.Maximum = $script:CurrentIconCount
        $busyProgress.Value = 0
        $busyProgress.Visibility = [System.Windows.Visibility]::Visible
        & $setBusy $true 'Exporterar alla ikoner…'

        for ($index = 0; $index -lt $script:CurrentIconCount; $index++) {
            $name = if ($format -eq 'ICO') {
                '{0}_ikon_{1:D3}.ico' -f $baseName, ($index + 1)
            } else {
                '{0}_ikon_{1:D3}_{2}x{2}.{3}' -f $baseName, ($index + 1), $size, $extension
            }
            $outputPath = Get-UniquePath -Path (Join-Path $folder $name)
            if ($format -eq 'ICO') {
                Save-ExecutableIconAsIco -SourcePath $script:CurrentFile -IconIndex $index -Sizes $icoSizes -DestinationPath $outputPath
            } else {
                $bitmap = Get-IconBitmap -Path $script:CurrentFile -Index $index -Size $size -Cache $script:BitmapCache
                Save-IconBitmap -Bitmap $bitmap -Path $outputPath -Format $format -JpegQuality ([int] [Math]::Round($qualitySlider.Value))
            }
            $busyProgress.Value = $index + 1
            $statusText.Text = 'Exporterar {0} av {1}…' -f ($index + 1), $script:CurrentIconCount
            & $pumpDispatcher
        }

        $busyProgress.Visibility = [System.Windows.Visibility]::Collapsed
        & $setBusy $false ('{0} ikoner exporterades till {1}' -f $script:CurrentIconCount, $folder)
    } catch {
        $busyProgress.Visibility = [System.Windows.Visibility]::Collapsed
        & $setBusy $false 'Exporten misslyckades'
        & $showError 'Exportfel' $_.Exception.Message
    }
}

$updateLibraryCount = {
    try {
        $catalog = Read-IconLibraryCatalog -RootPath $script:LibraryRoot
        $libraryHeaderCountText.Text = [string] @($catalog.Items).Count
    } catch {
        $libraryHeaderCountText.Text = '!'
        $statusText.Text = 'Det lokala biblioteket kunde inte läsas'
    }
}

$saveToLibrary = {
    if ($script:IsBusy) { return }
    $index = & $getSelectedIndex
    if ($null -eq $index) { return }

    try {
        & $setBusy $true 'Sparar ikonen i biblioteket…'
        $bitmap = Get-IconBitmap -Path $script:CurrentFile -Index $index -Size 256 -Cache $script:BitmapCache
        $bytes = ConvertTo-PngBytes -Bitmap $bitmap
        $sourceName = [System.IO.Path]::GetFileName($script:CurrentFile)
        $displayName = '{0} – Ikon {1}' -f [System.IO.Path]::GetFileNameWithoutExtension($script:CurrentFile), ($index + 1)
        $addLibraryItem = @{
            PngBytes = $bytes
            Name = $displayName
            SourceFileName = $sourceName
            SourceIndex = $index
            RootPath = $script:LibraryRoot
        }
        $result = Add-IconLibraryItem @addLibraryItem
        & $updateLibraryCount
        if ($result.Added) {
            & $setBusy $false ("'$displayName' sparades i biblioteket")
        } else {
            & $setBusy $false 'Ikonen finns redan i biblioteket'
        }
    } catch {
        & $setBusy $false 'Ikonen kunde inte sparas'
        & $showError 'Kunde inte spara i biblioteket' $_.Exception.Message
    }
}

$showLibrary = {
    if ($script:IsBusy) { return }
    try {
        $libraryWindowParameters = @{
            Owner = $window
            XamlPath = Join-Path $scriptDirectory 'LibraryWindow.xaml'
            IcoDialogXamlPath = Join-Path $scriptDirectory 'IcoExportWindow.xaml'
            RootPath = $script:LibraryRoot
        }
        Show-IconLibraryWindow @libraryWindowParameters
        & $updateLibraryCount
        $statusText.Text = 'Ikonbiblioteket stängdes'
    } catch {
        & $showError 'Kunde inte öppna ikonbiblioteket' $_.Exception.Message
    }
}

$updateLibraryLocationPresentation = {
    $libraryButton.ToolTip = 'Öppna ikonbiblioteket: {0}' -f $script:LibraryRoot
    $librarySettingsButton.ToolTip = 'Ställ in biblioteksplats (nu: {0})' -f $script:LibraryRoot
}

$showLibrarySettings = {
    if ($script:IsBusy) { return }
    try {
        $localRoot = Get-DefaultIconLibraryRoot
        $selectedRoot = Show-LibrarySettingsDialog `
            -Owner $window `
            -XamlPath (Join-Path $scriptDirectory 'LibrarySettingsWindow.xaml') `
            -CurrentRoot $script:LibraryRoot `
            -LocalRoot $localRoot
        if ([string]::IsNullOrWhiteSpace($selectedRoot)) { return }

        $selectedPaths = Initialize-IconLibrary -RootPath $selectedRoot
        $testLock = Enter-IconLibraryLock -RootPath $selectedPaths.Root
        $testLock.Stream.Dispose()
        [void] (Write-IconExtractorSettings -LibraryRoot $selectedPaths.Root)
        $script:LibraryRoot = $selectedPaths.Root
        $script:LibraryRootSource = 'Saved'
        & $updateLibraryLocationPresentation
        & $updateLibraryCount
        $statusText.Text = 'Biblioteksplatsen sparades: {0}' -f $script:LibraryRoot
    } catch {
        & $showError 'Kunde inte byta biblioteksplats' $_.Exception.Message
    }
}

$openButton.Add_Click($chooseFile)
$libraryButton.Add_Click($showLibrary)
$librarySettingsButton.Add_Click($showLibrarySettings)
$saveToLibraryButton.Add_Click($saveToLibrary)
$exportSelectedButton.Add_Click($exportSelected)
$exportAllButton.Add_Click($exportAll)
$iconList.Add_SelectionChanged($updatePreview)
$sizeCombo.Add_SelectionChanged($updatePreview)
$updateFormatControls = {
    $isJpeg = $jpgRadio.IsChecked -eq $true
    $isIco = $icoRadio.IsChecked -eq $true
    $qualityPanel.Visibility = if ($isJpeg) {
        [System.Windows.Visibility]::Visible
    } else {
        [System.Windows.Visibility]::Collapsed
    }
    $icoHintPanel.Visibility = if ($isIco) {
        [System.Windows.Visibility]::Visible
    } else {
        [System.Windows.Visibility]::Collapsed
    }
    $sizeCombo.IsEnabled = -not $isIco
}
$jpgRadio.Add_Checked($updateFormatControls)
$pngRadio.Add_Checked($updateFormatControls)
$icoRadio.Add_Checked($updateFormatControls)
$qualitySlider.Add_ValueChanged({
    $qualityText.Text = '{0} %' -f [int] [Math]::Round($qualitySlider.Value)
})

$window.Add_PreviewKeyDown({
    param($sender, $eventArgs)
    if (($eventArgs.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -and
        $eventArgs.Key -eq [System.Windows.Input.Key]::O) {
        $eventArgs.Handled = $true
        & $chooseFile
    } elseif (($eventArgs.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -and
              $eventArgs.Key -eq [System.Windows.Input.Key]::S -and
              $exportSelectedButton.IsEnabled) {
        $eventArgs.Handled = $true
        & $exportSelected
    }
})

$window.Add_PreviewDragOver({
    param($sender, $eventArgs)
    $eventArgs.Effects = [System.Windows.DragDropEffects]::None
    if ($eventArgs.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $paths = [string[]] $eventArgs.Data.GetData([System.Windows.DataFormats]::FileDrop)
        if ($paths.Count -gt 0 -and
            [System.IO.Path]::GetExtension($paths[0]).ToLowerInvariant() -in @('.exe', '.dll')) {
            $eventArgs.Effects = [System.Windows.DragDropEffects]::Copy
        }
    }
    $eventArgs.Handled = $true
})

$window.Add_Drop({
    param($sender, $eventArgs)
    if ($eventArgs.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $paths = [string[]] $eventArgs.Data.GetData([System.Windows.DataFormats]::FileDrop)
        if ($paths.Count -gt 0) { & $loadFile $paths[0] }
    }
})

$window.Add_Closed({
    & $clearLoadedImages
})

& $updateLibraryLocationPresentation
& $updateLibraryCount
if (-not [string]::IsNullOrWhiteSpace($libraryRootResolution.Warning)) {
    $statusText.Text = $libraryRootResolution.Warning
}

if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
    & $loadFile $FilePath
}

if (-not [string]::IsNullOrWhiteSpace($LibraryScreenshotPath)) {
    $window.ShowInTaskbar = $false
    $window.Left = -20000
    $window.Top = -20000
    $window.Show()
    $window.UpdateLayout()
    $libraryScreenshotParameters = @{
        Owner = $window
        XamlPath = Join-Path $scriptDirectory 'LibraryWindow.xaml'
        IcoDialogXamlPath = Join-Path $scriptDirectory 'IcoExportWindow.xaml'
        RootPath = $script:LibraryRoot
        ScreenshotPath = $LibraryScreenshotPath
    }
    Show-IconLibraryWindow @libraryScreenshotParameters
    $window.Close()
    return
}

if (-not [string]::IsNullOrWhiteSpace($ScreenshotPath)) {
    $resolvedScreenshotPath = [System.IO.Path]::GetFullPath($ScreenshotPath)
    $screenshotDirectory = [System.IO.Path]::GetDirectoryName($resolvedScreenshotPath)
    if (-not [System.IO.Directory]::Exists($screenshotDirectory)) {
        [void] [System.IO.Directory]::CreateDirectory($screenshotDirectory)
    }

    $window.ShowInTaskbar = $false
    $window.Left = -20000
    $window.Top = -20000
    $window.Show()
    $window.UpdateLayout()
    & $pumpDispatcher

    $renderElement = [System.Windows.FrameworkElement] $window.Content
    $renderWidth = [Math]::Max(1, [int] [Math]::Ceiling($renderElement.ActualWidth))
    $renderHeight = [Math]::Max(1, [int] [Math]::Ceiling($renderElement.ActualHeight))
    $renderTarget = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
        $renderWidth,
        $renderHeight,
        96,
        96,
        [System.Windows.Media.PixelFormats]::Pbgra32
    )
    $renderTarget.Render($renderElement)
    $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($renderTarget))
    $fileStream = [System.IO.File]::Open(
        $resolvedScreenshotPath,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    try {
        $encoder.Save($fileStream)
    } finally {
        $fileStream.Dispose()
    }
    $window.Close()
    return
}

if ($GuiSmokeTest) {
    $window.ShowInTaskbar = $false
    $window.Opacity = 0
    $window.Show()
    $window.UpdateLayout()
    & $pumpDispatcher
    $librarySmokeParameters = @{
        Owner = $window
        XamlPath = Join-Path $scriptDirectory 'LibraryWindow.xaml'
        IcoDialogXamlPath = Join-Path $scriptDirectory 'IcoExportWindow.xaml'
        RootPath = $script:LibraryRoot
        SmokeTest = $true
    }
    Show-IconLibraryWindow @librarySmokeParameters
    [void] (Show-IcoSizeDialog -Owner $window -XamlPath (Join-Path $scriptDirectory 'IcoExportWindow.xaml') -SmokeTest)
    [void] (Show-LibrarySettingsDialog `
        -Owner $window `
        -XamlPath (Join-Path $scriptDirectory 'LibrarySettingsWindow.xaml') `
        -CurrentRoot $script:LibraryRoot `
        -LocalRoot (Get-DefaultIconLibraryRoot) `
        -SmokeTest)
    $window.Close()
    return
}

[void] $window.ShowDialog()
