#!/usr/bin/env python3
"""Builds the signed update feed of one Alchemac release.

  make-update-feed.py --app <new .app> --dmg <dmg> --out <dir> [--previous <old .app>]... [--key <path>]

Writes into <dir>: update.json (manifest, schema 1), update.json.sig (base64 Ed25519 signature of its exact bytes)
and one Alchemac-<version>-from-<build>.tar.xz per --previous app. Upload all of them, with the DMG, to the GitHub
release v<version>. The signing key is created once with `update-sign keygen`; it never leaves this Mac.
"""
import argparse
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = 'Deavour31/alchemac'
DEFAULT_KEY = Path.home() / '.alchemac-release/update-signing-ed25519.key'
SIGN_SOURCE = ROOT / 'tools/app/update-sign.swift'


def fail(text):
    raise SystemExit('make-update-feed: ' + text)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def read_info(app):
    with open(app / 'Contents/Info.plist', 'rb') as handle:
        return plistlib.load(handle)


def scan(app):
    """path -> entry for every directory, regular file and symlink below the .app (xattrs are ignored)."""
    entries = {}
    for current, dirs, files in os.walk(app, followlinks=False):
        for name in dirs + files:
            full = os.path.join(current, name)
            rel = os.path.relpath(full, app)
            if '\n' in rel or '\r' in rel:
                fail(f'path with a line break: {rel!r}')
            parts = rel.split(os.sep)
            if any(part in ('', '.', '..') for part in parts):
                fail(f'unsafe path: {rel!r}')
            mode = os.lstat(full).st_mode
            if stat.S_ISLNK(mode):
                entries[rel] = {'path': rel, 'type': 'link', 'target': os.readlink(full)}
            elif stat.S_ISDIR(mode):
                entries[rel] = {'path': rel, 'type': 'dir'}
            elif stat.S_ISREG(mode):
                entries[rel] = {'path': rel, 'type': 'file', 'size': os.lstat(full).st_size, 'sha256': sha256(full),
                                'executable': bool(mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))}
            else:
                fail(f'unsupported file type: {rel!r}')
    return entries


def tool(cache, source):
    binary = cache / 'update-sign'
    if not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime:
        cache.mkdir(parents=True, exist_ok=True)
        subprocess.run(['/usr/bin/xcrun', 'swiftc', '-O', '-target', 'arm64-apple-macos27.0',
                        '-module-cache-path', str(cache / 'module-cache'), '-o', str(binary), str(source)], check=True)
    return str(binary)


def make_delta(app, new, old_entries, out, name):
    changed = sorted(p for p, e in new.items() if e['type'] in ('file', 'link')
                     and not (p in old_entries and old_entries[p]['type'] == e['type']
                              and (e['type'] == 'link' and old_entries[p]['target'] == e['target']
                                   or e['type'] == 'file' and old_entries[p]['size'] == e['size'] and old_entries[p]['sha256'] == e['sha256'])))
    for path in changed:
        if not path.startswith('Contents/'):
            fail(f'unexpected path outside Contents: {path!r}')
    listing = out / (name + '.list')
    listing.write_bytes(''.join(p + '\n' for p in changed).encode('utf-8', 'surrogateescape'))
    try:
        env = dict(os.environ, COPYFILE_DISABLE='1')
        subprocess.run(['/usr/bin/tar', '--no-mac-metadata', '--no-xattrs', '-cJf', str(out / name), '-C', str(app), '-T', str(listing)],
                       check=True, env=env)
    finally:
        listing.unlink()
    return changed


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--dmg', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--previous', action='append', default=[], type=Path)
    parser.add_argument('--key', type=Path, default=DEFAULT_KEY)
    parser.add_argument('--tool-cache', type=Path, default=ROOT / 'work/alchemac-build')
    args = parser.parse_args()

    app = args.app.resolve()
    if not (app / 'Contents/Info.plist').is_file():
        fail('--app is not an app bundle')
    if not args.dmg.is_file():
        fail('--dmg not found')
    if args.out.exists() and any(args.out.iterdir()):
        fail(f'{args.out} already contains files')
    info = read_info(app)
    version, build = info['CFBundleShortVersionString'], int(info['CFBundleVersion'])
    bundle_id, minimum = info['CFBundleIdentifier'], info.get('LSMinimumSystemVersion', '27.0')
    if not re.fullmatch(r'[0-9]+(\.[0-9]+)*', version):
        fail(f'unexpected version {version!r}')
    dmg_name = f'Alchemac-{version}.dmg'
    if args.dmg.name != dmg_name:
        fail(f'the DMG must be named {dmg_name}')
    args.out.mkdir(parents=True, exist_ok=True)
    out = args.out.resolve()

    new = scan(app)
    deltas, summary = [], []
    seen = set()
    for previous in args.previous:
        previous = previous.resolve()
        old_build = int(read_info(previous)['CFBundleVersion'])
        if old_build >= build or old_build in seen:
            fail(f'--previous {previous.name} has build {old_build}: must be older than {build} and not repeated')
        seen.add(old_build)
        name = f'Alchemac-{version}-from-{old_build}.tar.xz'
        changed = make_delta(app, new, scan(previous), out, name)
        deltas.append({'fromBuild': old_build, 'name': name, 'size': (out / name).stat().st_size, 'sha256': sha256(out / name)})
        summary.append((old_build, len(changed), sum(new[p].get('size', 0) for p in changed)))

    manifest = {
        'schema': 1, 'bundleID': bundle_id, 'version': version, 'build': build, 'minimumSystem': minimum,
        'releaseURL': f'https://github.com/{REPO}/releases/tag/v{version}',
        'dmg': {'name': dmg_name, 'size': args.dmg.stat().st_size, 'sha256': sha256(args.dmg)},
        'deltas': sorted(deltas, key=lambda d: d['fromBuild']),
        'entries': [new[p] for p in sorted(new)],
    }
    (out / 'update.json').write_text(json.dumps(manifest, indent=1, ensure_ascii=False, sort_keys=True) + '\n', encoding='utf-8')

    signer = tool(args.tool_cache, SIGN_SOURCE)
    signed = subprocess.run([signer, 'sign', str(args.key), str(out / 'update.json')], check=True, capture_output=True, text=True)
    (out / 'update.json.sig').write_text(signed.stdout.strip() + '\n')
    public = subprocess.run([signer, 'pubkey', str(args.key)], check=True, capture_output=True, text=True).stdout.strip()
    if subprocess.run([signer, 'verify', public, str(out / 'update.json'), str(out / 'update.json.sig')]).returncode != 0:
        fail('the signature does not verify')

    for path in sorted(out.iterdir()):
        print(f'{path.stat().st_size:>12,}  {path}')
    print(f'verified with public key {public}')
    for old_build, count, size in summary:
        print(f'delta from build {old_build}: {count} changed file(s), {size:,} bytes before compression')
    print(f'upload with the DMG {dmg_name} to the GitHub release v{version}')


if __name__ == '__main__':
    main()
