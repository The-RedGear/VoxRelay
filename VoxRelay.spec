# -*- mode: python ; coding: utf-8 -*-


a = Analysis(
    ['wpf_launcher.py'],
    pathex=['src'],
    binaries=[],
    datas=[('VoxRelay.ps1', '.'), ('VoxRelay.xaml', '.'), ('ImportPreview.xaml', '.'), ('assets', 'assets')],
    hiddenimports=['boto3', 'botocore', 'miniaudio', '_cffi_backend', 'cffi', 'websockets', 'google.auth', 'google.oauth2.service_account'],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=['tkinter', '_tkinter'],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='VoxRelay',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=['assets/VoxRelay.ico'],
    version='version_info.txt',
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name='VoxRelay',
)
