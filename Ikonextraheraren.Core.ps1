[CmdletBinding()]
param(
    [switch] $SelfTest,
    [switch] $GuiSmokeTest,
    [switch] $LibraryOnly,
    [string] $FilePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'Ikonextraheraren kräver Windows och PowerShell 7.'
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try {
    [void] [System.Windows.Forms.Application]::SetHighDpiMode(
        [System.Windows.Forms.HighDpiMode]::PerMonitorV2
    )
} catch {
    # DPI-läget kan redan vara låst om Forms har initialiserats av värdprocessen.
}

$nativeSource = @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;

public static class IconResourceReader
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint ExtractIconEx(
        string szFileName,
        int nIconIndex,
        IntPtr[] phiconLarge,
        IntPtr[] phiconSmall,
        uint nIcons);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint PrivateExtractIcons(
        string szFileName,
        int nIconIndex,
        int cxIcon,
        int cyIcon,
        IntPtr[] phicon,
        uint[] piconid,
        uint nIcons,
        uint flags);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr hIcon);

    public static int GetIconCount(string path)
    {
        if (String.IsNullOrWhiteSpace(path))
            throw new ArgumentException("En filsökväg krävs.", "path");

        uint count = ExtractIconEx(path, -1, null, null, 0);
        return checked((int)count);
    }

    public static Icon ExtractIcon(string path, int index, int size)
    {
        if (index < 0) throw new ArgumentOutOfRangeException("index");
        if (size < 1) throw new ArgumentOutOfRangeException("size");

        IntPtr[] handles = new IntPtr[1];
        uint[] resourceIds = new uint[1];
        uint extracted = PrivateExtractIcons(
            path, index, size, size, handles, resourceIds, 1, 0);

        if (extracted > 0 && handles[0] != IntPtr.Zero)
        {
            try
            {
                using (Icon borrowed = Icon.FromHandle(handles[0]))
                    return (Icon)borrowed.Clone();
            }
            finally
            {
                DestroyIcon(handles[0]);
            }
        }

        IntPtr[] large = new IntPtr[1];
        IntPtr[] small = new IntPtr[1];
        extracted = ExtractIconEx(path, index, large, small, 1);
        IntPtr fallback = large[0] != IntPtr.Zero ? large[0] : small[0];

        if (extracted == 0 || fallback == IntPtr.Zero)
            throw new InvalidOperationException(
                "Ikonen kunde inte läsas från filen (Win32-fel " +
                Marshal.GetLastWin32Error().ToString() + ").");

        try
        {
            using (Icon borrowed = Icon.FromHandle(fallback))
                return (Icon)borrowed.Clone();
        }
        finally
        {
            if (large[0] != IntPtr.Zero) DestroyIcon(large[0]);
            if (small[0] != IntPtr.Zero) DestroyIcon(small[0]);
        }
    }
}
'@

if (-not ('IconResourceReader' -as [type])) {
    $drawingReferences = @([System.Drawing.Icon].Assembly.Location)
    $windowsDrawingAssemblies = [AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object FullName -Like 'System.Private.Windows.*' |
        Where-Object { -not [string]::IsNullOrEmpty($_.Location) }
    foreach ($assembly in $windowsDrawingAssemblies) {
        $drawingReferences += $assembly.Location
    }
    Add-Type -TypeDefinition $nativeSource -ReferencedAssemblies $drawingReferences
}

function ConvertTo-SquareBitmap {
    param(
        [Parameter(Mandatory)] [System.Drawing.Image] $Image,
        [Parameter(Mandatory)] [int] $Size
    )

    $bitmap = [System.Drawing.Bitmap]::new(
        $Size,
        $Size,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $destination = [System.Drawing.Rectangle]::new(0, 0, $Size, $Size)
        $graphics.DrawImage($Image, $destination)
    } finally {
        $graphics.Dispose()
    }
    return $bitmap
}

function Get-IconBitmap {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [int] $Index,
        [Parameter(Mandatory)] [int] $Size,
        [hashtable] $Cache
    )

    $key = '{0}:{1}' -f $Index, $Size
    if ($null -ne $Cache -and $Cache.ContainsKey($key)) {
        return $Cache[$key]
    }

    $icon = [IconResourceReader]::ExtractIcon($Path, $Index, $Size)
    try {
        $source = $icon.ToBitmap()
        try {
            $bitmap = ConvertTo-SquareBitmap -Image $source -Size $Size
        } finally {
            $source.Dispose()
        }
    } finally {
        $icon.Dispose()
    }

    if ($null -ne $Cache) {
        $Cache[$key] = $bitmap
    }
    return $bitmap
}

function Save-IconBitmap {
    param(
        [Parameter(Mandatory)] [System.Drawing.Bitmap] $Bitmap,
        [Parameter(Mandatory)] [string] $Path,
        [ValidateSet('PNG', 'JPG')] [string] $Format,
        [ValidateRange(1, 100)] [int] $JpegQuality = 92
    )

    if ($Format -eq 'PNG') {
        $Bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        return
    }

    $canvas = [System.Drawing.Bitmap]::new(
        $Bitmap.Width,
        $Bitmap.Height,
        [System.Drawing.Imaging.PixelFormat]::Format24bppRgb
    )
    $graphics = [System.Drawing.Graphics]::FromImage($canvas)
    try {
        $graphics.Clear([System.Drawing.Color]::White)
        $graphics.DrawImageUnscaled($Bitmap, 0, 0)

        $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
            Where-Object MimeType -eq 'image/jpeg' |
            Select-Object -First 1
        $encoderParameters = [System.Drawing.Imaging.EncoderParameters]::new(1)
        try {
            $encoderParameters.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new(
                [System.Drawing.Imaging.Encoder]::Quality,
                [long] $JpegQuality
            )
            $canvas.Save($Path, $codec, $encoderParameters)
        } finally {
            $encoderParameters.Dispose()
        }
    } finally {
        $graphics.Dispose()
        $canvas.Dispose()
    }
}

function Get-UniquePath {
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $Path }

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $extension = [System.IO.Path]::GetExtension($Path)
    $number = 2
    do {
        $candidate = Join-Path $directory ('{0}_{1}{2}' -f $stem, $number, $extension)
        $number++
    } while (Test-Path -LiteralPath $candidate)
    return $candidate
}

if ($SelfTest) {
    $testFile = Join-Path $env:SystemRoot 'System32\shell32.dll'
    $count = [IconResourceReader]::GetIconCount($testFile)
    if ($count -lt 1) { throw "Inga testikoner hittades i $testFile." }
    $testBitmap = Get-IconBitmap -Path $testFile -Index 0 -Size 48
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $testDirectory = Join-Path $tempRoot ('ikonextraheraren-test-' + [guid]::NewGuid().ToString('N'))
    [void] [System.IO.Directory]::CreateDirectory($testDirectory)
    try {
        if ($testBitmap.Width -ne 48 -or $testBitmap.Height -ne 48) {
            throw 'Testikonen fick oväntade dimensioner.'
        }

        $pngPath = Join-Path $testDirectory 'test.png'
        $jpgPath = Join-Path $testDirectory 'test.jpg'
        Save-IconBitmap -Bitmap $testBitmap -Path $pngPath -Format PNG
        Save-IconBitmap -Bitmap $testBitmap -Path $jpgPath -Format JPG -JpegQuality 90

        foreach ($imagePath in @($pngPath, $jpgPath)) {
            $savedImage = [System.Drawing.Image]::FromFile($imagePath)
            try {
                if ($savedImage.Width -ne 48 -or $savedImage.Height -ne 48) {
                    throw "Den sparade testbilden $imagePath fick fel dimensioner."
                }
            } finally {
                $savedImage.Dispose()
            }
        }
    } finally {
        $testBitmap.Dispose()
        $resolvedTestDirectory = [System.IO.Path]::GetFullPath($testDirectory)
        if ($resolvedTestDirectory.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
            [System.IO.Directory]::Exists($resolvedTestDirectory)) {
            [System.IO.Directory]::Delete($resolvedTestDirectory, $true)
        }
    }
    [pscustomobject]@{
        Resultat = 'OK'
        Testfil = $testFile
        AntalIkoner = $count
        Teststorlek = '48x48'
    }
    return
}

if ($LibraryOnly) {
    return
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:CurrentFile = $null
$script:CurrentIconCount = 0
$script:BitmapCache = @{}

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'Ikonextraheraren'
$form.Icon = [System.Drawing.SystemIcons]::Application
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.MinimumSize = [System.Drawing.Size]::new(900, 610)
$form.ClientSize = [System.Drawing.Size]::new(1080, 700)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.KeyPreview = $true
$form.AllowDrop = $true

$root = [System.Windows.Forms.TableLayoutPanel]::new()
$root.Dock = [System.Windows.Forms.DockStyle]::Fill
$root.Padding = [System.Windows.Forms.Padding]::new(12)
$root.RowCount = 3
$root.ColumnCount = 1
[void] $root.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void] $root.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
[void] $root.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
$form.Controls.Add($root)

$fileBar = [System.Windows.Forms.TableLayoutPanel]::new()
$fileBar.Dock = [System.Windows.Forms.DockStyle]::Fill
$fileBar.AutoSize = $true
$fileBar.ColumnCount = 3
$fileBar.RowCount = 1
$fileBar.Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 10)
[void] $fileBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void] $fileBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
[void] $fileBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
$root.Controls.Add($fileBar, 0, 0)

$openButton = [System.Windows.Forms.Button]::new()
$openButton.Text = 'Öppna EXE/DLL…'
$openButton.AutoSize = $true
$openButton.Padding = [System.Windows.Forms.Padding]::new(8, 3, 8, 3)
$openButton.Margin = [System.Windows.Forms.Padding]::new(0, 0, 8, 0)
$fileBar.Controls.Add($openButton, 0, 0)

$fileTextBox = [System.Windows.Forms.TextBox]::new()
$fileTextBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$fileTextBox.ReadOnly = $true
$fileTextBox.PlaceholderText = 'Välj en EXE- eller DLL-fil, eller släpp den här'
$fileTextBox.Margin = [System.Windows.Forms.Padding]::new(0, 4, 8, 0)
$fileBar.Controls.Add($fileTextBox, 1, 0)

$fileInfoLabel = [System.Windows.Forms.Label]::new()
$fileInfoLabel.Text = 'Ingen fil vald'
$fileInfoLabel.AutoSize = $true
$fileInfoLabel.Margin = [System.Windows.Forms.Padding]::new(0, 7, 0, 0)
$fileBar.Controls.Add($fileInfoLabel, 2, 0)

$split = [System.Windows.Forms.SplitContainer]::new()
$split.Dock = [System.Windows.Forms.DockStyle]::Fill
$split.Orientation = [System.Windows.Forms.Orientation]::Vertical
$split.Size = [System.Drawing.Size]::new(1000, 600)
$split.SplitterDistance = 600
$split.Panel1MinSize = 360
$split.Panel2MinSize = 280
$root.Controls.Add($split, 0, 1)

$thumbnailList = [System.Windows.Forms.ImageList]::new()
$thumbnailList.ImageSize = [System.Drawing.Size]::new(64, 64)
$thumbnailList.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit

$iconList = [System.Windows.Forms.ListView]::new()
$iconList.Dock = [System.Windows.Forms.DockStyle]::Fill
$iconList.View = [System.Windows.Forms.View]::LargeIcon
$iconList.LargeImageList = $thumbnailList
$iconList.MultiSelect = $false
$iconList.HideSelection = $false
$iconList.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 250)
$iconList.LargeImageList = $thumbnailList
$split.Panel1.Controls.Add($iconList)

$emptyLabel = [System.Windows.Forms.Label]::new()
$emptyLabel.Text = "Öppna eller släpp en EXE/DLL här`nför att visa dess ikoner"
$emptyLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$emptyLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$emptyLabel.ForeColor = [System.Drawing.Color]::DimGray
$emptyLabel.Font = [System.Drawing.Font]::new($form.Font.FontFamily, 13)
$emptyLabel.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 250)
$split.Panel1.Controls.Add($emptyLabel)
$emptyLabel.BringToFront()

$details = [System.Windows.Forms.TableLayoutPanel]::new()
$details.Dock = [System.Windows.Forms.DockStyle]::Fill
$details.Padding = [System.Windows.Forms.Padding]::new(16, 0, 0, 0)
$details.ColumnCount = 2
$details.RowCount = 8
[void] $details.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void] $details.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
[void] $details.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void] $details.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
1..6 | ForEach-Object {
    [void] $details.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
}
$split.Panel2.Controls.Add($details)

$previewTitle = [System.Windows.Forms.Label]::new()
$previewTitle.Text = 'Förhandsvisning'
$previewTitle.Font = [System.Drawing.Font]::new($form.Font, [System.Drawing.FontStyle]::Bold)
$previewTitle.AutoSize = $true
$previewTitle.Margin = [System.Windows.Forms.Padding]::new(0, 3, 0, 9)
$details.Controls.Add($previewTitle, 0, 0)
$details.SetColumnSpan($previewTitle, 2)

$checker = [System.Drawing.Bitmap]::new(24, 24)
$checkerGraphics = [System.Drawing.Graphics]::FromImage($checker)
try {
    $checkerGraphics.Clear([System.Drawing.Color]::White)
    $checkerBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(224, 224, 224))
    try {
        $checkerGraphics.FillRectangle($checkerBrush, 0, 0, 12, 12)
        $checkerGraphics.FillRectangle($checkerBrush, 12, 12, 12, 12)
    } finally {
        $checkerBrush.Dispose()
    }
} finally {
    $checkerGraphics.Dispose()
}

$preview = [System.Windows.Forms.PictureBox]::new()
$preview.Dock = [System.Windows.Forms.DockStyle]::Fill
$preview.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$preview.BackgroundImage = $checker
$preview.BackgroundImageLayout = [System.Windows.Forms.ImageLayout]::Tile
$preview.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$preview.MinimumSize = [System.Drawing.Size]::new(220, 220)
$preview.Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 14)
$details.Controls.Add($preview, 0, 1)
$details.SetColumnSpan($preview, 2)

$selectionLabel = [System.Windows.Forms.Label]::new()
$selectionLabel.Text = 'Ingen ikon vald'
$selectionLabel.AutoSize = $true
$selectionLabel.Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 12)
$details.Controls.Add($selectionLabel, 0, 2)
$details.SetColumnSpan($selectionLabel, 2)

$sizeLabel = [System.Windows.Forms.Label]::new()
$sizeLabel.Text = 'Storlek:'
$sizeLabel.AutoSize = $true
$sizeLabel.Margin = [System.Windows.Forms.Padding]::new(0, 6, 10, 0)
$details.Controls.Add($sizeLabel, 0, 3)

$sizeCombo = [System.Windows.Forms.ComboBox]::new()
$sizeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$sizeCombo.Dock = [System.Windows.Forms.DockStyle]::Fill
[void] $sizeCombo.Items.AddRange([object[]] @('16 × 16', '24 × 24', '32 × 32', '48 × 48', '64 × 64', '128 × 128', '256 × 256'))
$sizeCombo.SelectedIndex = 4
$details.Controls.Add($sizeCombo, 1, 3)

$formatLabel = [System.Windows.Forms.Label]::new()
$formatLabel.Text = 'Format:'
$formatLabel.AutoSize = $true
$formatLabel.Margin = [System.Windows.Forms.Padding]::new(0, 10, 10, 0)
$details.Controls.Add($formatLabel, 0, 4)

$formatPanel = [System.Windows.Forms.FlowLayoutPanel]::new()
$formatPanel.AutoSize = $true
$formatPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$formatPanel.WrapContents = $false
$formatPanel.Margin = [System.Windows.Forms.Padding]::new(0, 5, 0, 0)
$details.Controls.Add($formatPanel, 1, 4)

$formatCombo = [System.Windows.Forms.ComboBox]::new()
$formatCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$formatCombo.Width = 80
[void] $formatCombo.Items.AddRange([object[]] @('PNG', 'JPG'))
$formatCombo.SelectedIndex = 0
$formatPanel.Controls.Add($formatCombo)

$qualityLabel = [System.Windows.Forms.Label]::new()
$qualityLabel.Text = 'Kvalitet:'
$qualityLabel.AutoSize = $true
$qualityLabel.Margin = [System.Windows.Forms.Padding]::new(12, 5, 4, 0)
$qualityLabel.Enabled = $false
$formatPanel.Controls.Add($qualityLabel)

$qualityInput = [System.Windows.Forms.NumericUpDown]::new()
$qualityInput.Minimum = 1
$qualityInput.Maximum = 100
$qualityInput.Value = 92
$qualityInput.Width = 58
$qualityInput.Enabled = $false
$formatPanel.Controls.Add($qualityInput)

$formatHint = [System.Windows.Forms.Label]::new()
$formatHint.Text = 'PNG bevarar transparens. JPG använder vit bakgrund.'
$formatHint.AutoSize = $true
$formatHint.ForeColor = [System.Drawing.Color]::DimGray
$formatHint.Margin = [System.Windows.Forms.Padding]::new(0, 8, 0, 12)
$details.Controls.Add($formatHint, 0, 5)
$details.SetColumnSpan($formatHint, 2)

$exportSelectedButton = [System.Windows.Forms.Button]::new()
$exportSelectedButton.Text = 'Exportera vald…'
$exportSelectedButton.AutoSize = $true
$exportSelectedButton.Enabled = $false
$exportSelectedButton.Padding = [System.Windows.Forms.Padding]::new(7, 3, 7, 3)
$exportSelectedButton.Margin = [System.Windows.Forms.Padding]::new(0, 0, 5, 0)
$details.Controls.Add($exportSelectedButton, 0, 6)

$exportAllButton = [System.Windows.Forms.Button]::new()
$exportAllButton.Text = 'Exportera alla…'
$exportAllButton.AutoSize = $true
$exportAllButton.Enabled = $false
$exportAllButton.Padding = [System.Windows.Forms.Padding]::new(7, 3, 7, 3)
$exportAllButton.Margin = [System.Windows.Forms.Padding]::new(5, 0, 0, 0)
$details.Controls.Add($exportAllButton, 1, 6)

$tip = [System.Windows.Forms.ToolTip]::new()
$tip.SetToolTip($openButton, 'Öppna fil (Ctrl+O)')
$tip.SetToolTip($exportSelectedButton, 'Exportera markerad ikon (Ctrl+S)')

$statusStrip = [System.Windows.Forms.StatusStrip]::new()
$statusStrip.SizingGrip = $false
$statusStrip.Margin = [System.Windows.Forms.Padding]::new(0, 9, 0, 0)
$statusLabel = [System.Windows.Forms.ToolStripStatusLabel]::new()
$statusLabel.Text = 'Redo'
$statusLabel.Spring = $true
$statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$progress = [System.Windows.Forms.ToolStripProgressBar]::new()
$progress.Visible = $false
$progress.Minimum = 0
$progress.Maximum = 100
[void] $statusStrip.Items.Add($statusLabel)
[void] $statusStrip.Items.Add($progress)
$root.Controls.Add($statusStrip, 0, 2)

$getSelectedIndex = {
    if ($iconList.SelectedItems.Count -eq 0) { return $null }
    return [int] $iconList.SelectedItems[0].Tag
}

$getSelectedSize = {
    return [int] (($sizeCombo.SelectedItem -split '\s')[0])
}

$setBusy = {
    param([bool] $Busy, [string] $Text = 'Redo')
    $form.UseWaitCursor = $Busy
    $openButton.Enabled = -not $Busy
    $exportSelectedButton.Enabled = (-not $Busy -and $iconList.SelectedItems.Count -gt 0)
    $exportAllButton.Enabled = (-not $Busy -and $script:CurrentIconCount -gt 0)
    $statusLabel.Text = $Text
    [System.Windows.Forms.Application]::DoEvents()
}

$disposeLoadedImages = {
    $preview.Image = $null
    $thumbnailList.Images.Clear()
    foreach ($bitmap in @($script:BitmapCache.Values)) {
        if ($null -ne $bitmap) { $bitmap.Dispose() }
    }
    $script:BitmapCache.Clear()
}

$updatePreview = {
    $index = & $getSelectedIndex
    if ($null -eq $index -or [string]::IsNullOrEmpty($script:CurrentFile)) {
        $preview.Image = $null
        $selectionLabel.Text = 'Ingen ikon vald'
        $exportSelectedButton.Enabled = $false
        return
    }

    try {
        $size = & $getSelectedSize
        $bitmap = Get-IconBitmap -Path $script:CurrentFile -Index $index -Size $size -Cache $script:BitmapCache
        $preview.Image = $bitmap
        $selectionLabel.Text = 'Ikon {0} av {1}  •  {2} × {2} px' -f ($index + 1), $script:CurrentIconCount, $size
        $exportSelectedButton.Enabled = $true
        $statusLabel.Text = 'Ikon {0} vald' -f ($index + 1)
    } catch {
        $statusLabel.Text = 'Förhandsvisningen kunde inte skapas'
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Fel vid ikonläsning',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

$loadFile = {
    param([string] $Path)

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

        & $disposeLoadedImages
        $iconList.Items.Clear()
        $emptyLabel.Visible = $false
        $script:CurrentFile = $resolvedPath
        $script:CurrentIconCount = $count
        $fileTextBox.Text = $resolvedPath
        $fileInfoLabel.Text = '{0} ikon{1}' -f $count, $(if ($count -eq 1) { '' } else { 'er' })

        $progress.Visible = $true
        $progress.Maximum = $count
        $progress.Value = 0
        $iconList.BeginUpdate()
        try {
            for ($index = 0; $index -lt $count; $index++) {
                $thumbnail = Get-IconBitmap -Path $resolvedPath -Index $index -Size 64 -Cache $script:BitmapCache
                [void] $thumbnailList.Images.Add(('icon-{0}' -f $index), [System.Drawing.Image] $thumbnail)
                $item = [System.Windows.Forms.ListViewItem]::new(('Ikon {0}' -f ($index + 1)))
                $item.ImageKey = 'icon-{0}' -f $index
                $item.Tag = $index
                [void] $iconList.Items.Add($item)
                $progress.Value = $index + 1
                if ($index % 8 -eq 0) { [System.Windows.Forms.Application]::DoEvents() }
            }
        } finally {
            $iconList.EndUpdate()
            $progress.Visible = $false
        }

        $exportAllButton.Enabled = $true
        $iconList.Items[0].Selected = $true
        $iconList.Items[0].Focused = $true
        [void] $iconList.Focus()
        & $updatePreview
        & $setBusy $false ('{0} ikoner lästa från {1}' -f $count, [System.IO.Path]::GetFileName($resolvedPath))
    } catch {
        & $setBusy $false 'Kunde inte öppna filen'
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Kunde inte öppna filen',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

$chooseFile = {
    $dialog = [System.Windows.Forms.OpenFileDialog]::new()
    try {
        $dialog.Title = 'Välj en fil som innehåller ikoner'
        $dialog.Filter = 'Program och bibliotek (*.exe;*.dll)|*.exe;*.dll|Program (*.exe)|*.exe|Bibliotek (*.dll)|*.dll|Alla filer (*.*)|*.*'
        $dialog.CheckFileExists = $true
        $dialog.Multiselect = $false
        if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            & $loadFile $dialog.FileName
        }
    } finally {
        $dialog.Dispose()
    }
}

$exportSelected = {
    $index = & $getSelectedIndex
    if ($null -eq $index) { return }

    $format = [string] $formatCombo.SelectedItem
    $extension = if ($format -eq 'PNG') { 'png' } else { 'jpg' }
    $size = & $getSelectedSize
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($script:CurrentFile)
    $dialog = [System.Windows.Forms.SaveFileDialog]::new()
    try {
        $dialog.Title = 'Exportera vald ikon'
        $dialog.Filter = if ($format -eq 'PNG') { 'PNG-bild (*.png)|*.png' } else { 'JPEG-bild (*.jpg)|*.jpg' }
        $dialog.DefaultExt = $extension
        $dialog.AddExtension = $true
        $dialog.FileName = '{0}_ikon_{1:D3}_{2}x{2}.{3}' -f $baseName, ($index + 1), $size, $extension
        if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }

        & $setBusy $true 'Exporterar ikon…'
        $bitmap = Get-IconBitmap -Path $script:CurrentFile -Index $index -Size $size -Cache $script:BitmapCache
        Save-IconBitmap -Bitmap $bitmap -Path $dialog.FileName -Format $format -JpegQuality ([int] $qualityInput.Value)
        & $setBusy $false ('Sparad: {0}' -f $dialog.FileName)
    } catch {
        & $setBusy $false 'Exporten misslyckades'
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Exportfel', 'OK', 'Error') | Out-Null
    } finally {
        $dialog.Dispose()
    }
}

$exportAll = {
    if ($script:CurrentIconCount -lt 1) { return }

    $folderDialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    try {
        $folderDialog.Description = 'Välj mapp för de exporterade ikonerna'
        $folderDialog.UseDescriptionForTitle = $true
        if ($folderDialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }

        $format = [string] $formatCombo.SelectedItem
        $extension = if ($format -eq 'PNG') { 'png' } else { 'jpg' }
        $size = & $getSelectedSize
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($script:CurrentFile)
        $progress.Visible = $true
        $progress.Maximum = $script:CurrentIconCount
        $progress.Value = 0
        & $setBusy $true 'Exporterar alla ikoner…'

        for ($index = 0; $index -lt $script:CurrentIconCount; $index++) {
            $name = '{0}_ikon_{1:D3}_{2}x{2}.{3}' -f $baseName, ($index + 1), $size, $extension
            $outputPath = Get-UniquePath -Path (Join-Path $folderDialog.SelectedPath $name)
            $bitmap = Get-IconBitmap -Path $script:CurrentFile -Index $index -Size $size -Cache $script:BitmapCache
            Save-IconBitmap -Bitmap $bitmap -Path $outputPath -Format $format -JpegQuality ([int] $qualityInput.Value)
            $progress.Value = $index + 1
            $statusLabel.Text = 'Exporterar {0} av {1}…' -f ($index + 1), $script:CurrentIconCount
            [System.Windows.Forms.Application]::DoEvents()
        }

        $progress.Visible = $false
        & $setBusy $false ('{0} ikoner exporterades till {1}' -f $script:CurrentIconCount, $folderDialog.SelectedPath)
    } catch {
        $progress.Visible = $false
        & $setBusy $false 'Exporten misslyckades'
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Exportfel', 'OK', 'Error') | Out-Null
    } finally {
        $folderDialog.Dispose()
    }
}

$openButton.Add_Click($chooseFile)
$exportSelectedButton.Add_Click($exportSelected)
$exportAllButton.Add_Click($exportAll)
$iconList.Add_SelectedIndexChanged($updatePreview)
$sizeCombo.Add_SelectedIndexChanged($updatePreview)
$formatCombo.Add_SelectedIndexChanged({
    $isJpeg = $formatCombo.SelectedItem -eq 'JPG'
    $qualityLabel.Enabled = $isJpeg
    $qualityInput.Enabled = $isJpeg
})
$form.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Control -and $eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::O) {
        $eventArgs.SuppressKeyPress = $true
        & $chooseFile
    } elseif ($eventArgs.Control -and $eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::S -and $exportSelectedButton.Enabled) {
        $eventArgs.SuppressKeyPress = $true
        & $exportSelected
    }
})
$form.Add_DragEnter({
    param($sender, $eventArgs)
    if ($eventArgs.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $paths = [string[]] $eventArgs.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
        if ($paths.Count -gt 0 -and [System.IO.Path]::GetExtension($paths[0]).ToLowerInvariant() -in @('.exe', '.dll')) {
            $eventArgs.Effect = [System.Windows.Forms.DragDropEffects]::Copy
        }
    }
})
$form.Add_DragDrop({
    param($sender, $eventArgs)
    $paths = [string[]] $eventArgs.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    if ($paths.Count -gt 0) { & $loadFile $paths[0] }
})
$form.Add_FormClosed({
    & $disposeLoadedImages
    $checker.Dispose()
    $thumbnailList.Dispose()
    $tip.Dispose()
})

if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
    & $loadFile $FilePath
}

$smokeTimer = $null
if ($GuiSmokeTest) {
    $form.ShowInTaskbar = $false
    $form.Opacity = 0
    $smokeTimer = [System.Windows.Forms.Timer]::new()
    $smokeTimer.Interval = 150
    $smokeTimer.Add_Tick({
        $smokeTimer.Stop()
        $form.Close()
    })
    $smokeTimer.Start()
}

[void] $form.ShowDialog()
if ($null -ne $smokeTimer) { $smokeTimer.Dispose() }
$form.Dispose()
