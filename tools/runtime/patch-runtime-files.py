#!/usr/bin/env python3
"""Replace rebuilt files (Wine PE/unix libraries, FEX DLLs, ...) in a Hadron runtime.

Run with `python3 -I`.

Usage: patch-runtime-files.py <base-runtime> <new-runtime>
           --file <built-file> <runtime-relative-path> [--file ...]
           --patch <patch-file> [--patch ...]
           [--reason <text>] [--kind <short label>]

Keep <new-runtime> SHORT (e.g. 0.3.3-ac1): the runtime root is limited to 180 characters.

The base runtime is cloned (APFS clone, `cp -c -R`) to <new-runtime> (which must not exist).
Every <runtime-relative-path> must already exist in the base as a regular file (not a symlink)
and must not be inside a *.app bundle (a signed loader is never replaced). The same built file
may be given for several paths. Each built file is copied next to its target and stripped
(PE: llvm-strip --strip-debug; Mach-O: strip -S -x, then ad-hoc codesign), keeps the base
file's mode bits, and replaces the target atomically. The PE machine / Mach-O cputype of the
new file must equal the base file's. Afterwards the new runtime is refused (and the new folder
deleted) if a replaced file contains the home directory path or /private/tmp/.

BUILD-ID becomes the new folder's name; RUNTIME-PATCH.json records build_id, base_build_id,
kind, reason, patches, files and tool (an earlier RUNTIME-PATCH.json of the base is nested
under "previous"); BUILD-LINEAGE.json (if present) is copied and extended like
patch-mtld3d-d3d9.py does.
"""
import hashlib, json, os, shutil, struct, subprocess, sys
from pathlib import Path

TOOL = 'tools/runtime/patch-runtime-files.py'
LLVM_STRIP = '/opt/homebrew/opt/llvm/bin/llvm-strip'
STRIP = '/usr/bin/strip'
CODESIGN = '/usr/bin/codesign'
MACHO64 = b'\xcf\xfa\xed\xfe'


def check_id_length(name):
    # standalone-run refuses a runtime root over 180 chars; allow a 32-char user name.
    n = len('/Users/' + 'x' * 32 + '/Library/Application Support/Alchemac/runtime.noindex/prefix-sessions/' + '0' * 32 + '/runtimes/' + name)
    if n > 180:
        raise SystemExit('new runtime name %r is too long (runtime root would be %d chars, limit 180); use a short name such as 0.3.0-ac6' % (name, n))

def sha(b): return hashlib.sha256(b).hexdigest()


def kind_of(d):
    """('pe', machine) / ('macho', cputype) / (None, None)."""
    if d[:2] == b'MZ' and len(d) > 0x40:
        pe, = struct.unpack_from('<I', d, 0x3c)
        if d[pe:pe + 4] == b'PE\0\0':
            return 'pe', struct.unpack_from('<H', d, pe + 4)[0]
    if d[:4] == MACHO64 and len(d) >= 8:
        return 'macho', struct.unpack_from('<I', d, 4)[0]
    return None, None


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError('%s failed: %s' % (' '.join(cmd), (r.stderr or r.stdout).strip()))


def check_rel(base, rel):
    p = Path(rel)
    if p.is_absolute() or '..' in p.parts or not p.parts:
        raise SystemExit('refusing: %r is not a clean runtime-relative path' % rel)
    if any(part.endswith('.app') for part in p.parts):
        raise SystemExit('refusing: %s is inside an .app bundle (the signed loader is never replaced)' % rel)
    cur = base
    for part in p.parts[:-1]:
        cur = cur / part
        if cur.is_symlink():
            raise SystemExit('refusing: %s goes through a symlink (%s)' % (rel, part))
    f = base / p
    if f.is_symlink() or not f.is_file():
        raise SystemExit('refusing: %s is not an existing regular file in the base runtime' % rel)


def main():
    args = sys.argv[1:]
    pos, files, patches, reason, kind = [], [], [], None, None
    i = 0
    try:
        while i < len(args):
            a = args[i]
            if a == '--file':
                files.append((Path(args[i + 1]).resolve(), args[i + 2])); i += 3
            elif a == '--patch':
                patches.append(Path(args[i + 1]).resolve()); i += 2
            elif a == '--reason':
                reason = args[i + 1]; i += 2
            elif a == '--kind':
                kind = args[i + 1]; i += 2
            elif a.startswith('--'):
                raise SystemExit(__doc__)
            else:
                pos.append(a); i += 1
    except IndexError:
        raise SystemExit(__doc__)
    if len(pos) != 2 or not files or not patches:
        raise SystemExit(__doc__)
    base, new = Path(pos[0]).resolve(), Path(pos[1]).resolve()
    check_id_length(new.name)
    if new.exists():
        raise SystemExit('destination exists: %s' % new)
    if not base.is_dir():
        raise SystemExit('base runtime not found: %s' % base)
    for p in patches:
        if not p.is_file():
            raise SystemExit('patch not found: %s' % p)
    seen = set()
    for src, rel in files:
        if not src.is_file():
            raise SystemExit('built file not found: %s' % src)
        if rel in seen:
            raise SystemExit('duplicate runtime path: %s' % rel)
        seen.add(rel)
        check_rel(base, rel)
        k, _ = kind_of(src.read_bytes())
        if k is None:
            raise SystemExit('refusing: %s is neither a PE nor a Mach-O 64-bit file' % src)

    subprocess.run(['cp', '-c', '-R', str(base), str(new)], check=True)
    try:
        rows = replace_all(base, new, files)
        home = str(Path.home()).encode()
        for rel, _, _, _ in rows:
            d = (new / rel).read_bytes()
            for needle in (home, b'/private/tmp/'):
                if needle in d:
                    raise SystemExit('refusing: %s contains %r' % (rel, needle.decode()))
        write_meta(base, new, rows, files, patches, reason, kind)
    except BaseException as e:
        if new.exists() and new.parent != new:
            shutil.rmtree(new, ignore_errors=True)
        if isinstance(e, RuntimeError):
            raise SystemExit('refusing: %s' % e)
        if isinstance(e, SystemExit):
            raise SystemExit('%s\n(new runtime folder removed)' % e)
        raise
    print('%-62s %-12s %-12s %s' % ('runtime path', 'base sha', 'new sha', 'built from'))
    for rel, o, n, src in rows:
        print('%-62s %-12s %-12s %s' % (rel, o[:12], n[:12], src))
    print('created %s (BUILD-ID %s)' % (new, new.name))


def replace_all(base, new, files):
    rows = []
    cache = {}  # built file -> stripped bytes
    for src, rel in files:
        old = (base / rel).read_bytes()
        dst = new / rel
        mode = os.stat(base / rel).st_mode & 0o7777
        tmp = dst.with_name(dst.name + '.rpt-tmp')
        if src not in cache:
            shutil.copyfile(src, tmp)
            k, _ = kind_of(tmp.read_bytes())
            if k == 'pe':
                run([LLVM_STRIP, '--strip-debug', str(tmp)])
            else:
                run([STRIP, '-S', '-x', str(tmp)])
                run([CODESIGN, '-f', '-s', '-', str(tmp)])
            cache[src] = tmp.read_bytes()
        else:
            tmp.write_bytes(cache[src])
        data = cache[src]
        nk, nm = kind_of(data)
        ok, om = kind_of(old)
        if (nk, nm) != (ok, om):
            tmp.unlink()
            raise SystemExit('refusing: %s type mismatch: new %s 0x%x, base %s %s' % (
                rel, nk, nm or 0, ok, hex(om) if om is not None else None))
        os.chmod(tmp, mode)
        os.replace(tmp, dst)
        assert (dst.read_bytes()) == data
        rows.append((rel, sha(old), sha(data), src.name))
    return rows


def write_meta(base, new, rows, files, patches, reason, kind):
    base_id = (base / 'BUILD-ID').read_text().strip() if (base / 'BUILD-ID').is_file() else None
    (new / 'BUILD-ID').write_text(new.name + '\n')
    info = {
        'build_id': new.name,
        'base_build_id': base_id,
        'kind': kind,
        'reason': reason,
        'patches': [{'file': p.name, 'sha256': sha(p.read_bytes())} for p in patches],
        'files': [{'path': r, 'base_sha256': o, 'new_sha256': n, 'built_from': s} for r, o, n, s in rows],
        'tool': TOOL,
    }
    prev = base / 'RUNTIME-PATCH.json'
    if prev.is_file():
        info['previous'] = json.loads(prev.read_text())
    (new / 'RUNTIME-PATCH.json').write_text(json.dumps(info, indent=2, ensure_ascii=False) + '\n')
    lin = base / 'BUILD-LINEAGE.json'
    if lin.is_file():
        L = json.loads(lin.read_text())
        L['previous_build_id'] = L.get('build_id', base_id)
        L['build_id'] = new.name
        L.setdefault('lineage', []).append('%s: %s on %s (RUNTIME-PATCH.json)' % (new.name, kind or 'runtime files replaced', base_id))
        L.setdefault('rebuilds', []).append({
            'build_id': new.name, 'base_build_id': base_id, 'tool': TOOL,
            'change': '%s: %s' % (kind or 'runtime files replaced', ', '.join(r for r, _, _, _ in rows)),
            'patches': [p.name for p in patches], 'reason': reason})
        (new / 'BUILD-LINEAGE.json').write_text(json.dumps(L, indent=2, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
