"""Exercise the real Windows updater helper against disposable installations."""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from threading import Thread

import pytest

pytestmark=pytest.mark.skipif(sys.platform!='win32',reason='Windows installer helper')
HELPER=Path(__file__).resolve().parents[1]/'assets'/'ApplyUpdate.ps1'


@pytest.fixture(scope='module')
def fixture_exe(tmp_path_factory):
    root=tmp_path_factory.mktemp('update-fixture')
    # The fixture writes the same desktop-ready marker as the real WPF app.
    # No real YapLoq process, credentials, service, or installation is touched.
    script=root/'compile.ps1'
    script.write_text('''
param([string]$OutputExe)
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
public class FixtureApp {
 public static void Main() {
  string marker=Environment.GetEnvironmentVariable("YAPLOQ_UPDATE_HEALTH");
  if (!String.IsNullOrEmpty(marker) && Environment.GetEnvironmentVariable("YAPLOQ_FIXTURE_FAIL")!="1") {
   File.WriteAllText(marker,"ready");
   Thread.Sleep(30000);
  }
 }
}
'@ -OutputAssembly $OutputExe -OutputType WindowsApplication
''',encoding='utf-8')
    executable=root/'Fixture.exe'
    subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(script),str(executable)],check=True,capture_output=True,timeout=30)
    return executable


@pytest.mark.parametrize('fail',[False,True])
def test_helper_applies_or_rolls_back_without_changing_user_data(tmp_path,fixture_exe,fail):
    install=tmp_path/'[portable] installation';install.mkdir()
    shutil.copy2(fixture_exe,install/'YapLoq.exe')
    runtime=install/'_internal';runtime.mkdir()
    (runtime/'payload.txt').write_text('old runtime')
    data=install/'data';data.mkdir()
    (data/'settings.json').write_text('{"fixture":"preserve me"}')
    job=data/'updates'/'job';stage=job/'stage';stage.mkdir(parents=True)
    shutil.copy2(fixture_exe,stage/'YapLoq.exe')
    (stage/'_internal').mkdir()
    (stage/'_internal'/'payload.txt').write_text('new runtime')
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            body=json.dumps(dict(ready=True,version='0.6.0',channel='yaploq')).encode()
            self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        def log_message(self,*args):pass
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    thread=Thread(target=server.serve_forever,daemon=True);thread.start()
    plan=dict(install=str(install),stage=str(stage),backup=str(job/'rollback'),data=str(data),
        executable='YapLoq.exe',version='0.6.0',channel='yaploq',port=server.server_port,processes=[],
        files=[dict(path=name,sha256=hashlib.sha256((stage/name).read_bytes()).hexdigest()) for name in ['YapLoq.exe','_internal/payload.txt']])
    plan_path=job/'plan.json';plan_path.write_text(json.dumps(plan))
    environment=dict(os.environ,YAPLOQ_FIXTURE_FAIL='1' if fail else '0')
    try:
        with (tmp_path/'helper.log').open('wb') as log:
            result=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(HELPER),'-Plan',str(plan_path),'-NoDialog'],env=environment,stdout=log,stderr=subprocess.STDOUT,timeout=30)
        outcome=json.loads((data/'updates'/'outcome.json').read_text(encoding='utf-8-sig'))
        assert result.returncode==(1 if fail else 0),(tmp_path/'helper.log').read_text()
        assert outcome['state']==('rolled-back' if fail else 'success'),outcome
        assert (runtime/'payload.txt').read_text()==('old runtime' if fail else 'new runtime')
        assert json.loads((data/'settings.json').read_text())=={'fixture':'preserve me'}
        assert (job/'rollback'/'files'/'_internal'/'payload.txt').read_text()=='old runtime'
    finally:
        server.shutdown();server.server_close()
        # Stop only the fixture process whose exact executable lives in tmp_path.
        subprocess.run(['powershell.exe','-NoProfile','-Command',
            'param($ExactExe) Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -eq $ExactExe } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }',str(install/'YapLoq.exe')],capture_output=True,timeout=15)
