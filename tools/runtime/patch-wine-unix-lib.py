#!/usr/bin/env python3
"""Replace one rebuilt Wine unix library (for example win32u.so) in a Hadron runtime.

Run with `python3 -I`.

Usage: patch-wine-unix-lib.py <base-runtime> <new-runtime> <library.so> <patch>...

The new folder name is the runtime's BUILD-ID and must stay SHORT (for example 0.3.0-ac6): the
runtime root may be at most 180 characters, so do NOT append suffixes to the base id. Record the
lineage in WINE-PATCH.json (base_build_id) instead. The tool refuses names that are too long.

<library.so> must be a Mach-O arm64 library named like one already in
dist/lib/wine/aarch64-unix/ of the base runtime (the file name picks the library to
replace). The base runtime folder is cloned (APFS clone, `cp -c -R`) to the new folder
(which must not exist), its BUILD-ID is set to the new folder's name, the library is
replaced, and WINE-PATCH.json records the Wine patch file names and the old and new
sha256 of the library. Scripts are not touched, so ADAPTER.json stays valid. Apps that
migrate prefixes by BUILD-ID see a new runtime and run their normal prefix update.
"""
import hashlib, json, os, struct, subprocess, sys
from pathlib import Path

DIR = 'dist/lib/wine/aarch64-unix'
MACHO64 = b'\xcf\xfa\xed\xfe'
CPU_ARM64 = 0x0100000C


def check_id_length(name):
    # standalone-run refuses a runtime root over 180 chars; allow a 32-char user name.
    n = len('/Users/' + 'x' * 32 + '/Library/Application Support/Alchemac/runtime.noindex/prefix-sessions/' + '0' * 32 + '/runtimes/' + name)
    if n > 180:
        raise SystemExit('new runtime name %r is too long (runtime root would be %d chars, limit 180); use a short name such as 0.3.0-ac6' % (name, n))

def sha(b): return hashlib.sha256(b).hexdigest()


def main():
    if len(sys.argv) < 5:
        raise SystemExit(__doc__)
    base, new = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    lib = Path(sys.argv[3]).resolve()
    patches = [Path(p).resolve() for p in sys.argv[4:]]
    check_id_length(new.name)
    if new.exists():
        raise SystemExit('destination exists: %s' % new)
    for p in patches:
        if not p.is_file():
            raise SystemExit('patch not found: %s' % p)
    rel = '%s/%s' % (DIR, lib.name)
    if not (base / rel).is_file():
        raise SystemExit('base runtime has no %s' % rel)
    data = lib.read_bytes()
    if data[:4] != MACHO64 or struct.unpack_from('<I', data, 4)[0] != CPU_ARM64:
        raise SystemExit('refusing: %s is not a Mach-O arm64 library' % lib)
    old_sha, new_sha = sha((base / rel).read_bytes()), sha(data)
    if old_sha == new_sha:
        raise SystemExit('refusing: the library is identical to the base runtime\'s')
    subprocess.run(['cp', '-c', '-R', str(base), str(new)], check=True)
    dst = new / rel
    tmp = dst.with_name(dst.name + '.tmp')
    tmp.write_bytes(data)
    os.chmod(tmp, 0o755)
    os.replace(tmp, dst)
    assert sha(dst.read_bytes()) == new_sha
    base_id = (base / 'BUILD-ID').read_text().strip()
    (new / 'BUILD-ID').write_text(new.name + '\n')
    info = {
        'build_id': new.name,
        'base_build_id': base_id,
        'change': '%s rebuilt with the Wine patches below; every other runtime file is unchanged' % lib.name,
        'tool': 'tools/runtime/patch-wine-unix-lib.py',
        'patches': [{'file': p.name, 'sha256': sha(p.read_bytes())} for p in patches],
        'library': rel,
        'original_sha256': old_sha,
        'patched_sha256': new_sha,
        'modified_runtime_files': [rel, 'BUILD-ID'],
    }
    (new / 'WINE-PATCH.json').write_text(json.dumps(info, indent=2, ensure_ascii=False) + '\n')
    print('patched %s\n  sha256 %s -> %s' % (dst, old_sha, new_sha))


if __name__ == '__main__':
    main()
