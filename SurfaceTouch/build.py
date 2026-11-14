#!/usr/bin/env python3
"""Build SurfaceTouch.kext with MacKernelSDK."""
import argparse
import hashlib
import plistlib
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent
NAME = 'SurfaceTouch'
VERSION = '1.0.0'
IDENT = 'org.besiple.SurfaceTouch'
PCI_MATCH = '0xa0d08086 0xa0d18086 0x43d08086 0x43d18086 0x51d08086 0x51d18086'

def run(cmd):
    subprocess.run([str(x) for x in cmd], check=True, cwd=ROOT)

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sdk', type=Path, default=ROOT / 'MacKernelSDK')
    p.add_argument('--output', type=Path, default=ROOT / 'build')
    a = p.parse_args()
    out = a.output.resolve()
    sdk = a.sdk.resolve()

    if not sdk.exists():
        print(f"MacKernelSDK not found at {sdk}, cloning from GitHub...")
        subprocess.run(['git', 'clone', '--depth', '1', 'https://github.com/acidanthera/MacKernelSDK.git', str(sdk)], check=True)

    bundle = out / (NAME + '.kext') / 'Contents'
    (bundle / 'MacOS').mkdir(parents=True, exist_ok=True)
    objdir = out / 'obj'
    objdir.mkdir(parents=True, exist_ok=True)

    base = [
        'xcrun', 'clang++', '-arch', 'x86_64', '-std=c++17', '-O2', '-g',
        '-mkernel', '-fapple-kext', '-fno-exceptions', '-fno-rtti',
        '-fno-stack-protector', '-fno-builtin', '-fno-asynchronous-unwind-tables',
        '-mno-red-zone', '-nostdinc', '-DKERNEL', '-DKERNEL_PRIVATE', '-D__APPLE__',
        '-D__MACH__', '-D_FORTIFY_SOURCE=0',
        '-I' + str(sdk / 'Headers'),
        '-I' + str(ROOT),
        '-mmacosx-version-min=10.15',
        '-Wall', '-Wextra', '-Wno-unused-parameter', '-Wno-deprecated-declarations',
        '-Wno-ossharedptr-misuse',
        '-fdebug-compilation-dir=.',
        '-ffile-prefix-map=' + str(ROOT) + '=/SurfaceTouch',
        '-ffile-prefix-map=' + str(sdk) + '=/MacKernelSDK'
    ]

    objects = []
    for source in sorted(ROOT.glob('*.cpp')):
        obj = objdir / (source.stem + '.o')
        run(base + ['-c', source, '-o', obj])
        objects.append(obj)

    exe = bundle / 'MacOS' / NAME
    run([
        'xcrun', 'ld', '-arch', 'x86_64', '-kext', '-undefined', 'dynamic_lookup',
        '-no_fixup_chains', '-macos_version_min', '10.15',
        '-o', exe, *objects, sdk / 'Library/x86_64/libkmod.a'
    ])

    libs = {
        'com.apple.kpi.iokit': '14.0',
        'com.apple.kpi.libkern': '14.0',
        'com.apple.kpi.mach': '14.0',
        'com.apple.kpi.unsupported': '14.0',
        'com.apple.iokit.IOPCIFamily': '2.9',
        'com.apple.iokit.IOHIDFamily': '2.0'
    }

    info = {
        'CFBundleIdentifier': IDENT,
        'CFBundleExecutable': NAME,
        'CFBundleName': NAME,
        'CFBundlePackageType': 'KEXT',
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleVersion': VERSION,
        'CFBundleShortVersionString': VERSION,
        'OSBundleCompatibleVersion': VERSION,
        'OSBundleRequired': 'Root',
        'OSBundleLibraries': libs,
        'IOKitPersonalities': {
            NAME: {
                'CFBundleIdentifier': IDENT,
                'IOClass': NAME,
                'IOProviderClass': 'IOPCIDevice',
                'IOPCIMatch': PCI_MATCH,
                'IOProbeScore': 2000
            }
        }
    }
    (bundle / 'Info.plist').write_bytes(plistlib.dumps(info))
    run(['xcrun', 'strip', '-S', exe])

    symbols = subprocess.check_output(['xcrun', 'nm', str(exe)], text=True)
    assert ' _kmod_info' in symbols and ' __realmain' in symbols, 'missing kext lifecycle metadata'

    unresolved = subprocess.check_output(['xcrun', 'nm', '-u', str(exe)], text=True)
    assert '__ZN12SurfaceTouch' not in unresolved and '__ZN21SurfaceTouchHIDDevice' not in unresolved, 'unresolved symbols'
    assert not any(x in unresolved for x in ['chkstk_darwin', '___memcpy_chk']), 'userspace ABI imported'

    sha256 = hashlib.sha256(exe.read_bytes()).hexdigest()
    print(f"SUCCESS: Built {NAME}.kext v{VERSION} (SHA-256: {sha256})")

if __name__ == '__main__':
    main()
