function Install-NumericEditors {
    $script:numericEditors = @{}
    foreach ($spec in @(
        @('MaxCharactersSettingBox',1,5000,1), @('MaxQueueSettingBox',1,200,1),
        @('HistoryLimitBox',1,1000,1), @('PerUserQueueLimitBox',0,50,1),
        @('MessageAgeBox',0,600,5), @('DuplicateWindowBox',0,120,1),
        @('MaxQueueBox',1,200,1), @('UserCooldownBox',0,120,0.5), @('GlobalCooldownBox',0,30,0.25)
    )) {
        $box = $window.FindName($spec[0]); if (-not $box) { continue }
        $parent = $box.Parent; if ($parent -isnot [Windows.Controls.Panel]) { continue }
        $index = $parent.Children.IndexOf($box)
        $parent.Children.Remove($box)
        $grid = New-Object Windows.Controls.Grid
        $grid.Margin = $box.Margin; $box.Margin = '12,0,0,0'; $box.Width = 82; $box.MinWidth = 64
        $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))
        $col = New-Object Windows.Controls.ColumnDefinition; $col.Width = 'Auto'; $grid.ColumnDefinitions.Add($col)
        $slider = New-Object Windows.Controls.Slider
        $slider.Style = $window.FindResource('VoiceSlider'); $slider.Minimum = $spec[1]; $slider.Maximum = $spec[2]
        $slider.TickFrequency = $spec[3]; $slider.SmallChange = $spec[3]; $slider.LargeChange = $spec[3]*5
        $slider.IsSnapToTickEnabled = $true; $slider.VerticalAlignment = 'Center'
        $slider.ToolTip = if ($spec[1] -eq 0) { '0 = off. Drag to adjust, or enter an exact value.' } else { 'Drag to adjust, or enter an exact value.' }
        $box.ToolTip = $slider.ToolTip
        [Windows.Controls.Grid]::SetColumn($box,1)
        [void]$grid.Children.Add($slider); [void]$grid.Children.Add($box); $parent.Children.Insert($index,$grid)
        $pair = @{ Box=$box; Slider=$slider; Maximum=[double]$spec[2]; Step=[double]$spec[3] }
        $script:numericEditors[$box] = $pair; $script:numericEditors[$slider] = $pair
        $box.Add_TextChanged({ param($sender,$e)
            if ($script:updatingNumericEditor) { return }
            $pair = $script:numericEditors[$sender]; $value = 0.0
            if (-not $pair -or -not [double]::TryParse($sender.Text,[ref]$value) -or [double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt $pair.Slider.Minimum) { return }
            $script:updatingNumericEditor = $true
            try {
                $pair.Slider.Maximum = [Math]::Max($pair.Maximum,$value); $pair.Slider.Value = $value
                if ($sender.Name -in @('MaxQueueBox','MaxQueueSettingBox')) {
                    $other = if ($sender.Name -eq 'MaxQueueBox') { $MaxQueueSettingBox } else { $MaxQueueBox }
                    $other.Text = $sender.Text; $otherPair = $script:numericEditors[$other]
                    if ($otherPair) { $otherPair.Slider.Maximum=[Math]::Max($otherPair.Maximum,$value);$otherPair.Slider.Value=$value }
                }
            } finally { $script:updatingNumericEditor = $false }
        })
        $slider.Add_ValueChanged({ param($sender,$e)
            if ($script:updatingNumericEditor) { return }
            $pair = $script:numericEditors[$sender]
            if ($pair) { $pair.Box.Text = $sender.Value.ToString('0.##') }
        })
    }
}

function Get-ProfanityDefaults {
    $families = Get-Content -LiteralPath (Join-Path $resourceRoot 'assets\profanity-defaults.json') -Raw | ConvertFrom-Json
    foreach ($p in $families.PSObject.Properties) {
        [pscustomobject]@{word=$p.Name;variants=@($p.Value);enabled=$true;match_variants=$true;action='replace';replacement='bleep'}
    }
}

function Get-ProfanityRules {
    foreach ($r in @($script:profanityGrid.ItemsSource)) {
        [pscustomobject]@{word=$r.Word;variants=@($r.Variants);enabled=[bool]$r.Enabled;match_variants=[bool]$r.MatchVariants;action=$r.Action;replacement=$r.Replacement}
    }
}

function Update-ProfanityDisplay {
    $terms = New-Object 'System.Collections.Generic.List[string]'
    foreach ($row in @($script:profanityGrid.ItemsSource)) {
        $row.DisplayWord = if ($script:profanityShow.IsChecked) { $row.Word } else { '****' }
        $row.DisplayReplacement = if ($script:profanityShow.IsChecked) { $row.Replacement } elseif ($row.Replacement) { '****' } else { '-' }
        foreach ($term in @($row.Word) + @($row.Variants) + @($row.Replacement -split ',')) {
            if ($term.Trim()) { $terms.Add([regex]::Escape($term.Trim())) }
        }
    }
    $script:profanityMask = if ($terms.Count) { [regex]::new(('(?<!\w)(?:' + (($terms | Sort-Object -Unique | Sort-Object Length -Descending) -join '|') + ')(?!\w)'),[Text.RegularExpressions.RegexOptions]::IgnoreCase) } else { $null }
    $script:profanityGrid.Items.Refresh()
    $script:playerHistoryRenderedRevision = -1
    $script:lastHistorySignature = ''; $script:lastQueueSignature = ''
    $script:activityLogModified = $null
    if ($QuickHistoryPopup) { $QuickHistoryPopup.IsOpen=$false }
}

function Load-ProfanityRules($settings) {
    if (-not $script:profanityGrid) { return }
    $script:profanityEnabled.IsChecked = [bool]$settings.profanity_enabled
    $script:profanityShow.IsChecked = ($null -ne $settings.profanity_hide_words -and -not [bool]$settings.profanity_hide_words)
    $rules = if ($null -ne $settings.profanity_rules) { @($settings.profanity_rules) } else { @(Get-ProfanityDefaults) }
    $rows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    foreach ($r in $rules) {
        $label = switch ($r.action) { 'block' {'Block message'} 'remove' {'Remove word'} default {'Replace'} }
        $rows.Add([pscustomobject]@{Word=[string]$r.word;Variants=@($r.variants);Enabled=[bool]$r.enabled;MatchVariants=[bool]$r.match_variants;Action=[string]$r.action;Replacement=[string]$r.replacement;DisplayWord='****';DisplayReplacement='****';ActionLabel=$label;FormCount=$(if($r.match_variants){1+@($r.variants).Count}else{1})})
    }
    $script:profanityGrid.ItemsSource = $rows
    Update-ProfanityDisplay
}

function Show-ProfanityDialog($row) {
    $d = Load-Xaml (Join-Path $resourceRoot 'assets\ProfanityDialog.xaml'); $d.Owner=$window; Apply-AppFont $d
    $show = $d.FindName('ShowWords'); $action = $d.FindName('Action'); $forms = $d.FindName('MatchVariants')
    foreach ($name in @('Word','Variants','Replacement')) {
        $value = if ($row) { if($name -eq 'Variants'){$row.Variants -join ', '}else{[string]$row.$name} } elseif($name -eq 'Replacement') { 'bleep' } else { '' }
        $d.FindName($name).Text=$value; $d.FindName($name+'Hidden').Password=$value
    }
    $action.SelectedIndex=0
    if($row){$forms.IsChecked=$row.MatchVariants;foreach($i in $action.Items){if($i.Tag -eq $row.Action){$action.SelectedItem=$i}}}
    $show.Add_Click({
        foreach($name in @('Word','Variants','Replacement')) {
            $plain=$d.FindName($name);$hidden=$d.FindName($name+'Hidden')
            if($show.IsChecked){$plain.Text=$hidden.Password;$plain.Visibility='Visible';$hidden.Visibility='Collapsed'}else{$hidden.Password=$plain.Text;$plain.Visibility='Collapsed';$hidden.Visibility='Visible'}
        }
    })
    $action.Add_SelectionChanged({$enabled=$action.SelectedItem.Tag -eq 'replace';$d.FindName('Replacement').IsEnabled=$enabled;$d.FindName('ReplacementHidden').IsEnabled=$enabled})
    $d.FindName('TitleBar').Add_MouseLeftButtonDown({$d.DragMove()})
    $d.FindName('Close').Add_Click({$d.Close()});$d.FindName('Cancel').Add_Click({$d.Close()})
    $script:profanityDialogResult=$null
    $d.FindName('Save').Add_Click({
        $values=@{};foreach($name in @('Word','Variants','Replacement')){$values[$name]=if($show.IsChecked){$d.FindName($name).Text.Trim()}else{$d.FindName($name+'Hidden').Password.Trim()}}
        if(-not $values.Word){$d.FindName('Error').Text='Enter a word or phrase.';return}
        foreach($existing in @($script:profanityGrid.ItemsSource)){if($existing -ne $row -and $existing.Word -eq $values.Word){$d.FindName('Error').Text='That word already has a rule.';return}}
        $script:profanityDialogResult=[pscustomobject]@{word=$values.Word;variants=@($values.Variants -split ',' | ForEach-Object {$_.Trim()} | Where-Object {$_});enabled=$(if($row){$row.Enabled}else{$true});match_variants=[bool]$forms.IsChecked;action=[string]$action.SelectedItem.Tag;replacement=$values.Replacement}
        $d.DialogResult=$true
    })
    [void]$d.ShowDialog(); return $script:profanityDialogResult
}

function Edit-ProfanityRule([bool]$adding) {
    $row = if($adding){$null}else{$script:profanityGrid.SelectedItem};if(-not $adding -and -not $row){return}
    $result = Show-ProfanityDialog $row; if(-not $result){return}
    $rules = @(Get-ProfanityRules)
    if($row){$rules=@($rules | Where-Object {$_.word -ne $row.Word})}
    $settings=[pscustomobject]@{profanity_rules=@($rules)+@($result);profanity_enabled=$script:profanityEnabled.IsChecked;profanity_hide_words=(-not $script:profanityShow.IsChecked)}
    Load-ProfanityRules $settings
}

function Install-ProfanityEditor {
    $panel = Load-Xaml (Join-Path $resourceRoot 'assets\ProfanityPanel.xaml')
    $script:profanityGrid=$panel.FindName('Words');$script:profanityShow=$panel.FindName('ShowWords');$script:profanityEnabled=$panel.FindName('Enabled')
    foreach($column in $script:profanityGrid.Columns){if($column -is [Windows.Controls.DataGridTextColumn]){$column.ElementStyle=$window.FindResource('GridText')}}
    $window.FindName('RulesStack').Children.Insert(1,$panel)
    $panel.FindName('Add').Add_Click({Edit-ProfanityRule $true})
    $panel.FindName('Edit').Add_Click({Edit-ProfanityRule $false})
    $script:profanityGrid.Add_MouseDoubleClick({Edit-ProfanityRule $false})
    $panel.FindName('Remove').Add_Click({$r=$script:profanityGrid.SelectedItem;if($r){[void]$script:profanityGrid.ItemsSource.Remove($r);Update-ProfanityDisplay}})
    $panel.FindName('All').Add_Click({foreach($r in $script:profanityGrid.ItemsSource){$r.Enabled=$true};$script:profanityGrid.Items.Refresh()})
    $panel.FindName('None').Add_Click({foreach($r in $script:profanityGrid.ItemsSource){$r.Enabled=$false};$script:profanityGrid.Items.Refresh()})
    $panel.FindName('SaveProfanity').Style=$window.FindResource('PrimaryButton')
    $panel.FindName('SaveProfanity').Add_Click({
        try {
            $s=Read-Settings
            Set-JsonProperty $s 'profanity_enabled' ([bool]$script:profanityEnabled.IsChecked)
            Set-JsonProperty $s 'profanity_hide_words' (-not [bool]$script:profanityShow.IsChecked)
            Set-JsonProperty $s 'profanity_rules' @(Get-ProfanityRules)
            Write-Settings $s;Update-ProfanityDisplay
            $BottomStatus.Text='Profanity rules saved'
        } catch {$BottomStatus.Text=$_.Exception.Message}
    })
    $script:profanityShow.Add_Click({Update-ProfanityDisplay;Refresh-ServiceState})
}
