#!/usr/bin/env python3
"""Replace the native ARM64X d3d9.dll of mtld3d in a Hadron runtime.

Only the d3d9 crate of mtld3d changed, so only dist/lib/hadron/d3d9/aarch64/d3d9.dll
(and, with --i386, dist/lib/hadron/d3d9/i386/d3d9.dll) is replaced; build them with
tools/runtime/build-mtld3d-d3d9.sh. mtld3d.dll and mtld3d.so stay as in the base runtime.

Run with `python3 -I`.

Usage: patch-mtld3d-d3d9.py [--i386 <i386-d3d9.dll>] <base-runtime> <new-runtime> <d3d9.dll> <patch>...
Keep <new-runtime> SHORT (e.g. 0.3.0-ac6, never base-id plus suffix): the runtime root is limited to 180 characters.

The base runtime folder is cloned (APFS clone, `cp -c -R`) to the new folder (which must
not exist), its BUILD-ID is set to the new folder's name, the DLL is replaced, one line
naming the patches is appended to dist/lib/hadron/d3d9/VERSION and MTLD3D-PATCH.json is
written. The new DLLs are checked (PE, machine ARM64 -- ARM64X images report ARM64 -- or
i386 for --i386, and containing "mtld3d") and so is the base's existing ARM64X DLL before
anything is written. The i386 DLL of the base may be the shipped one or an earlier mingw-CRT
build; its old and new sha256 are recorded.
Scripts are not touched, so ADAPTER.json stays valid.
"""
import hashlib, json, os, struct, subprocess, sys
from pathlib import Path

REL = 'dist/lib/hadron/d3d9/aarch64/d3d9.dll'
REL_I386 = 'dist/lib/hadron/d3d9/i386/d3d9.dll'
VERSION = 'dist/lib/hadron/d3d9/VERSION'
ORIG_SHA = '41563499c3b05494ef820a795a12d0f3a563e1d2bf324e2827b6e47cf6e16e98'
MTLD3D_BASE = '20707710a67c60c16ef78c5425acd87e9b3d3bc5'
MACHINE_ARM64 = 0xAA64
MACHINE_I386 = 0x014C


def check_id_length(name):
    # standalone-run refuses a runtime root over 180 chars; allow a 32-char user name.
    n = len('/Users/' + 'x' * 32 + '/Library/Application Support/Alchemac/runtime.noindex/prefix-sessions/' + '0' * 32 + '/runtimes/' + name)
    if n > 180:
        raise SystemExit('new runtime name %r is too long (runtime root would be %d chars, limit 180); use a short name such as 0.3.0-ac6' % (name, n))

def sha(b): return hashlib.sha256(b).hexdigest()


def check_dll(d, want=MACHINE_ARM64):
    assert d[:2] == b'MZ' and len(d) > 0x40, 'not a PE file'
    pe, = struct.unpack_from('<I', d, 0x3c)
    assert d[pe:pe + 4] == b'PE\0\0', 'no PE signature'
    machine, = struct.unpack_from('<H', d, pe + 4)
    assert machine == want, 'PE machine 0x%04x is not 0x%04x' % (machine, want)
    assert b'mtld3d' in d, 'no "mtld3d" marker in the DLL'


def main():
    args = sys.argv[1:]
    dll32 = None
    if args and args[0] == '--i386':
        if len(args) < 2:
            raise SystemExit(__doc__)
        dll32 = Path(args[1]).resolve()
        args = args[2:]
    if len(args) < 4:
        raise SystemExit(__doc__)
    base, new = Path(args[0]).resolve(), Path(args[1]).resolve()
    check_id_length(new.name)
    dll = Path(args[2]).resolve()
    patches = [Path(p).resolve() for p in args[3:]]
    if new.exists():
        raise SystemExit('destination exists: %s' % new)
    for p in patches:
        if not p.is_file():
            raise SystemExit('patch not found: %s' % p)
    old = (base / REL).read_bytes()
    old_sha = sha(old)
    if old_sha != ORIG_SHA:
        raise SystemExit('refusing: base d3d9.dll sha256 %s is not the expected %s' % (old_sha, ORIG_SHA))
    data = dll.read_bytes()
    try:
        check_dll(data)
    except AssertionError as e:
        raise SystemExit('refusing: %s: %s' % (dll, e))
    new_sha = sha(data)
    data32 = None
    if dll32 is not None:
        data32 = dll32.read_bytes()
        try:
            check_dll(data32, MACHINE_I386)
        except AssertionError as e:
            raise SystemExit('refusing: %s: %s' % (dll32, e))
    old32_sha = sha((base / REL_I386).read_bytes())
    names = [p.name for p in patches]

    subprocess.run(['cp', '-c', '-R', str(base), str(new)], check=True)
    dst = new / REL
    tmp = dst.with_name(dst.name + '.tmp')
    tmp.write_bytes(data)
    os.chmod(tmp, 0o644)
    os.replace(tmp, dst)
    assert sha(dst.read_bytes()) == new_sha
    if data32 is not None:
        dst32 = new / REL_I386
        tmp32 = dst32.with_name(dst32.name + '.tmp')
        tmp32.write_bytes(data32)
        os.chmod(tmp32, 0o644)
        os.replace(tmp32, dst32)
        assert sha(dst32.read_bytes()) == sha(data32)
    ver = new / VERSION
    text = ver.read_text()
    if text and not text.endswith('\n'):
        text += '\n'
    text += 'd3d9 (aarch64) rebuilt with patches: %s\n' % ', '.join(names)
    if data32 is not None:
        text += 'd3d9 (i386) rebuilt against the mingw CRT with patches: %s\n' % ', '.join(names)
    ver.write_text(text)
    base_id = (base / 'BUILD-ID').read_text().strip()
    (new / 'BUILD-ID').write_text(new.name + '\n')
    info = {
        'build_id': new.name,
        'base_build_id': base_id,
        'change': 'native ARM64X d3d9.dll%s of mtld3d rebuilt with the d3d9 patches below; '
                  'mtld3d.dll and mtld3d.so are unchanged' % (' and i386 d3d9.dll' if data32 else ''),
        'tool': 'tools/runtime/patch-mtld3d-d3d9.py',
        'build_tool': 'tools/runtime/build-mtld3d-d3d9.sh',
        'mtld3d_base_commit': MTLD3D_BASE,
        'patches': [{'file': p.name, 'sha256': sha(p.read_bytes())} for p in patches],
        'original_d3d9_aarch64_sha256': old_sha,
        'patched_d3d9_aarch64_sha256': new_sha,
        'modified_runtime_files': [REL, VERSION, 'BUILD-ID'],
        'i386_d3d9_unchanged': data32 is None,
        'i386_d3d9_sha256': sha((new / REL_I386).read_bytes()),
    }
    if data32 is not None:
        info['original_d3d9_i386_sha256'] = old32_sha
        info['patched_d3d9_i386_sha256'] = sha(data32)
        info['i386_crt'] = 'llvm-mingw (built by build-mtld3d-d3d9.sh; upstream uses the MSVC CRT)'
        info['modified_runtime_files'].insert(1, REL_I386)
    (new / 'MTLD3D-PATCH.json').write_text(json.dumps(info, indent=2, ensure_ascii=False) + '\n')
    print('patched %s\n  sha256 %s -> %s' % (dst, old_sha, new_sha))


if __name__ == '__main__':
    main()
