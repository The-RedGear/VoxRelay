param([Parameter(Mandatory=$true)][string]$Plan,[switch]$NoDialog)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
$planPath=[IO.Path]::GetFullPath($Plan)
$jobFolder=Split-Path -Parent $planPath
$config=Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
$install=[IO.Path]::GetFullPath($config.install).TrimEnd('\')
$backup=[IO.Path]::GetFullPath($config.backup)
$stage=[IO.Path]::GetFullPath($config.stage)
$data=[IO.Path]::GetFullPath($config.data)
$outcome=Join-Path $data 'updates\outcome.json'
$changed=[Collections.Generic.List[object]]::new()
$launched=$null
$dataSaved=$false
function Child-Path($root,$relative){
    if([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)|:'){throw 'Unsafe update path'}
    $resolved=[IO.Path]::GetFullPath((Join-Path $root $relative))
    if(-not $resolved.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Update path escaped its folder'}
    $cursor=$resolved
    while($cursor -and $cursor.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){
        if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Linked paths are not supported during updates'}
        if($cursor -eq $root){break};$cursor=Split-Path -Parent $cursor
    }
    return $resolved
}
function Write-Outcome($state,$message){
    @{state=$state;message=$message;version=$config.version;time=[datetime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $outcome -Encoding UTF8
}
function File-Sha256($path){
    $stream=[IO.File]::OpenRead($path);$algorithm=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}
    finally{$stream.Dispose();$algorithm.Dispose()}
}
function Start-UpdatedApp {
    # ProcessStartInfo treats brackets in portable install paths literally.
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$exe;$start.WorkingDirectory=$install
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    return [Diagnostics.Process]::Start($start)
}
function Stop-NewApp {
    if(-not $launched){return}
    $descendants=@([int]$launched.Id)
    $processes=@(Get-CimInstance Win32_Process)
    do{
        $next=@($processes|Where-Object{$_.ParentProcessId -in $descendants -and $_.ProcessId -notin $descendants})
        $descendants+=@($next.ProcessId)
    }while($next.Count)
    foreach($process in @($processes|Where-Object{$_.ProcessId -in $descendants}|Sort-Object ProcessId -Descending)){
        # Only the process tree started by this helper can be stopped.
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 600
}
try{
    if($config.executable -notin @('YapLoq.exe','YapLoq-preview.exe')){throw 'Unknown application executable'}
    if($stage -ne (Join-Path $jobFolder 'stage') -or $backup -ne (Join-Path $jobFolder 'rollback')){throw 'Unexpected update staging location'}
    $exe=Child-Path $install $config.executable
    if(-not(Test-Path -LiteralPath $exe)){throw 'Existing installation was not found'}
    $deadline=[datetime]::UtcNow.AddSeconds(100)
    foreach($processId in @($config.processes|Where-Object{$_ -gt 0}|Select-Object -Unique)){
        while(Get-Process -Id $processId -ErrorAction SilentlyContinue){
            if([datetime]::UtcNow -gt $deadline){throw 'YapLoq is still running. Close it from the tray and try again.'}
            Start-Sleep -Milliseconds 250
        }
    }
    [void][IO.Directory]::CreateDirectory($backup)
    # Preserve the exact pre-migration data, in addition to the normal settings backup.
    $dataBackup=Join-Path $backup 'user-data'
    [void][IO.Directory]::CreateDirectory($dataBackup)
    foreach($name in @('settings.json','settings.json.bak','history.json','queue.json')){
        $original=Join-Path $data $name
        if(Test-Path -LiteralPath $original){Copy-Item -LiteralPath $original -Destination (Join-Path $dataBackup $name)}
    }
    $dataSaved=$true
    # Back up and validate ALL replacement files before touching the installation.
    foreach($file in $config.files){
        $top=($file.path -split '/')[0]
        if($top -in @('data','data-preview','.git','src','updates','backups')){throw 'An update attempted to replace user data'}
        $source=Child-Path $stage $file.path
        $destination=Child-Path $install $file.path
        if((File-Sha256 $source) -ne $file.sha256){throw 'Staged update failed verification'}
        $previous=Child-Path $backup ('files/'+$file.path)
        $exists=Test-Path -LiteralPath $destination
        if($exists){[void][IO.Directory]::CreateDirectory((Split-Path -Parent $previous));Copy-Item -LiteralPath $destination -Destination $previous}
        $changed.Add(@{source=$source;destination=$destination;previous=$previous;existed=$exists})
    }
    foreach($file in $changed){
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $file.destination))
        Copy-Item -LiteralPath $file.source -Destination $file.destination -Force
    }
    $health=Join-Path $jobFolder ('health-'+[guid]::NewGuid().ToString('N')+'.json')
    $env:YAPLOQ_UPDATE_HEALTH=$health
    $launched=Start-UpdatedApp
    $deadline=[datetime]::UtcNow.AddSeconds(65)
    $healthy=$false
    while([datetime]::UtcNow -lt $deadline){
        try{
            $identity=Invoke-RestMethod -Uri ('http://127.0.0.1:'+$config.port+'/api/identity') -TimeoutSec 2
            if($identity.ready -and $identity.version -eq $config.version -and $identity.channel -eq $config.channel -and (Test-Path -LiteralPath $health)){$healthy=$true;break}
        }catch{}
        if($launched.HasExited){break}
        Start-Sleep -Milliseconds 500
    }
    if(-not $healthy){throw 'The updated app did not finish starting. Restoring your previous version.'}
    Write-Outcome 'success' 'YapLoq was updated successfully. Your previous version is backed up.'
    $ready=Join-Path $data 'updates\ready.json'
    if(Test-Path -LiteralPath $ready){Remove-Item -LiteralPath $ready}
}catch{
    $failure=$_.Exception.Message
    try{($_.Exception.ToString()+[Environment]::NewLine+$_.ScriptStackTrace)|Set-Content -LiteralPath (Join-Path $jobFolder 'update-error.log') -Encoding UTF8}catch{}
    Stop-NewApp
    try{
        foreach($file in $changed){
            if($file.existed){Copy-Item -LiteralPath $file.previous -Destination $file.destination -Force}
            elseif(Test-Path -LiteralPath $file.destination){Remove-Item -LiteralPath $file.destination}
        }
        if($dataSaved){foreach($name in @('settings.json','settings.json.bak','history.json','queue.json')){
            $saved=Join-Path $dataBackup $name
            if(Test-Path -LiteralPath $saved){Copy-Item -LiteralPath $saved -Destination (Join-Path $data $name) -Force}
        }}
        Write-Outcome 'rolled-back' ('Update not applied: '+$failure)
        if($changed.Count){
            Remove-Item Env:\YAPLOQ_UPDATE_HEALTH -ErrorAction SilentlyContinue
            [void](Start-UpdatedApp)
        }
    }catch{
        try{Write-Outcome 'recovery-needed' ('Update failed: '+$failure+'. Recovery failed: '+$_.Exception.Message+'. Backup: '+$backup)}catch{}
    }
    if(-not $NoDialog){[void][Windows.Forms.MessageBox]::Show(('The update could not be completed. '+$failure+"`nYour backup is in: "+$backup),'YapLoq update',0,48)}
    exit 1
}
