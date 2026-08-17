Set-StrictMode -Version Latest

function Show-LibrarySettingsDialog {
    param(
        [Parameter(Mandatory)] [System.Windows.Window] $Owner,
        [Parameter(Mandatory)] [string] $XamlPath,
        [Parameter(Mandatory)] [string] $CurrentRoot,
        [Parameter(Mandatory)] [string] $LocalRoot,
        [switch] $SmokeTest
    )

    $xamlText = [System.IO.File]::ReadAllText($XamlPath)
    $stringReader = [System.IO.StringReader]::new($xamlText)
    $xmlReader = [System.Xml.XmlReader]::Create($stringReader)
    try {
        $dialog = [System.Windows.Markup.XamlReader]::Load($xmlReader)
    } finally {
        $xmlReader.Dispose()
        $stringReader.Dispose()
    }
    $dialog.Owner = $Owner

    $pathText = $dialog.FindName('LibraryPathText')
    $pathTypeText = $dialog.FindName('PathTypeText')
    $chooseFolderButton = $dialog.FindName('ChooseFolderButton')
    $useLocalButton = $dialog.FindName('UseLocalButton')
    $saveButton = $dialog.FindName('SaveButton')
    $cancelButton = $dialog.FindName('CancelButton')
    $state = [pscustomobject]@{ Path = [System.IO.Path]::GetFullPath($CurrentRoot) }

    $updatePresentation = {
        $pathText.Text = $state.Path
        $isLocal = $state.Path.Equals(
            [System.IO.Path]::GetFullPath($LocalRoot),
            [System.StringComparison]::OrdinalIgnoreCase
        )
        $pathTypeText.Text = if ($isLocal) { 'Lokal standardplats' } else { 'Egen eller delad plats' }
    }

    $chooseFolderButton.Add_Click({
        $folderDialogType = 'Microsoft.Win32.OpenFolderDialog' -as [type]
        if ($null -ne $folderDialogType) {
            $folderDialog = [Microsoft.Win32.OpenFolderDialog]::new()
            $folderDialog.Title = 'Välj plats för ikonbiblioteket'
            $folderDialog.Multiselect = $false
            if ([System.IO.Directory]::Exists($state.Path)) {
                $folderDialog.InitialDirectory = $state.Path
            }
            if ($folderDialog.ShowDialog($dialog) -eq $true) {
                $state.Path = [System.IO.Path]::GetFullPath($folderDialog.FolderName)
                & $updatePresentation
            }
            return
        }

        Add-Type -AssemblyName System.Windows.Forms
        $fallback = [System.Windows.Forms.FolderBrowserDialog]::new()
        try {
            $fallback.Description = 'Välj plats för ikonbiblioteket'
            if ([System.IO.Directory]::Exists($state.Path)) { $fallback.SelectedPath = $state.Path }
            if ($fallback.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $state.Path = [System.IO.Path]::GetFullPath($fallback.SelectedPath)
                & $updatePresentation
            }
        } finally {
            $fallback.Dispose()
        }
    })
    $useLocalButton.Add_Click({
        $state.Path = [System.IO.Path]::GetFullPath($LocalRoot)
        & $updatePresentation
    })
    $cancelButton.Add_Click({ $dialog.DialogResult = $false })
    $saveButton.Add_Click({
        $dialog.Tag = $state.Path
        $dialog.DialogResult = $true
    })

    & $updatePresentation
    if ($SmokeTest) {
        $dialog.ShowInTaskbar = $false
        $dialog.Opacity = 0
        $dialog.Show()
        $dialog.UpdateLayout()
        $dialog.Close()
        return $state.Path
    }
    if ($dialog.ShowDialog() -eq $true) {
        return [string] $dialog.Tag
    }
    return $null
}
