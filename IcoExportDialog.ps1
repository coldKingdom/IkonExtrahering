Set-StrictMode -Version Latest

function Show-IcoSizeDialog {
    param(
        [Parameter(Mandatory)] [System.Windows.Window] $Owner,
        [Parameter(Mandatory)] [string] $XamlPath,
        [switch] $SmokeTest
    )

    $text = [System.IO.File]::ReadAllText($XamlPath)
    $stringReader = [System.IO.StringReader]::new($text)
    $xmlReader = [System.Xml.XmlReader]::Create($stringReader)
    try {
        $dialog = [System.Windows.Markup.XamlReader]::Load($xmlReader)
    } finally {
        $xmlReader.Dispose()
        $stringReader.Dispose()
    }
    $dialog.Owner = $Owner

    $sizeControls = @(
        $dialog.FindName('Size16'),
        $dialog.FindName('Size24'),
        $dialog.FindName('Size32'),
        $dialog.FindName('Size48'),
        $dialog.FindName('Size64'),
        $dialog.FindName('Size128'),
        $dialog.FindName('Size256')
    )
    $validationText = $dialog.FindName('ValidationText')
    $selectAllButton = $dialog.FindName('SelectAllButton')
    $clearButton = $dialog.FindName('ClearButton')
    $continueButton = $dialog.FindName('ContinueButton')
    $cancelButton = $dialog.FindName('CancelButton')

    $selectAllButton.Add_Click({
        foreach ($control in $sizeControls) { $control.IsChecked = $true }
        $validationText.Visibility = [System.Windows.Visibility]::Collapsed
    })
    $clearButton.Add_Click({
        foreach ($control in $sizeControls) { $control.IsChecked = $false }
    })
    $cancelButton.Add_Click({ $dialog.DialogResult = $false })
    $continueButton.Add_Click({
        $sizes = @($sizeControls | Where-Object IsChecked -EQ $true | ForEach-Object { [int] $_.Tag })
        if ($sizes.Count -eq 0) {
            $validationText.Visibility = [System.Windows.Visibility]::Visible
            return
        }
        $dialog.Tag = [int[]] $sizes
        $dialog.DialogResult = $true
    })

    if ($SmokeTest) {
        $dialog.ShowInTaskbar = $false
        $dialog.Opacity = 0
        $dialog.Show()
        $dialog.UpdateLayout()
        $dialog.Close()
        return [int[]] @(16, 24, 32, 48, 64, 128, 256)
    }
    if ($dialog.ShowDialog() -eq $true) {
        return [int[]] $dialog.Tag
    }
    return $null
}
