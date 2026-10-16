# Dedicated preview executable; production VoxRelay.spec remains unchanged.
a = Analysis(
    ['yaploq_preview.py'], pathex=['src'], binaries=[],
    datas=[('VoxRelay.ps1', '.'), ('VoxRelay.xaml', '.'), ('ImportPreview.xaml', '.'), ('assets', 'assets')],
    hiddenimports=['boto3', 'botocore', 'miniaudio', '_cffi_backend', 'cffi', 'websockets', 'google.auth', 'google.oauth2.service_account'],
    hookspath=[], hooksconfig={}, runtime_hooks=[], excludes=['tkinter', '_tkinter'],
    noarchive=False, optimize=0,
)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name='YapLoq-preview',
          debug=False, strip=False, upx=False, console=False,
          icon=['assets/VoxRelay.ico'])
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name='YapLoq-preview')
