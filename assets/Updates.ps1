function Start-YapLoqUpdateRequest([string]$command='status'){
    if($script:updateFetchTask){
        if($command -ne 'status'){$script:updatePendingRequest=$command}
        return
    }
    if($command -ne 'status'){$script:updateRequestError=$null}
    $script:updateRequestCommand=$command
    $script:updateFetchClient=[Net.WebClient]::new()
    $script:updateFetchClient.Headers['X-YapLoq-Update-Token']=$env:YAPLOQ_UPDATE_TOKEN
    $base=Get-BridgeBaseUri
    if($command -eq 'status'){
        $script:updateFetchTask=$script:updateFetchClient.DownloadStringTaskAsync([uri]($base+'/api/updates'))
    }else{
        $script:updateFetchClient.Headers['Content-Type']='application/json'
        $payload=if($command -eq 'apply'){@{desktopPid=$PID}|ConvertTo-Json -Compress}else{'{}'}
        $script:updateFetchTask=$script:updateFetchClient.UploadStringTaskAsync([uri]($base+'/api/updates/'+$command),'POST',$payload)
    }
}

function Start-UpdateCheck([bool]$showResult){
    if($showResult){Show-YapLoqUpdates}
    $script:updateMonitoring=$true
    Start-YapLoqUpdateRequest 'check'
}

function Update-YapLoqUpdateWindow{
    $info=$script:updateInfo
    if(-not $info){return}
    $button=$window.FindName('TitleUpdateButton');$dot=$window.FindName('TitleUpdateDot')
    $window.FindName('AppVersionLabel').Text=$info.currentVersion+$(if($info.channel -eq 'preview'){' Preview'}else{''})
    $notice=[bool]$info.available
    $button.Foreground=if($notice){[Windows.Media.BrushConverter]::new().ConvertFromString('#87C9AF')}else{$window.FindResource('Muted')}
    $dot.Visibility='Collapsed'
    $button.ToolTip=if($script:updateWhenIdle){'Update waiting for speech to finish'}elseif($info.state -eq 'ready'){'Restart to finish updating'}elseif($info.available){'Update available: '+$info.version}else{'Check for updates'}
    if(-not $script:updateDialog){return}
    $d=$script:updateDialog
    $title=switch($info.state){'checking'{'Checking for updates...'} 'available'{'An update is available'} 'downloading'{'Downloading update'} 'ready'{'Ready to update'} 'current'{if($info.version){'You are up to date'}else{'YapLoq updates'}} 'error'{'Could not update YapLoq'} default{'YapLoq updates'}}
    $d.FindName('UpdateHeading').Text=$title
    $versions='Installed '+$info.currentVersion+'  |  '+$info.channel+' channel'
    if($info.version){$versions+='  '+[char]0x2192+'  '+$info.version}
    $d.FindName('UpdateVersions').Text=$versions
    $d.FindName('UpdateMessage').Text=if($script:updateRequestError){$script:updateRequestError}elseif($script:updateWhenIdle){'Waiting for the current speech and queue to finish. New speech will delay the update.'}else{[string]$info.message}
    $hasNotes=-not [string]::IsNullOrWhiteSpace([string]$info.notes)
    $d.FindName('UpdateNotesCard').Visibility=if($hasNotes){'Visible'}else{'Collapsed'}
    if($hasNotes){$d.FindName('UpdateNotes').Text=([string]$info.notes -replace '(?m)^#{1,6}\s+','')}
    $d.FindName('UpdateSafetyNote').Visibility=if($info.available -or $info.state -in @('downloading','ready')){'Visible'}else{'Collapsed'}
    $d.Height=if($hasNotes){470}else{330}
    $progress=$d.FindName('UpdateProgress');$progress.Visibility=if($info.state -in @('checking','downloading')){'Visible'}else{'Collapsed'}
    $progress.IsIndeterminate=$info.state -eq 'checking';$progress.Value=[double]$info.progress
    $primary=$d.FindName('UpdatePrimary');$primary.Visibility='Visible';$primary.IsEnabled=$true
    $primary.Content=switch($info.state){'available'{'Download update'} 'downloading'{'Cancel download'} 'ready'{if($script:updateWhenIdle){'Cancel scheduled update'}else{'Restart & update'}} 'error'{'Try again'} default{'Check for updates'}}
    if($info.state -in @('checking','applying')){$primary.IsEnabled=$false}
    if($info.state -eq 'available' -and -not $info.compatible){$primary.IsEnabled=$false}
    $d.FindName('UpdateSavePackage').Visibility=if($info.state -eq 'ready' -and $info.packagePath){'Visible'}else{'Collapsed'}
}

function Invoke-YapLoqUpdatePrimary{
    switch($script:updateInfo.state){
        'available'{Start-YapLoqUpdateRequest 'download'}
        'downloading'{Start-YapLoqUpdateRequest 'cancel'}
        'ready'{
            if($script:updateWhenIdle){$script:updateWhenIdle=$false;Update-YapLoqUpdateWindow;return}
            $state=$script:lastPlaybackState
            if($state.current -or $state.queueLength){
                $answer=[Windows.MessageBox]::Show($script:updateDialog,'Speech is active. Schedule the update for when the current speech and waiting queue have finished? You can cancel it at any time.','Update after speech finishes','YesNo','Question')
                if($answer -eq 'Yes'){$script:updateWhenIdle=$true;Update-YapLoqUpdateWindow}
            }else{Start-YapLoqUpdateRequest 'apply'}
        }
        default{Start-YapLoqUpdateRequest 'check'}
    }
}

function Show-YapLoqUpdates{
    if($script:updateDialog){$script:updateDialog.Activate();return}
    $d=Load-Xaml (Join-Path $resourceRoot 'assets\Updates.xaml')
    $d.Owner=$window;$d.Resources.MergedDictionaries.Add($window.Resources);Apply-AppFont $d
    foreach($name in @('UpdateClose','UpdateSavePackage')){$d.FindName($name).Style=$window.FindResource([Windows.Controls.Button])}
    $d.FindName('UpdatePrimary').Style=$window.FindResource('PrimaryButton')
    $d.Icon=$window.Icon
    $brandPath=Join-Path $resourceRoot 'assets\YapLoq-logo.png'
    if(Test-Path -LiteralPath $brandPath){$brand=[Windows.Media.Imaging.BitmapImage]::new();$brand.BeginInit();$brand.CacheOption='OnLoad';$brand.UriSource=[Uri]::new($brandPath);$brand.EndInit();$brand.Freeze();$d.FindName('UpdateBrandLogo').Source=$brand}
    $script:updateDialog=$d;$script:updateMonitoring=$true
    $d.FindName('UpdateTitleDragRegion').Add_MouseLeftButtonDown({$d.DragMove()})
    $d.FindName('UpdateClose').Add_Click({$d.Close()})
    $d.FindName('UpdatePrimary').Add_Click({Invoke-YapLoqUpdatePrimary})
    $d.FindName('UpdateSavePackage').Add_Click({
        $picker=[Microsoft.Win32.SaveFileDialog]::new();$picker.Filter='YapLoq update package (*.zip)|*.zip';$picker.FileName='YapLoq-update.zip'
        if($picker.ShowDialog($script:updateDialog)){try{Copy-Item -LiteralPath $script:updateInfo.packagePath -Destination $picker.FileName -Force}catch{$script:updateDialog.FindName('UpdateMessage').Text='Could not save the package. Choose a writable location.'}}
    })
    $d.Add_Closed({$script:updateDialog=$null})
    $d.Add_KeyDown({param($sender,$e)if($e.Key -eq 'Escape'){$sender.Close()}})
    Update-YapLoqUpdateWindow
    if(-not $script:updateInfo -or $script:updateInfo.state -eq 'idle'){Start-YapLoqUpdateRequest 'check'}
    $d.Show()
}

function Install-YapLoqUpdates{
    $window.FindName('TitleUpdateButton').Add_Click({Show-YapLoqUpdates})
    $CheckUpdatesButton.Content='Open updates';$CheckUpdatesButton.Add_Click({Show-YapLoqUpdates})
    $script:updateMonitoring=$true
    $script:updatePollTimer=[Windows.Threading.DispatcherTimer]::new();$script:updatePollTimer.Interval=[TimeSpan]::FromMilliseconds(700)
    $script:updatePollTimer.Add_Tick({
        if($script:updateFetchTask){
            if(-not $script:updateFetchTask.IsCompleted){return}
            try{
                $response=$script:updateFetchTask.GetAwaiter().GetResult()|ConvertFrom-Json
                if($script:updateRequestCommand -eq 'apply' -and $response.result.close){
                    $script:updatePollTimer.Stop();if($script:updateDialog){$script:updateDialog.Close()}
                    $script:allowClose=$true;$window.Close();return
                }
                $script:updateInfo=$response.result
                Update-YapLoqUpdateWindow
                $script:updateMonitoring=$script:updateInfo.state -in @('checking','downloading')
            }catch{
                $message='Could not complete the update request. Check your connection and try again.'
                try{$errorResponse=$_.Exception.GetBaseException().Response;if($errorResponse){$reader=[IO.StreamReader]::new($errorResponse.GetResponseStream());try{$message=($reader.ReadToEnd()|ConvertFrom-Json).error}finally{$reader.Dispose()}}}catch{}
                $script:updateRequestError=$message
                if($script:updateDialog){$script:updateDialog.FindName('UpdateMessage').Text=$message}
                if($script:updateRequestCommand -eq 'apply'){$script:updateWhenIdle=$false}
                $script:updateMonitoring=$false
            }finally{$script:updateFetchClient.Dispose();$script:updateFetchTask=$null}
        }
        if($script:updatePendingRequest){$pending=$script:updatePendingRequest;$script:updatePendingRequest=$null;Start-YapLoqUpdateRequest $pending;return}
        if($script:updateWhenIdle -and -not $script:lastPlaybackState.current -and -not $script:lastPlaybackState.queueLength){Start-YapLoqUpdateRequest 'apply';return}
        if($script:updateMonitoring){Start-YapLoqUpdateRequest 'status'}
    })
    $script:updatePollTimer.Start()
    $window.Add_Closed({$script:updatePollTimer.Stop();if($script:updateFetchClient){$script:updateFetchClient.Dispose()}})
}
