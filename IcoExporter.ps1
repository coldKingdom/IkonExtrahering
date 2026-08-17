Set-StrictMode -Version Latest

function Assert-IcoSizes {
    param([Parameter(Mandatory)] [int[]] $Sizes)

    $allowed = [System.Collections.Generic.HashSet[int]]::new([int[]] @(16, 24, 32, 48, 64, 128, 256))
    $normalized = @($Sizes | Sort-Object -Unique)
    if ($normalized.Count -eq 0) {
        throw 'Välj minst en storlek för ICO-filen.'
    }
    foreach ($size in $normalized) {
        if (-not $allowed.Contains($size)) {
            throw "ICO-storleken $size stöds inte."
        }
    }
    return [int[]] $normalized
}

function Get-PngFrameBytes {
    param([Parameter(Mandatory)] [System.Drawing.Bitmap] $Bitmap)

    $stream = [System.IO.MemoryStream]::new()
    try {
        $Bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return $stream.ToArray()
    } finally {
        $stream.Dispose()
    }
}

function Get-DibIconFrameBytes {
    param([Parameter(Mandatory)] [System.Drawing.Bitmap] $Bitmap)

    if ($Bitmap.Width -ne $Bitmap.Height) {
        throw 'ICO-bilden måste vara kvadratisk.'
    }
    $size = $Bitmap.Width
    $converted = $Bitmap.Clone(
        [System.Drawing.Rectangle]::new(0, 0, $size, $size),
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    try {
        $rectangle = [System.Drawing.Rectangle]::new(0, 0, $size, $size)
        $bitmapData = $converted.LockBits(
            $rectangle,
            [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
            [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
        )
        try {
            $absoluteStride = [Math]::Abs($bitmapData.Stride)
            $rowBytes = $size * 4
            $maskStride = [int] ([Math]::Ceiling($size / 32.0) * 4)
            $xorBytes = [byte[]]::new($rowBytes * $size)
            $maskBytes = [byte[]]::new($maskStride * $size)
            $row = [byte[]]::new($absoluteStride)

            for ($outputRow = 0; $outputRow -lt $size; $outputRow++) {
                $sourceY = $size - 1 - $outputRow
                $sourceOffset = if ($bitmapData.Stride -ge 0) {
                    $sourceY * $absoluteStride
                } else {
                    ($size - 1 - $sourceY) * $absoluteStride
                }
                [System.Runtime.InteropServices.Marshal]::Copy(
                    [IntPtr]::Add($bitmapData.Scan0, $sourceOffset),
                    $row,
                    0,
                    $absoluteStride
                )
                [Array]::Copy($row, 0, $xorBytes, $outputRow * $rowBytes, $rowBytes)

                for ($x = 0; $x -lt $size; $x++) {
                    $alpha = $row[($x * 4) + 3]
                    if ($alpha -eq 0) {
                        $maskIndex = ($outputRow * $maskStride) + [int] [Math]::Floor($x / 8)
                        $maskBytes[$maskIndex] = $maskBytes[$maskIndex] -bor (0x80 -shr ($x % 8))
                    }
                }
            }
        } finally {
            $converted.UnlockBits($bitmapData)
        }

        $stream = [System.IO.MemoryStream]::new()
        $writer = [System.IO.BinaryWriter]::new($stream)
        try {
            $imageByteCount = $xorBytes.Length + $maskBytes.Length
            $writer.Write([uint32] 40)
            $writer.Write([int32] $size)
            $writer.Write([int32] ($size * 2))
            $writer.Write([uint16] 1)
            $writer.Write([uint16] 32)
            $writer.Write([uint32] 0)
            $writer.Write([uint32] $imageByteCount)
            $writer.Write([int32] 0)
            $writer.Write([int32] 0)
            $writer.Write([uint32] 0)
            $writer.Write([uint32] 0)
            $writer.Write($xorBytes)
            $writer.Write($maskBytes)
            $writer.Flush()
            return $stream.ToArray()
        } finally {
            $writer.Dispose()
            $stream.Dispose()
        }
    } finally {
        $converted.Dispose()
    }
}

function Save-MultiSizeIcon {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Images
    )

    $sizes = Assert-IcoSizes -Sizes ([int[]] @($Images.Keys))
    $frames = [System.Collections.Generic.List[object]]::new()
    foreach ($size in $sizes) {
        $bitmap = $Images[$size]
        if ($null -eq $bitmap -or $bitmap.Width -ne $size -or $bitmap.Height -ne $size) {
            throw "Bildposten för $size × $size px saknas eller har fel dimensioner."
        }
        $bytes = if ($size -eq 256) {
            Get-PngFrameBytes -Bitmap $bitmap
        } else {
            Get-DibIconFrameBytes -Bitmap $bitmap
        }
        [void] $frames.Add([pscustomobject]@{ Size = $size; Bytes = [byte[]] $bytes })
    }

    $destination = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($destination)
    if (-not [System.IO.Directory]::Exists($directory)) {
        throw "Målmappen finns inte: $directory"
    }
    $temporaryPath = Join-Path $directory ('ico-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        $stream = [System.IO.File]::Open(
            $temporaryPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $writer = [System.IO.BinaryWriter]::new($stream)
        try {
            $writer.Write([uint16] 0)
            $writer.Write([uint16] 1)
            $writer.Write([uint16] $frames.Count)
            [uint32] $dataOffset = 6 + (16 * $frames.Count)
            foreach ($frame in $frames) {
                $dimensionByte = if ($frame.Size -eq 256) { [byte] 0 } else { [byte] $frame.Size }
                $writer.Write($dimensionByte)
                $writer.Write($dimensionByte)
                $writer.Write([byte] 0)
                $writer.Write([byte] 0)
                $writer.Write([uint16] 1)
                $writer.Write([uint16] 32)
                $writer.Write([uint32] $frame.Bytes.Length)
                $writer.Write([uint32] $dataOffset)
                $dataOffset += [uint32] $frame.Bytes.Length
            }
            foreach ($frame in $frames) {
                $writer.Write([byte[]] $frame.Bytes)
            }
            $writer.Flush()
            $stream.Flush($true)
        } finally {
            $writer.Dispose()
            $stream.Dispose()
        }
        [System.IO.File]::Move($temporaryPath, $destination, $true)
    } finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}

function Save-ExecutableIconAsIco {
    param(
        [Parameter(Mandatory)] [string] $SourcePath,
        [Parameter(Mandatory)] [int] $IconIndex,
        [Parameter(Mandatory)] [int[]] $Sizes,
        [Parameter(Mandatory)] [string] $DestinationPath
    )

    $normalizedSizes = Assert-IcoSizes -Sizes $Sizes
    $images = [System.Collections.Generic.Dictionary[int, System.Drawing.Bitmap]]::new()
    try {
        foreach ($size in $normalizedSizes) {
            $images[$size] = Get-IconBitmap -Path $SourcePath -Index $IconIndex -Size $size
        }
        Save-MultiSizeIcon -Path $DestinationPath -Images $images
    } finally {
        foreach ($bitmap in $images.Values) { $bitmap.Dispose() }
    }
}

function Save-PngIconAsIco {
    param(
        [Parameter(Mandatory)] [string] $SourcePath,
        [Parameter(Mandatory)] [int[]] $Sizes,
        [Parameter(Mandatory)] [string] $DestinationPath
    )

    $normalizedSizes = Assert-IcoSizes -Sizes $Sizes
    $sourceImage = [System.Drawing.Image]::FromFile($SourcePath)
    $images = [System.Collections.Generic.Dictionary[int, System.Drawing.Bitmap]]::new()
    try {
        foreach ($size in $normalizedSizes) {
            $images[$size] = ConvertTo-SquareBitmap -Image $sourceImage -Size $size
        }
        Save-MultiSizeIcon -Path $DestinationPath -Images $images
    } finally {
        foreach ($bitmap in $images.Values) { $bitmap.Dispose() }
        $sourceImage.Dispose()
    }
}

function Get-IcoDirectoryInfo {
    param([Parameter(Mandatory)] [string] $Path)

    $stream = [System.IO.File]::OpenRead([System.IO.Path]::GetFullPath($Path))
    $reader = [System.IO.BinaryReader]::new($stream)
    try {
        $reserved = $reader.ReadUInt16()
        $type = $reader.ReadUInt16()
        $count = $reader.ReadUInt16()
        if ($reserved -ne 0 -or $type -ne 1 -or $count -lt 1) {
            throw 'Filen har inte en giltig ICO-katalog.'
        }
        $entries = @()
        for ($index = 0; $index -lt $count; $index++) {
            $widthByte = $reader.ReadByte()
            $heightByte = $reader.ReadByte()
            [void] $reader.ReadByte()
            [void] $reader.ReadByte()
            $planes = $reader.ReadUInt16()
            $bits = $reader.ReadUInt16()
            $length = $reader.ReadUInt32()
            $offset = $reader.ReadUInt32()
            $entries += [pscustomobject]@{
                Width = if ($widthByte -eq 0) { 256 } else { [int] $widthByte }
                Height = if ($heightByte -eq 0) { 256 } else { [int] $heightByte }
                Planes = $planes
                BitDepth = $bits
                Length = $length
                Offset = $offset
            }
        }
        return [pscustomobject]@{ Count = $count; Entries = $entries }
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}
