#!/usr/bin/env python3
"""Builds Alchemac.app (and with --release a DMG). Preserves the signed upstream loader verbatim."""
from pathlib import Path
import hashlib
import json
import plistlib
import shutil
import subprocess
import os
import sys

ROOT = Path(__file__).resolve().parents[1]
PROFILE = json.loads((ROOT / 'config/alchemac.json').read_text())
RUNTIME = next((d for d in (ROOT / 'work/hadron-prototype' / b / PROFILE['runtime_build_id'] for b in ('t4-builds', 't2-builds'))
                if (d / 'BUILD-ID').exists()), None)
if RUNTIME is None: raise SystemExit('Runtime build not found: ' + PROFILE['runtime_build_id'])
# standalone-run refuses a runtime root longer than 180 characters (the Wine bootstrap path limit).
# The root is $HOME/Library/Application Support/Alchemac/runtime.noindex/prefix-sessions/<32 hex>/runtimes/<id>,
# so a long build id silently breaks every user whose home folder name is longer than a few characters.
# Allow a 32-character user name.
_longest_root = len('/Users/' + 'x' * 32 + '/Library/Application Support/Alchemac/runtime.noindex/prefix-sessions/'
                    + '0' * 32 + '/runtimes/' + PROFILE['runtime_build_id'])
if _longest_root > 180:
    raise SystemExit('runtime_build_id %r is too long: runtime root would be %d chars for a 32-char user name (limit 180); use a short id'
                     % (PROFILE['runtime_build_id'], _longest_root))
RELEASE = '--release' in sys.argv[1:]
BUNDLE_ID = 'io.github.deavour31.alchemac'
VERSION, BUILD = '0.5.14', '37'
# https://dl.winehq.org/wine/wine-mono/11.3.0/wine-mono-11.3.0-x86.msi, the version this Wine asks for.
WINE_MONO_SHA256 = 'df2dfc1665c2511882e7cabd56eafd0c0a3d94e5a7e86f969277f6c189d418d3'
PARENT = ROOT / ('outputs/alchemac-release.noindex' if RELEASE else 'outputs/alchemac-app-build.noindex')
APP = PARENT / 'Alchemac.app'
STAGE = PARENT / ('.staging-' + str(os.getpid())) / APP.name
CACHE = ROOT / 'work/alchemac-build/module-cache'


def run(argv):
    subprocess.run(list(map(str, argv)), check=True)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    PARENT.mkdir(parents=True, exist_ok=True)
    CACHE.mkdir(parents=True, exist_ok=True)
    if APP.exists() or STAGE.exists():
        raise SystemExit('Build output exists; preserve or move the previous build before rebuilding')
    adapter = json.loads((RUNTIME / 'ADAPTER.json').read_text())
    for name, expected in adapter['script_hashes'].items():
        if sha(RUNTIME / 'scripts' / name) != expected or sha(ROOT / 'src/hadron/scripts' / name) != expected:
            raise SystemExit('Runtime/source adapter mismatch: ' + name)
    contents = STAGE / 'Contents'
    resources = contents / 'Resources'
    (contents / 'MacOS').mkdir(parents=True)
    resources.mkdir()
    (contents / 'SharedSupport').mkdir()
    run(['/bin/cp', '-c', '-R', RUNTIME, contents / 'SharedSupport/runtime'])
    # Alchemac starts programs through scripts/standalone-run only. Hadron's Steam entry points
    # and their x86_64+arm64 shims are unused, so they are left out of the app.
    shutil.rmtree(contents / 'SharedSupport/runtime/steam')
    for script in (contents / 'SharedSupport/runtime/scripts').glob('steam-*'):
        script.unlink()
    sources = [ROOT / 'app/alchemac' / n for n in ('main.swift', 'App.swift', 'Runtime.swift', 'SessionController.swift', 'Profile.swift', 'InputSource.swift', 'Addon.swift', 'ExeIcon.swift', 'Maintenance.swift', 'Updater.swift')]
    run(['/usr/bin/xcrun', 'swiftc', '-O', '-swift-version', '5', '-target', 'arm64-apple-macos27.0', '-module-cache-path', CACHE,
         '-o', contents / 'MacOS/Alchemac', *sources])
    fonts = resources / 'Fonts'
    fonts.mkdir()
    for name in ('NanumGothic-Regular.ttf', 'NanumGothic-OFL.txt'):
        shutil.copy2(ROOT / 'work' / name, fonts / name)
    compiler = ROOT / 'work/hadron-prototype/toolchains/llvm-mingw-20260922-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang'
    run(['/usr/bin/arch', '-arm64', compiler, ROOT / 'app/alchemac/prefix-profile.c', '-O2', '-municode',
         '-ladvapi32', '-lgdi32', '-luser32', '-o', resources / 'prefix-profile.exe'])
    shutil.copy2(ROOT / 'config/alchemac.json', resources / 'alchemac.json')
    shutil.copy2(ROOT / 'src/hadron/sources.conf', resources / 'hadron-sources.conf')
    shutil.copy2(ROOT / 'outputs/hadron-investigation/runs/T2/standalone.patch', resources / 'standalone.patch')
    shutil.copy2(ROOT / 'app/alchemac/README.md', resources / 'README.md')
    shutil.copy2(ROOT / 'app/alchemac/session-attach', resources / 'session-attach')
    # prefix-profile installs this into a prefix the first time a .NET Framework program runs there.
    mono = ROOT / 'work/wine-mono/wine-mono-11.3.0-x86.msi'
    if sha(mono) != WINE_MONO_SHA256:
        raise SystemExit('Wine Mono package does not match the pinned hash')
    shutil.copy2(mono, resources / 'wine-mono.msi')
    licenses = resources / 'Licenses'
    licenses.mkdir()
    shutil.copy2(ROOT / 'app/alchemac/LICENSE', licenses / 'Alchemac-LICENSE.txt')
    shutil.copy2(ROOT / 'work/NanumGothic-OFL.txt', licenses / 'NanumGothic-OFL.txt')
    shutil.copy2(ROOT / 'work/wine-mono/COPYING', licenses / 'Wine-Mono-COPYING.txt')
    (licenses / 'README.txt').write_text(
        'Alchemac is MIT licensed (Alchemac-LICENSE.txt).\n'
        'It bundles the Hadron runtime (BSD-3-Clause, Copyright (c) 2026 David Andrews) with Wine, FEX,\n'
        'DXMT and other components, each under its own license in components/.\n'
        'It also bundles Wine Mono 11.3.0 (https://github.com/wine-mono/wine-mono), installed into a\n'
        'Wine environment when a .NET Framework program first runs there; source and license:\n'
        'https://dl.winehq.org/wine/wine-mono/11.3.0/\n'
        'Alchemac changes to Hadron and FEX are published as patches with the Alchemac source:\n'
        'https://github.com/Deavour31/alchemac\n', encoding='utf-8')
    run(['/bin/cp', '-R', contents / 'SharedSupport/runtime/licenses', licenses / 'components'])
    run(['/usr/bin/xcrun', 'swiftc', '-O', '-swift-version', '5', '-target', 'arm64-apple-macos27.0', '-module-cache-path', CACHE,
         ROOT / 'tools/app/make-icon.swift', '-o', CACHE.parent / 'make-icon'])
    iconset = STAGE.parent / 'Alchemac.iconset'
    if iconset.exists():
        raise SystemExit('Icon staging exists; inspect it before rebuilding')
    run([CACHE.parent / 'make-icon', iconset])
    run(['/usr/bin/iconutil', '-c', 'icns', iconset, '-o', resources / 'Alchemac.icns'])
    shutil.rmtree(iconset) # This invocation's generated images, outside runtime.
    info = {
        'CFBundleExecutable': 'Alchemac', 'CFBundleName': 'Alchemac', 'CFBundleDisplayName': 'Alchemac',
        'CFBundleIdentifier': BUNDLE_ID, 'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': VERSION, 'CFBundleVersion': BUILD,
        'CFBundleIconFile': 'Alchemac', 'LSMinimumSystemVersion': '27.0',
        'LSApplicationCategoryType': 'public.app-category.games', 'NSHighResolutionCapable': True,
        'LSMultipleInstancesProhibited': True,
    }
    if not RELEASE:
        info['AlchemacDevelopmentBuild'] = True
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    provenance = {'app': 'Alchemac', 'development_build': not RELEASE,
                  'runtime_build_id': PROFILE['runtime_build_id'], 'adapter': adapter,
                  'fex_downstream_patches': sorted(p.name for p in (ROOT / 'src/hadron/patches/fex').glob('*.patch')),
                  'wrapper_sources': {str(p.relative_to(ROOT)): sha(p) for p in sources},
                  'font_helper_source_sha256': sha(ROOT / 'app/alchemac/prefix-profile.c'),
                  'font_helper_sha256': sha(resources / 'prefix-profile.exe'),
                  'wrapper_sha256': sha(contents / 'MacOS/Alchemac'),
                  'wrapper_sha256_stage': 'compiler output before outer codesign',
                  'game_in_bundle': False, 'account_in_bundle': False,
                  'upstream_notarization_inherited': False}
    (resources / 'PROVENANCE.json').write_text(json.dumps(provenance, indent=2) + '\n')
    # Only sign the outer app. Never --deep sign, strip or resign the nested loader.
    run(['/usr/bin/codesign', '--force', '--sign', '-', STAGE])
    run(['/usr/bin/codesign', '--verify', '--strict', contents / 'SharedSupport/runtime/dist/lib/wine/aarch64-unix/wine.app'])
    run(['/usr/bin/codesign', '--verify', '--strict', STAGE])
    STAGE.rename(APP)
    STAGE.parent.rmdir()
    print(APP, flush=True)
    if RELEASE:
        dmg_stage = PARENT / 'dmg'
        if dmg_stage.exists():
            raise SystemExit('DMG staging exists; inspect it before rebuilding')
        dmg_stage.mkdir()
        run(['/bin/cp', '-c', '-R', APP, dmg_stage / APP.name])
        (dmg_stage / 'Applications').symlink_to('/Applications')
        dmg = PARENT / f'Alchemac-{VERSION}.dmg'
        run(['/usr/bin/hdiutil', 'create', '-quiet', '-volname', f'Alchemac {VERSION}', '-srcfolder', dmg_stage,
             '-fs', 'APFS', '-format', 'ULFO', '-ov', dmg])
        shutil.rmtree(dmg_stage) # This invocation's staging copy.
        print(dmg, hashlib.sha256(dmg.read_bytes()).hexdigest(), flush=True)


if __name__ == '__main__':
    main()
