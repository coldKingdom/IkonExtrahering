Set-StrictMode -Version Latest

function Get-WpfImageSourceFromFile {
    param([Parameter(Mandatory)] [string] $Path)

    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    try {
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

function Show-IconLibraryWindow {
    param(
        [Parameter(Mandatory)] [System.Windows.Window] $Owner,
        [Parameter(Mandatory)] [string] $XamlPath,
        [Parameter(Mandatory)] [string] $IcoDialogXamlPath,
        [string] $RootPath,
        [switch] $SmokeTest,
        [string] $ScreenshotPath
    )

    $xamlText = [System.IO.File]::ReadAllText($XamlPath)
    $stringReader = [System.IO.StringReader]::new($xamlText)
    $xmlReader = [System.Xml.XmlReader]::Create($stringReader)
    try {
        $libraryWindow = [System.Windows.Markup.XamlReader]::Load($xmlReader)
    } finally {
        $xmlReader.Dispose()
        $stringReader.Dispose()
    }
    $libraryWindow.Owner = $Owner

    $libraryCountText = $libraryWindow.FindName('LibraryCountText')
    $libraryPathText = $libraryWindow.FindName('LibraryPathText')
    $libraryList = $libraryWindow.FindName('LibraryList')
    $librarySearchBox = $libraryWindow.FindName('LibrarySearchBox')
    $searchPlaceholder = $libraryWindow.FindName('SearchPlaceholder')
    $clearSearchButton = $libraryWindow.FindName('ClearSearchButton')
    $allFilter = $libraryWindow.FindName('AllFilter')
    $favoritesFilter = $libraryWindow.FindName('FavoritesFilter')
    $libraryEmptyState = $libraryWindow.FindName('LibraryEmptyState')
    $libraryNoResultsState = $libraryWindow.FindName('LibraryNoResultsState')
    $libraryPreview = $libraryWindow.FindName('LibraryPreview')
    $libraryNameText = $libraryWindow.FindName('LibraryNameText')
    $libraryMetaText = $libraryWindow.FindName('LibraryMetaText')
    $librarySourceText = $libraryWindow.FindName('LibrarySourceText')
    $favoriteButton = $libraryWindow.FindName('FavoriteButton')
    $tagItemsControl = $libraryWindow.FindName('TagItemsControl')
    $tagInput = $libraryWindow.FindName('TagInput')
    $tagPlaceholder = $libraryWindow.FindName('TagPlaceholder')
    $addTagButton = $libraryWindow.FindName('AddTagButton')
    $importLibraryButton = $libraryWindow.FindName('ImportLibraryButton')
    $exportLibraryButton = $libraryWindow.FindName('ExportLibraryButton')
    $exportLibraryIconButton = $libraryWindow.FindName('ExportLibraryIconButton')
    $exportLibraryIcoButton = $libraryWindow.FindName('ExportLibraryIcoButton')
    $deleteLibraryIconButton = $libraryWindow.FindName('DeleteLibraryIconButton')
    $closeLibraryButton = $libraryWindow.FindName('CloseLibraryButton')
    $libraryStatusText = $libraryWindow.FindName('LibraryStatusText')
    $libraryResultsText = $libraryWindow.FindName('LibraryResultsText')

    $paths = Initialize-IconLibrary -RootPath $RootPath
    $libraryPathText.Text = $paths.Root
    $syncState = [pscustomobject]@{ LastCatalogStamp = '' }
    $getCatalogStamp = {
        if (-not [System.IO.File]::Exists($paths.Database)) { return 'missing' }
        $fileInfo = [System.IO.FileInfo]::new($paths.Database)
        return '{0}:{1}' -f $fileInfo.LastWriteTimeUtc.Ticks, $fileInfo.Length
    }
    $collection = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    $libraryView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($collection)
    $libraryList.ItemsSource = $libraryView
    $tagCollection = [System.Collections.ObjectModel.ObservableCollection[string]]::new()
    $tagItemsControl.ItemsSource = $tagCollection
    $filterState = [pscustomobject]@{ SearchText = ''; FavoritesOnly = $false }

    $libraryView.Filter = [System.Predicate[object]] {
        param($item)
        return Test-IconLibraryItemMatch -Item $item -SearchText $filterState.SearchText -FavoritesOnly $filterState.FavoritesOnly
    }

    $showLibraryError = {
        param([string] $Title, [string] $Message)
        [void] [System.Windows.MessageBox]::Show(
            $libraryWindow,
            $Message,
            $Title,
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        )
    }

    $updateFilterPresentation = {
        $visibleCount = 0
        foreach ($visibleItem in $libraryView) { $visibleCount++ }
        $libraryResultsText.Text = '{0} av {1}' -f $visibleCount, $collection.Count
        $libraryEmptyState.Visibility = if ($collection.Count -eq 0) {
            [System.Windows.Visibility]::Visible
        } else {
            [System.Windows.Visibility]::Collapsed
        }
        $libraryNoResultsState.Visibility = if ($collection.Count -gt 0 -and $visibleCount -eq 0) {
            [System.Windows.Visibility]::Visible
        } else {
            [System.Windows.Visibility]::Collapsed
        }
    }

    $updateLibraryPreview = {
        $selected = $libraryList.SelectedItem
        if ($null -eq $selected) {
            $libraryPreview.Source = $null
            $libraryNameText.Text = 'Ingen ikon vald'
            $libraryMetaText.Text = 'Välj en ikon i biblioteket'
            $librarySourceText.Text = ''
            $exportLibraryIconButton.IsEnabled = $false
            $exportLibraryIcoButton.IsEnabled = $false
            $deleteLibraryIconButton.IsEnabled = $false
            $favoriteButton.IsEnabled = $false
            $favoriteButton.Content = '☆'
            $tagInput.IsEnabled = $false
            $addTagButton.IsEnabled = $false
            $tagCollection.Clear()
            return
        }

        $libraryPreview.Source = $selected.Image
        $libraryNameText.Text = $selected.Name
        $libraryMetaText.Text = '{0} × {1} px  •  Sparad {2}' -f $selected.Width, $selected.Height, $selected.AddedDisplay
        $librarySourceText.Text = if ([string]::IsNullOrWhiteSpace($selected.SourceFileName)) {
            'Källa saknas'
        } elseif ($selected.SourceIndex -ge 0) {
            'Källa: {0}, ikon {1}' -f $selected.SourceFileName, ($selected.SourceIndex + 1)
        } else {
            'Källa: {0}' -f $selected.SourceFileName
        }
        $exportLibraryIconButton.IsEnabled = $true
        $exportLibraryIcoButton.IsEnabled = $true
        $deleteLibraryIconButton.IsEnabled = $true
        $favoriteButton.IsEnabled = $true
        $favoriteButton.Content = if ($selected.Favorite) { '★' } else { '☆' }
        $favoriteButton.ToolTip = if ($selected.Favorite) { 'Ta bort från favoriter' } else { 'Markera som favorit' }
        $tagInput.IsEnabled = @($selected.Tags).Count -lt 20
        $addTagButton.IsEnabled = $tagInput.IsEnabled
        $tagCollection.Clear()
        foreach ($tag in @($selected.Tags)) { $tagCollection.Add([string] $tag) }
    }

    $refreshLibrary = {
        $selectedId = if ($null -ne $libraryList.SelectedItem) {
            [string] $libraryList.SelectedItem.Id
        } else { '' }
        $collection.Clear()
        $catalog = Read-IconLibraryCatalog -RootPath $RootPath
        foreach ($item in @($catalog.Items | Sort-Object AddedUtc -Descending)) {
            $imagePath = Get-IconLibraryImagePath -Item $item -RootPath $RootPath
            if (-not [System.IO.File]::Exists($imagePath)) { continue }
            try {
                $added = [DateTime]::Parse(
                    [string] $item.AddedUtc,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind
                ).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
            } catch {
                $added = 'okänt datum'
            }
            $viewItem = [pscustomobject]@{
                Id = [string] $item.Id
                Name = [string] $item.Name
                SourceFileName = [string] $item.SourceFileName
                SourceIndex = [int] $item.SourceIndex
                AddedDisplay = $added
                Width = [int] $item.Width
                Height = [int] $item.Height
                ImagePath = $imagePath
                Image = Get-WpfImageSourceFromFile -Path $imagePath
                Tags = [string[]] @($item.Tags)
                Favorite = [bool] $item.Favorite
                FavoriteGlyph = if ($item.Favorite) { '★' } else { '' }
            }
            $collection.Add($viewItem)
        }
        $libraryView.Refresh()
        $libraryCountText.Text = [string] $collection.Count
        $exportLibraryButton.IsEnabled = $collection.Count -gt 0

        if (-not [string]::IsNullOrEmpty($selectedId)) {
            $candidate = @($collection | Where-Object Id -EQ $selectedId | Select-Object -First 1)
            if ($candidate.Count -gt 0 -and $libraryView.Contains($candidate[0])) {
                $libraryList.SelectedItem = $candidate[0]
            }
        }
        if ($null -eq $libraryList.SelectedItem) {
            foreach ($firstVisible in $libraryView) {
                $libraryList.SelectedItem = $firstVisible
                break
            }
        }
        & $updateFilterPresentation
        & $updateLibraryPreview
        $syncState.LastCatalogStamp = & $getCatalogStamp
    }

    $libraryList.Add_SelectionChanged($updateLibraryPreview)
    $closeLibraryButton.Add_Click({ $libraryWindow.Close() })

    $refreshFilter = {
        $filterState.SearchText = $librarySearchBox.Text.Trim()
        $filterState.FavoritesOnly = $favoritesFilter.IsChecked -eq $true
        $searchPlaceholder.Visibility = if ([string]::IsNullOrEmpty($librarySearchBox.Text)) {
            [System.Windows.Visibility]::Visible
        } else {
            [System.Windows.Visibility]::Collapsed
        }
        $clearSearchButton.Visibility = if ([string]::IsNullOrEmpty($librarySearchBox.Text)) {
            [System.Windows.Visibility]::Collapsed
        } else {
            [System.Windows.Visibility]::Visible
        }
        $libraryView.Refresh()
        if ($null -ne $libraryList.SelectedItem -and -not $libraryView.Contains($libraryList.SelectedItem)) {
            $libraryList.SelectedItem = $null
        }
        if ($null -eq $libraryList.SelectedItem) {
            foreach ($firstVisible in $libraryView) {
                $libraryList.SelectedItem = $firstVisible
                break
            }
        }
        & $updateFilterPresentation
        & $updateLibraryPreview
    }

    $librarySearchBox.Add_TextChanged($refreshFilter)
    $clearSearchButton.Add_Click({ $librarySearchBox.Clear(); $librarySearchBox.Focus() })
    $allFilter.Add_Checked($refreshFilter)
    $favoritesFilter.Add_Checked($refreshFilter)

    $saveTags = {
        param([string[]] $Tags, [string] $SuccessMessage)
        $selected = $libraryList.SelectedItem
        if ($null -eq $selected) { return }
        try {
            [void] (Update-IconLibraryItemMetadata -Id $selected.Id -Tags $Tags -RootPath $RootPath)
            & $refreshLibrary
            $libraryStatusText.Text = $SuccessMessage
        } catch {
            & $showLibraryError 'Kunde inte uppdatera taggarna' $_.Exception.Message
        }
    }

    $addTag = {
        $selected = $libraryList.SelectedItem
        $tag = $tagInput.Text.Trim()
        if ($null -eq $selected -or [string]::IsNullOrWhiteSpace($tag)) { return }
        if (@($selected.Tags).Count -ge 20) {
            $libraryStatusText.Text = 'En ikon kan ha högst 20 taggar'
            return
        }
        $normalized = [string[]] (Normalize-IconTags -Tags (@($selected.Tags) + $tag))
        if ($normalized.Count -eq @($selected.Tags).Count) {
            $libraryStatusText.Text = 'Taggen finns redan'
            $tagInput.Clear()
            return
        }
        $tagInput.Clear()
        & $saveTags $normalized ("Taggen '$tag' lades till")
    }

    $addTagButton.Add_Click($addTag)
    $tagInput.Add_KeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter) {
            $eventArgs.Handled = $true
            & $addTag
        }
    })
    $tagInput.Add_TextChanged({
        $tagPlaceholder.Visibility = if ([string]::IsNullOrEmpty($tagInput.Text)) {
            [System.Windows.Visibility]::Visible
        } else {
            [System.Windows.Visibility]::Collapsed
        }
    })
    $tagItemsControl.AddHandler(
        [System.Windows.Controls.Button]::ClickEvent,
        [System.Windows.RoutedEventHandler] {
            param($sender, $eventArgs)
            $button = $eventArgs.Source -as [System.Windows.Controls.Button]
            if ($null -eq $button -or $null -eq $button.Tag -or $null -eq $libraryList.SelectedItem) { return }
            $removedTag = [string] $button.Tag
            $remaining = [string[]] @($libraryList.SelectedItem.Tags | Where-Object {
                -not ([string] $_).Equals($removedTag, [System.StringComparison]::CurrentCultureIgnoreCase)
            })
            $eventArgs.Handled = $true
            & $saveTags $remaining ("Taggen '$removedTag' togs bort")
        }
    )

    $favoriteButton.Add_Click({
        $selected = $libraryList.SelectedItem
        if ($null -eq $selected) { return }
        $newValue = -not [bool] $selected.Favorite
        try {
            [void] (Update-IconLibraryItemMetadata -Id $selected.Id -Favorite $newValue -RootPath $RootPath)
            & $refreshLibrary
            $libraryStatusText.Text = if ($newValue) {
                'Ikonen lades till i favoriter'
            } else {
                'Ikonen togs bort från favoriter'
            }
        } catch {
            & $showLibraryError 'Kunde inte uppdatera favoriten' $_.Exception.Message
        }
    })

    $exportLibraryIconButton.Add_Click({
        $selected = $libraryList.SelectedItem
        if ($null -eq $selected) { return }
        $dialog = [Microsoft.Win32.SaveFileDialog]::new()
        $dialog.Title = 'Exportera sparad ikon'
        $dialog.Filter = 'PNG-bild (*.png)|*.png'
        $dialog.DefaultExt = 'png'
        $dialog.AddExtension = $true
        $dialog.OverwritePrompt = $true
        $safeName = ($selected.Name -replace '[\\/:*?"<>|]', '_').Trim()
        if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = 'ikon' }
        $dialog.FileName = "$safeName.png"
        if ($dialog.ShowDialog($libraryWindow) -eq $true) {
            try {
                [System.IO.File]::Copy($selected.ImagePath, $dialog.FileName, $true)
                $libraryStatusText.Text = 'Ikonen exporterades till {0}' -f $dialog.FileName
            } catch {
                & $showLibraryError 'Exportfel' $_.Exception.Message
            }
        }
    })

    $exportLibraryIcoButton.Add_Click({
        $selected = $libraryList.SelectedItem
        if ($null -eq $selected) { return }
        $sizes = @(Show-IcoSizeDialog -Owner $libraryWindow -XamlPath $IcoDialogXamlPath)
        if ($sizes.Count -eq 0) { return }
        $dialog = [Microsoft.Win32.SaveFileDialog]::new()
        $dialog.Title = 'Exportera sparad ikon som ICO'
        $dialog.Filter = 'Windows-ikon (*.ico)|*.ico'
        $dialog.DefaultExt = 'ico'
        $dialog.AddExtension = $true
        $dialog.OverwritePrompt = $true
        $safeName = ($selected.Name -replace '[\\/:*?"<>|]', '_').Trim()
        if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = 'ikon' }
        $dialog.FileName = "$safeName.ico"
        if ($dialog.ShowDialog($libraryWindow) -eq $true) {
            try {
                Save-PngIconAsIco -SourcePath $selected.ImagePath -Sizes $sizes -DestinationPath $dialog.FileName
                $libraryStatusText.Text = 'ICO-filen exporterades till {0}' -f $dialog.FileName
            } catch {
                & $showLibraryError 'ICO-exportfel' $_.Exception.Message
            }
        }
    })

    $deleteLibraryIconButton.Add_Click({
        $selected = $libraryList.SelectedItem
        if ($null -eq $selected) { return }
        $answer = [System.Windows.MessageBox]::Show(
            $libraryWindow,
            "Vill du ta bort '$($selected.Name)' från det lokala biblioteket?",
            'Ta bort sparad ikon',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($answer -eq [System.Windows.MessageBoxResult]::Yes) {
            try {
                [void] (Remove-IconLibraryItem -Id $selected.Id -RootPath $RootPath)
                & $refreshLibrary
                $libraryStatusText.Text = 'Ikonen togs bort från biblioteket'
            } catch {
                & $showLibraryError 'Kunde inte ta bort ikonen' $_.Exception.Message
            }
        }
    })

    $exportLibraryButton.Add_Click({
        $dialog = [Microsoft.Win32.SaveFileDialog]::new()
        $dialog.Title = 'Exportera ikonbibliotek'
        $dialog.Filter = 'Ikonbibliotek (*.ikonbibliotek)|*.ikonbibliotek'
        $dialog.DefaultExt = 'ikonbibliotek'
        $dialog.AddExtension = $true
        $dialog.OverwritePrompt = $true
        $dialog.FileName = 'Ikonbibliotek_{0}.ikonbibliotek' -f [DateTime]::Now.ToString('yyyy-MM-dd')
        if ($dialog.ShowDialog($libraryWindow) -eq $true) {
            try {
                $count = Export-IconLibraryArchive -DestinationPath $dialog.FileName -RootPath $RootPath
                $libraryStatusText.Text = '{0} ikoner exporterades till ett portabelt bibliotek' -f $count
            } catch {
                & $showLibraryError 'Kunde inte exportera biblioteket' $_.Exception.Message
            }
        }
    })

    $importLibraryButton.Add_Click({
        $dialog = [Microsoft.Win32.OpenFileDialog]::new()
        $dialog.Title = 'Importera ikonbibliotek'
        $dialog.Filter = 'Ikonbibliotek (*.ikonbibliotek)|*.ikonbibliotek|ZIP-arkiv (*.zip)|*.zip'
        $dialog.CheckFileExists = $true
        $dialog.Multiselect = $false
        if ($dialog.ShowDialog($libraryWindow) -eq $true) {
            try {
                $result = Import-IconLibraryArchive -ArchivePath $dialog.FileName -RootPath $RootPath
                & $refreshLibrary
                $libraryStatusText.Text = '{0} importerade, {1} dubbletter, {2} metadatauppdateringar' -f $result.Imported, $result.Skipped, $result.Merged
            } catch {
                & $showLibraryError 'Kunde inte importera biblioteket' $_.Exception.Message
            }
        }
    })

    $syncTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $syncTimer.Interval = [TimeSpan]::FromSeconds(2)
    $syncTimer.Add_Tick({
        try {
            $currentStamp = & $getCatalogStamp
            if ($currentStamp -ne $syncState.LastCatalogStamp) {
                & $refreshLibrary
                $libraryStatusText.Text = 'Ändringar från det delade biblioteket synkroniserades'
            }
        } catch [System.TimeoutException] {
            $libraryStatusText.Text = 'Väntar på att en annan användare ska bli klar…'
        } catch {
            $libraryStatusText.Text = 'Det delade biblioteket kunde inte uppdateras'
        }
    })

    $libraryWindow.Add_Closed({
        $syncTimer.Stop()
        $libraryPreview.Source = $null
        $tagCollection.Clear()
        $collection.Clear()
    })

    & $refreshLibrary
    $syncTimer.Start()
    if (-not [string]::IsNullOrWhiteSpace($ScreenshotPath)) {
        $resolvedScreenshotPath = [System.IO.Path]::GetFullPath($ScreenshotPath)
        $screenshotDirectory = [System.IO.Path]::GetDirectoryName($resolvedScreenshotPath)
        if (-not [System.IO.Directory]::Exists($screenshotDirectory)) {
            [void] [System.IO.Directory]::CreateDirectory($screenshotDirectory)
        }
        $libraryWindow.ShowInTaskbar = $false
        $libraryWindow.Left = -20000
        $libraryWindow.Top = -20000
        $libraryWindow.Show()
        $libraryWindow.UpdateLayout()
        $renderElement = [System.Windows.FrameworkElement] $libraryWindow.Content
        $renderTarget = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
            [Math]::Max(1, [int] [Math]::Ceiling($renderElement.ActualWidth)),
            [Math]::Max(1, [int] [Math]::Ceiling($renderElement.ActualHeight)),
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
        $libraryWindow.Close()
        return
    }
    if ($SmokeTest) {
        $libraryWindow.ShowInTaskbar = $false
        $libraryWindow.Opacity = 0
        $libraryWindow.Show()
        $libraryWindow.UpdateLayout()
        $libraryWindow.Close()
        return
    }
    [void] $libraryWindow.ShowDialog()
}
