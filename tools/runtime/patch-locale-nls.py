#!/usr/bin/env python3
"""Give Wine's Korean calendar (CAL_KOREA, id 5) its era name.

Wine's locale.nls lists one EMPTY era string for calendar 5, while Windows returns the
Dangi era name. Delphi-built programs skip empty era names, end up with an empty era
array and crash indexing it at startup under a Korean locale.

Run with `python3 -I`.

Usage: patch-locale-nls.py <base-runtime> [<new-runtime>]
Keep <new-runtime> SHORT (e.g. 0.3.0-ac6, never base-id plus suffix): the runtime root is limited to 180 characters.

With two arguments the base runtime folder is cloned (APFS clone, `cp -c -R`) to the new
folder, its BUILD-ID is set to the new folder's name and NLS-PATCH.json is written.
With one argument that runtime is patched in place (locale.nls only).

How: a 16-byte block (pad, NUL-terminated length-prefixed string "<era>", string array [1 -> that string]) is
inserted at the end of the locale section (start of the charmaps section). Every other
section is addressed from the file header, so the header's charmaps/geoids/scripts
offsets are advanced by 16 and calendar 5's era and abbreviated era arrays are pointed at
the new array. All other bytes are unchanged and merely shifted. The result is
re-parsed and checked before anything is written.
"""
import hashlib, json, os, shutil, struct, subprocess, sys
from pathlib import Path

REL = 'dist/share/wine/nls/locale.nls'
ORIG_SHA = 'c35c8f50780a6e4248e05537e96dbc7f8249831c3f1abd3d255d93e85b91d1fd'
ERA = '단기'
CAL_KOREA = 5
INSERT = 16


def check_id_length(name):
    # standalone-run refuses a runtime root over 180 chars; allow a 32-char user name.
    n = len('/Users/' + 'x' * 32 + '/Library/Application Support/Alchemac/runtime.noindex/prefix-sessions/' + '0' * 32 + '/runtimes/' + name)
    if n > 180:
        raise SystemExit('new runtime name %r is too long (runtime root would be %d chars, limit 180); use a short name such as 0.3.0-ac6' % (name, n))

def sha(b): return hashlib.sha256(b).hexdigest()


def parse(d):
    hdr = list(struct.unpack_from('<8I', d, 0))
    locales, charmaps, geoids, scripts = hdr[4:]
    nb_cal, cal_size, cal_off, str_off = struct.unpack_from('<HHII', d, locales + 0x38)
    return hdr, dict(locales=locales, charmaps=charmaps, geoids=geoids, scripts=scripts,
                     nb_cal=nb_cal, cal_size=cal_size, cal_off=cal_off,
                     strings=locales + str_off)


def cal_pos(p, cal):
    return p['locales'] + p['cal_off'] + (cal - 1) * p['cal_size']


def read_str(d, p, idx):
    o = p['strings'] + idx * 2
    n, = struct.unpack_from('<H', d, o)
    return d[o + 2:o + 2 + n * 2].decode('utf-16-le')


def read_arr(d, p, idx):
    o = p['strings'] + idx * 2
    n, = struct.unpack_from('<H', d, o)
    return [read_str(d, p, i) for i in struct.unpack_from('<%dI' % n, d, o + 2)]


def patch(d):
    hdr, p = parse(d)
    assert len(d) == hdr[7], 'file size != scripts offset'
    assert p['nb_cal'] >= CAL_KOREA and p['cal_size'] >= 0x34
    assert (p['locales'], p['charmaps'], p['geoids'], p['scripts']) == (0x2678, 0xa7c00, 0xb995e, 0xc2106)
    at = p['charmaps']
    assert (at - p['strings']) % 2 == 0 and at > p['strings']
    # Strings in the pool are [WCHAR len][chars][WCHAR 0]; an array is [WCHAR count][DWORD idx...]
    # and its DWORDs sit at an even WCHAR index, so the block starts with one pad WCHAR:
    #   pad | len "<era>" NUL | count=1 idx
    s_idx = (at - p['strings']) // 2 + 1
    a_idx = s_idx + len(ERA) + 2
    assert s_idx % 2 == 1 and a_idx % 2 == 1, 'string array would leave its DWORDs unaligned'
    block = (bytes(2) + struct.pack('<H', len(ERA)) + ERA.encode('utf-16-le') + bytes(2)
             + struct.pack('<HI', 1, s_idx))
    assert len(block) == INSERT
    out = bytearray(d[:at] + block + d[at:])
    for i in (5, 6, 7):
        struct.pack_into('<I', out, i * 4, hdr[i] + INSERT)
    c = cal_pos(p, CAL_KOREA)
    for off in (0x10, 0x30):                   # serastring, sabbreverastring
        old, = struct.unpack_from('<I', out, c + off)
        assert read_arr(d, p, old) == [''], 'calendar 5 era is not the expected empty string'
        struct.pack_into('<I', out, c + off, a_idx)
    out = bytes(out)
    # verify by re-parsing
    h2, p2 = parse(out)
    assert len(out) == h2[7] == len(d) + INSERT
    assert out[p2['strings'] + (s_idx + 1 + len(ERA)) * 2:][:2] == bytes(2), 'era not NUL terminated'
    assert read_arr(out, p2, struct.unpack_from('<I', out, c + 0x10)[0]) == [ERA]
    assert read_arr(out, p2, struct.unpack_from('<I', out, c + 0x30)[0]) == [ERA]
    assert out[at + INSERT:] == d[at:], 'charmaps/geoids/scripts not preserved'
    # locale section: identical except the two calendar fields
    diff = [i for i in range(at) if out[i] != d[i] and not 4 <= i < 32]
    assert set(diff) <= {c + o + k for o in (0x10, 0x30) for k in range(4)}, 'unexpected change'
    assert h2[:5] == hdr[:5] and [x - INSERT for x in h2[5:]] == hdr[5:]
    return out


def main():
    args = sys.argv[1:]
    if not 1 <= len(args) <= 2:
        raise SystemExit(__doc__)
    base = Path(args[0]).resolve()
    new = Path(args[1]).resolve() if len(args) == 2 else base
    if new is not base: check_id_length(new.name)
    src = base / REL
    data = src.read_bytes()
    got = sha(data)
    if got == ORIG_SHA:
        out = patch(data)
    else:
        try:
            p = parse(data)[1]
            already = read_arr(
                data, p, struct.unpack_from('<I', data, cal_pos(p, CAL_KOREA) + 0x10)[0]) == [ERA]
        except Exception:
            already = False
        if already:
            print('locale.nls already patched; nothing to do')
            return
        raise SystemExit('refusing: locale.nls sha256 %s is not the expected base %s' % (got, ORIG_SHA))
    out_sha = sha(out)
    if new != base:
        if new.exists():
            raise SystemExit('destination exists: %s' % new)
        subprocess.run(['cp', '-c', '-R', str(base), str(new)], check=True)
    dst = new / REL
    tmp = dst.with_name(dst.name + '.tmp')
    tmp.write_bytes(out)
    os.chmod(tmp, 0o644)
    os.replace(tmp, dst)
    assert sha(dst.read_bytes()) == out_sha
    if new != base:
        base_id = (base / 'BUILD-ID').read_text().strip()
        (new / 'BUILD-ID').write_text(new.name + '\n')
        (new / 'NLS-PATCH.json').write_text(json.dumps({
            'build_id': new.name,
            'base_build_id': base_id,
            'change': 'locale.nls: calendar 5 (CAL_KOREA) era strings now "%s" instead of one empty string; '
                      '16 bytes inserted at the start of the charmaps section, header offsets for '
                      'charmaps/geoids/scripts advanced by 16' % ERA,
            'tool': 'tools/runtime/patch-locale-nls.py',
            'wine_commit': '6880117619afdf62b4ccc40a8c6268c86613131f',
            'original_locale_nls_sha256': got,
            'patched_locale_nls_sha256': out_sha,
            'modified_runtime_files': [REL, 'BUILD-ID'],
            'wine_loader_modified': False,
        }, indent=2, ensure_ascii=False) + '\n')
    print('patched %s\n  sha256 %s -> %s' % (dst, got, out_sha))


if __name__ == '__main__':
    main()
