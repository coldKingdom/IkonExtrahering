Set-StrictMode -Version Latest

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:IconLibrarySchemaVersion = 2
$script:IconLibraryLockTimeoutMilliseconds = 20000

function Normalize-IconTags {
    param([object[]] $Tags)

    $result = [System.Collections.Generic.List[string]]::new()
    $known = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::CurrentCultureIgnoreCase
    )
    foreach ($tagValue in @($Tags)) {
        if ($null -eq $tagValue) { continue }
        $tag = ([string] $tagValue).Trim()
        if ([string]::IsNullOrWhiteSpace($tag)) { continue }
        if ($tag.Length -gt 30) { $tag = $tag.Substring(0, 30).Trim() }
        if ($known.Add($tag)) {
            [void] $result.Add($tag)
            if ($result.Count -eq 20) { break }
        }
    }
    # Returnera själva listobjektet även när det är tomt. En tom PowerShell-array
    # blir annars $null när den används som egenskap och serialiseras felaktigt.
    return ,$result
}

function Test-IconLibraryItemMatch {
    param(
        [Parameter(Mandatory)] $Item,
        [string] $SearchText,
        [bool] $FavoritesOnly = $false
    )

    if ($FavoritesOnly -and -not [bool] $Item.Favorite) { return $false }
    $needle = if ($null -eq $SearchText) { '' } else { $SearchText.Trim() }
    if ([string]::IsNullOrWhiteSpace($needle)) { return $true }
    foreach ($value in @($Item.Name, $Item.SourceFileName) + @($Item.Tags)) {
        if (-not [string]::IsNullOrEmpty([string] $value) -and
            ([string] $value).IndexOf($needle, [System.StringComparison]::CurrentCultureIgnoreCase) -ge 0) {
            return $true
        }
    }
    return $false
}

function ConvertTo-IconLibraryV2Item {
    param([Parameter(Mandatory)] $Item)

    $tags = if ($null -ne $Item.PSObject.Properties['Tags']) {
        Normalize-IconTags -Tags @($Item.Tags)
    } else { [System.Collections.Generic.List[string]]::new() }
    $favorite = if ($null -ne $Item.PSObject.Properties['Favorite']) {
        [bool] $Item.Favorite
    } else { $false }
    return [pscustomobject]@{
        Id = [string] $Item.Id
        Name = [string] $Item.Name
        SourceFileName = [string] $Item.SourceFileName
        SourceIndex = [int] $Item.SourceIndex
        AddedUtc = [string] $Item.AddedUtc
        ImageFile = [string] $Item.ImageFile
        Sha256 = [string] $Item.Sha256
        Width = [int] $Item.Width
        Height = [int] $Item.Height
        Tags = $tags
        Favorite = $favorite
    }
}

function Get-IconLibraryRoot {
    param([string] $RootPath)

    if (-not [string]::IsNullOrWhiteSpace($RootPath)) {
        return [System.IO.Path]::GetFullPath($RootPath)
    }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA saknas och bibliotekets lagringsplats kan inte bestämmas.'
    }
    return [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Ikonextraheraren')
}

function Initialize-IconLibrary {
    param([string] $RootPath)

    $root = Get-IconLibraryRoot -RootPath $RootPath
    $images = Join-Path $root 'icons'
    [void] [System.IO.Directory]::CreateDirectory($root)
    [void] [System.IO.Directory]::CreateDirectory($images)
    return [pscustomobject]@{
        Root = $root
        Images = $images
        Database = Join-Path $root 'library.json'
        Lock = Join-Path $root 'library.lock'
    }
}

function Enter-IconLibraryLock {
    param(
        [string] $RootPath,
        [int] $TimeoutMilliseconds = $script:IconLibraryLockTimeoutMilliseconds
    )

    $paths = Initialize-IconLibrary -RootPath $RootPath
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $lastError = $null
    do {
        try {
            $stream = [System.IO.File]::Open(
                $paths.Lock,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
            return [pscustomobject]@{ Stream = $stream; Paths = $paths }
        } catch [System.IO.IOException] {
            $lastError = $_.Exception
            if ($timer.ElapsedMilliseconds -ge $TimeoutMilliseconds) { break }
            Start-Sleep -Milliseconds (50 + [System.Random]::Shared.Next(0, 75))
        }
    } while ($true)

    throw [System.TimeoutException]::new(
        'Ikonbiblioteket används av någon annan. Försök igen om en liten stund.',
        $lastError
    )
}

function Invoke-WithIconLibraryLock {
    param(
        [string] $RootPath,
        [Parameter(Mandatory)] [scriptblock] $Action,
        [int] $TimeoutMilliseconds = $script:IconLibraryLockTimeoutMilliseconds
    )

    $lock = Enter-IconLibraryLock -RootPath $RootPath -TimeoutMilliseconds $TimeoutMilliseconds
    try {
        return & $Action $lock.Paths
    } finally {
        $lock.Stream.Dispose()
    }
}

function New-EmptyIconLibraryCatalog {
    return [pscustomobject]@{
        Version = $script:IconLibrarySchemaVersion
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        Items = @()
    }
}

function Read-IconLibraryCatalogUnlocked {
    param([Parameter(Mandatory)] $Paths)

    $paths = $Paths
    if (-not [System.IO.File]::Exists($paths.Database)) {
        return New-EmptyIconLibraryCatalog
    }

    try {
        $json = [System.IO.File]::ReadAllText($paths.Database, [System.Text.Encoding]::UTF8)
        $catalog = $json | ConvertFrom-Json -Depth 20
    } catch {
        throw "Det lokala ikonbiblioteket kunde inte läsas: $($_.Exception.Message)"
    }

    if ($null -eq $catalog -or [int] $catalog.Version -notin @(1, $script:IconLibrarySchemaVersion)) {
        throw 'Ikonbibliotekets databas har en version som inte stöds.'
    }
    $sourceVersion = [int] $catalog.Version
    $catalog.Items = @($catalog.Items | ForEach-Object { ConvertTo-IconLibraryV2Item -Item $_ })
    $catalog.Version = $script:IconLibrarySchemaVersion
    if ($sourceVersion -eq 1) {
        Write-IconLibraryCatalogUnlocked -Catalog $catalog -Paths $paths
    }
    return $catalog
}

function Write-IconLibraryCatalogUnlocked {
    param(
        [Parameter(Mandatory)] $Catalog,
        [Parameter(Mandatory)] $Paths
    )

    $paths = $Paths
    $Catalog.Version = $script:IconLibrarySchemaVersion
    $Catalog.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    $json = $Catalog | ConvertTo-Json -Depth 8
    $temporaryPath = Join-Path $paths.Root ('library-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText(
            $temporaryPath,
            $json,
            [System.Text.UTF8Encoding]::new($false)
        )
        [System.IO.File]::Move($temporaryPath, $paths.Database, $true)
    } finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}

function Read-IconLibraryCatalog {
    param([string] $RootPath)

    return Invoke-WithIconLibraryLock -RootPath $RootPath -Action {
        param($paths)
        Read-IconLibraryCatalogUnlocked -Paths $paths
    }
}

function Write-IconLibraryCatalog {
    param(
        [Parameter(Mandatory)] $Catalog,
        [string] $RootPath
    )

    Invoke-WithIconLibraryLock -RootPath $RootPath -Action {
        param($paths)
        Write-IconLibraryCatalogUnlocked -Catalog $Catalog -Paths $paths
    }
}

function Get-IconBytesHash {
    param([Parameter(Mandatory)] [byte[]] $Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [Convert]::ToHexString($sha.ComputeHash($Bytes))
    } finally {
        $sha.Dispose()
    }
}

function Test-PngBytes {
    param([Parameter(Mandatory)] [byte[]] $Bytes)

    if ($Bytes.Length -lt 8 -or $Bytes.Length -gt 20MB) {
        throw 'Ikonbilden har en ogiltig storlek.'
    }
    $pngSignature = [byte[]] @(137, 80, 78, 71, 13, 10, 26, 10)
    for ($index = 0; $index -lt $pngSignature.Length; $index++) {
        if ($Bytes[$index] -ne $pngSignature[$index]) {
            throw 'Ikonbilden är inte en giltig PNG-fil.'
        }
    }

    $stream = [System.IO.MemoryStream]::new($Bytes, $false)
    try {
        $image = [System.Drawing.Image]::FromStream($stream, $true, $true)
        try {
            if ($image.Width -lt 1 -or $image.Height -lt 1 -or
                $image.Width -gt 4096 -or $image.Height -gt 4096) {
                throw 'Ikonbildens dimensioner stöds inte.'
            }
            return [pscustomobject]@{ Width = $image.Width; Height = $image.Height }
        } finally {
            $image.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Add-IconLibraryItem {
    param(
        [Parameter(Mandatory)] [byte[]] $PngBytes,
        [Parameter(Mandatory)] [string] $Name,
        [string] $SourceFileName,
        [int] $SourceIndex = -1,
        [string] $RootPath
    )

    $dimensions = Test-PngBytes -Bytes $PngBytes
    $hash = Get-IconBytesHash -Bytes $PngBytes
    return Invoke-WithIconLibraryLock -RootPath $RootPath -Action {
        param($paths)
        $catalog = Read-IconLibraryCatalogUnlocked -Paths $paths
        $duplicate = @($catalog.Items | Where-Object Sha256 -EQ $hash | Select-Object -First 1)
        if ($duplicate.Count -gt 0) {
            return [pscustomobject]@{ Added = $false; Item = $duplicate[0] }
        }

        $id = [guid]::NewGuid().ToString('N')
        $imageFile = "$id.png"
        $imagePath = Join-Path $paths.Images $imageFile
        $safeName = if ([string]::IsNullOrWhiteSpace($Name)) { 'Namnlös ikon' } else { $Name.Trim() }
        if ($safeName.Length -gt 120) { $safeName = $safeName.Substring(0, 120) }
        $sourceName = if ([string]::IsNullOrWhiteSpace($SourceFileName)) {
            ''
        } else {
            [System.IO.Path]::GetFileName($SourceFileName)
        }

        $item = [pscustomobject]@{
            Id = $id
            Name = $safeName
            SourceFileName = $sourceName
            SourceIndex = $SourceIndex
            AddedUtc = [DateTime]::UtcNow.ToString('o')
            ImageFile = $imageFile
            Sha256 = $hash
            Width = [int] $dimensions.Width
            Height = [int] $dimensions.Height
            Tags = [System.Collections.Generic.List[string]]::new()
            Favorite = $false
        }

        [System.IO.File]::WriteAllBytes($imagePath, $PngBytes)
        try {
            $catalog.Items = @($catalog.Items) + $item
            Write-IconLibraryCatalogUnlocked -Catalog $catalog -Paths $paths
        } catch {
            if ([System.IO.File]::Exists($imagePath)) { [System.IO.File]::Delete($imagePath) }
            throw
        }
        return [pscustomobject]@{ Added = $true; Item = $item }
    }
}

function Remove-IconLibraryItem {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [string] $RootPath
    )

    return Invoke-WithIconLibraryLock -RootPath $RootPath -Action {
        param($paths)
        $catalog = Read-IconLibraryCatalogUnlocked -Paths $paths
        $item = @($catalog.Items | Where-Object Id -EQ $Id | Select-Object -First 1)
        if ($item.Count -eq 0) { return $false }

        $catalog.Items = @($catalog.Items | Where-Object Id -NE $Id)
        Write-IconLibraryCatalogUnlocked -Catalog $catalog -Paths $paths
        $imageName = [System.IO.Path]::GetFileName([string] $item[0].ImageFile)
        $imagePath = Join-Path $paths.Images $imageName
        if ([System.IO.File]::Exists($imagePath)) {
            [System.IO.File]::Delete($imagePath)
        }
        return $true
    }
}

function Update-IconLibraryItemMetadata {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [object[]] $Tags,
        [Nullable[bool]] $Favorite,
        [string] $RootPath
    )

    $updateTags = $PSBoundParameters.ContainsKey('Tags')
    $updateFavorite = $PSBoundParameters.ContainsKey('Favorite') -and $null -ne $Favorite
    return Invoke-WithIconLibraryLock -RootPath $RootPath -Action {
        param($paths)
        $catalog = Read-IconLibraryCatalogUnlocked -Paths $paths
        $item = @($catalog.Items | Where-Object Id -EQ $Id | Select-Object -First 1)
        if ($item.Count -eq 0) { throw 'Biblioteksposten finns inte längre.' }
        if ($updateTags) {
            $item[0].Tags = Normalize-IconTags -Tags $Tags
        }
        if ($updateFavorite) {
            $item[0].Favorite = [bool] $Favorite
        }
        Write-IconLibraryCatalogUnlocked -Catalog $catalog -Paths $paths
        return $item[0]
    }
}

function Get-IconLibraryImagePath {
    param(
        [Parameter(Mandatory)] $Item,
        [string] $RootPath
    )

    $paths = Initialize-IconLibrary -RootPath $RootPath
    $imageName = [System.IO.Path]::GetFileName([string] $Item.ImageFile)
    return Join-Path $paths.Images $imageName
}

function Export-IconLibraryArchiveUnlocked {
    param(
        [Parameter(Mandatory)] [string] $DestinationPath,
        [Parameter(Mandatory)] $Paths
    )

    $paths = $Paths
    $catalog = Read-IconLibraryCatalogUnlocked -Paths $paths
    $destination = [System.IO.Path]::GetFullPath($DestinationPath)
    $stream = [System.IO.File]::Open(
        $destination,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    try {
        $archive = [System.IO.Compression.ZipArchive]::new(
            $stream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $false,
            [System.Text.Encoding]::UTF8
        )
        try {
            $databaseEntry = $archive.CreateEntry(
                'database.json',
                [System.IO.Compression.CompressionLevel]::Optimal
            )
            $entryStream = $databaseEntry.Open()
            $writer = [System.IO.StreamWriter]::new(
                $entryStream,
                [System.Text.UTF8Encoding]::new($false)
            )
            try {
                $writer.Write(($catalog | ConvertTo-Json -Depth 8))
            } finally {
                $writer.Dispose()
            }

            foreach ($item in @($catalog.Items)) {
                $imageName = [System.IO.Path]::GetFileName([string] $item.ImageFile)
                $imagePath = Join-Path $paths.Images $imageName
                if (-not [System.IO.File]::Exists($imagePath)) {
                    throw "Bildfilen för '$($item.Name)' saknas i det lokala biblioteket."
                }
                [void] [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $archive,
                    $imagePath,
                    "images/$imageName",
                    [System.IO.Compression.CompressionLevel]::Optimal
                )
            }
        } finally {
            $archive.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
    return $catalog.Items.Count
}

function Export-IconLibraryArchive {
    param(
        [Parameter(Mandatory)] [string] $DestinationPath,
        [string] $RootPath
    )

    return Invoke-WithIconLibraryLock -RootPath $RootPath -Action {
        param($paths)
        Export-IconLibraryArchiveUnlocked -DestinationPath $DestinationPath -Paths $paths
    }
}

function Import-IconLibraryArchiveUnlocked {
    param(
        [Parameter(Mandatory)] [string] $ArchivePath,
        [Parameter(Mandatory)] $Paths
    )

    $archiveFile = [System.IO.Path]::GetFullPath($ArchivePath)
    $stream = [System.IO.File]::OpenRead($archiveFile)
    $pendingItems = [System.Collections.Generic.List[object]]::new()
    $skipped = 0
    $merged = 0
    $metadataChanged = $false
    $existingCatalog = $null
    try {
        $archive = [System.IO.Compression.ZipArchive]::new(
            $stream,
            [System.IO.Compression.ZipArchiveMode]::Read,
            $false,
            [System.Text.Encoding]::UTF8
        )
        try {
            $databaseEntry = $archive.GetEntry('database.json')
            if ($null -eq $databaseEntry -or $databaseEntry.Length -lt 2 -or $databaseEntry.Length -gt 5MB) {
                throw 'Arkivet saknar en giltig database.json.'
            }
            $reader = [System.IO.StreamReader]::new($databaseEntry.Open(), [System.Text.Encoding]::UTF8)
            try {
                $importCatalog = $reader.ReadToEnd() | ConvertFrom-Json -Depth 20
            } finally {
                $reader.Dispose()
            }
            if ($null -eq $importCatalog -or [int] $importCatalog.Version -notin @(1, $script:IconLibrarySchemaVersion)) {
                throw 'Biblioteksarkivets version stöds inte.'
            }

            $items = @($importCatalog.Items)
            if ($items.Count -gt 10000) { throw 'Arkivet innehåller orimligt många poster.' }
            $existingCatalog = Read-IconLibraryCatalogUnlocked -Paths $Paths
            $knownHashes = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )
            $existingByHash = @{}
            foreach ($existingItem in @($existingCatalog.Items)) {
                [void] $knownHashes.Add([string] $existingItem.Sha256)
                $existingByHash[[string] $existingItem.Sha256] = $existingItem
            }

            [long] $totalBytes = 0
            foreach ($item in $items) {
                $declaredHash = [string] $item.Sha256
                if ($declaredHash -notmatch '^[0-9A-Fa-f]{64}$') {
                    throw 'Arkivet innehåller en post med ogiltig SHA-256-kontrollsumma.'
                }
                if ($knownHashes.Contains($declaredHash)) {
                    if ($existingByHash.ContainsKey($declaredHash)) {
                        $existingItem = $existingByHash[$declaredHash]
                        $importTags = if ($null -ne $item.PSObject.Properties['Tags']) {
                            @($item.Tags)
                        } else { @() }
                        $combinedTags = Normalize-IconTags -Tags (@($existingItem.Tags) + $importTags)
                        $importFavorite = if ($null -ne $item.PSObject.Properties['Favorite']) {
                            [bool] $item.Favorite
                        } else { $false }
                        $tagsChanged = ($combinedTags.Count -ne @($existingItem.Tags).Count) -or
                            (($combinedTags -join "`0") -cne (@($existingItem.Tags) -join "`0"))
                        $favoriteChanged = $importFavorite -and -not [bool] $existingItem.Favorite
                        if ($tagsChanged -or $favoriteChanged) {
                            $existingItem.Tags = $combinedTags
                            $existingItem.Favorite = ([bool] $existingItem.Favorite -or $importFavorite)
                            $metadataChanged = $true
                            $merged++
                        }
                    }
                    $skipped++
                    continue
                }

                $imageName = [System.IO.Path]::GetFileName([string] $item.ImageFile)
                if ([string]::IsNullOrWhiteSpace($imageName) -or $imageName -ne [string] $item.ImageFile) {
                    throw 'Arkivet innehåller ett ogiltigt bildfilnamn.'
                }
                $imageEntry = $archive.GetEntry("images/$imageName")
                if ($null -eq $imageEntry -or $imageEntry.Length -lt 8 -or $imageEntry.Length -gt 20MB) {
                    throw "Bildposten '$imageName' saknas eller är för stor."
                }
                $totalBytes += $imageEntry.Length
                if ($totalBytes -gt 200MB) { throw 'Biblioteksarkivet är för stort.' }

                $memory = [System.IO.MemoryStream]::new()
                $entryStream = $imageEntry.Open()
                try {
                    $entryStream.CopyTo($memory)
                } finally {
                    $entryStream.Dispose()
                }
                $bytes = $memory.ToArray()
                $memory.Dispose()
                $actualHash = Get-IconBytesHash -Bytes $bytes
                if ($actualHash -ne $declaredHash.ToUpperInvariant()) {
                    throw "Kontrollsumman stämmer inte för '$imageName'."
                }
                $dimensions = Test-PngBytes -Bytes $bytes
                [void] $pendingItems.Add([pscustomobject]@{
                    Bytes = $bytes
                    Original = $item
                    Hash = $actualHash
                    Width = $dimensions.Width
                    Height = $dimensions.Height
                })
                [void] $knownHashes.Add($actualHash)
            }
        } finally {
            $archive.Dispose()
        }
    } finally {
        $stream.Dispose()
    }

    if ($metadataChanged) {
        Write-IconLibraryCatalogUnlocked -Catalog $existingCatalog -Paths $Paths
    }
    if ($pendingItems.Count -eq 0) {
        return [pscustomobject]@{ Imported = 0; Skipped = $skipped; Merged = $merged }
    }

    $catalog = $existingCatalog
    $paths = $Paths
    $createdPaths = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($pending in $pendingItems) {
            $id = [guid]::NewGuid().ToString('N')
            $imageFile = "$id.png"
            $imagePath = Join-Path $paths.Images $imageFile
            [System.IO.File]::WriteAllBytes($imagePath, [byte[]] $pending.Bytes)
            [void] $createdPaths.Add($imagePath)
            $originalName = [string] $pending.Original.Name
            if ([string]::IsNullOrWhiteSpace($originalName)) { $originalName = 'Importerad ikon' }
            if ($originalName.Length -gt 120) { $originalName = $originalName.Substring(0, 120) }
            $sourceName = if ($null -ne $pending.Original.PSObject.Properties['SourceFileName']) {
                [System.IO.Path]::GetFileName([string] $pending.Original.SourceFileName)
            } else { '' }
            $sourceIndex = if ($null -ne $pending.Original.PSObject.Properties['SourceIndex']) {
                [int] $pending.Original.SourceIndex
            } else { -1 }
            $tags = if ($null -ne $pending.Original.PSObject.Properties['Tags']) {
                Normalize-IconTags -Tags @($pending.Original.Tags)
            } else { [System.Collections.Generic.List[string]]::new() }
            $favorite = if ($null -ne $pending.Original.PSObject.Properties['Favorite']) {
                [bool] $pending.Original.Favorite
            } else { $false }
            $catalog.Items = @($catalog.Items) + [pscustomobject]@{
                Id = $id
                Name = $originalName
                SourceFileName = $sourceName
                SourceIndex = $sourceIndex
                AddedUtc = [DateTime]::UtcNow.ToString('o')
                ImageFile = $imageFile
                Sha256 = $pending.Hash
                Width = [int] $pending.Width
                Height = [int] $pending.Height
                Tags = $tags
                Favorite = $favorite
            }
        }
        Write-IconLibraryCatalogUnlocked -Catalog $catalog -Paths $paths
    } catch {
        foreach ($createdPath in $createdPaths) {
            if ([System.IO.File]::Exists($createdPath)) { [System.IO.File]::Delete($createdPath) }
        }
        throw
    }
    return [pscustomobject]@{ Imported = $pendingItems.Count; Skipped = $skipped; Merged = $merged }
}

function Import-IconLibraryArchive {
    param(
        [Parameter(Mandatory)] [string] $ArchivePath,
        [string] $RootPath
    )

    return Invoke-WithIconLibraryLock -RootPath $RootPath -Action {
        param($paths)
        Import-IconLibraryArchiveUnlocked -ArchivePath $ArchivePath -Paths $paths
    }
}
