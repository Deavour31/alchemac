#!/usr/bin/env python3
"""Copies the publishable Alchemac source into a separate folder for its public repository.

Only files listed here are copied, so game files, accounts, logs, keys and the
investigation workspace can never be published by accident. The copy is then
scanned for this machine's paths and account-like values before it is accepted.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
DEST = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'release/alchemac'
HADRON = ROOT / 'src/hadron'
HADRON_BASE = '2faae2af7dbcd0b6448bea5c86c20c33548a792c'
# Spelled in pieces so this file does not match its own check.
PROGRAM_NAMES = 'dur' + 'ango|듀' + '랑고'

FILES = {
    'README.md': 'app/alchemac/README.md',
    'LICENSE': 'app/alchemac/LICENSE',
    'config/alchemac.json': 'config/alchemac.json',
    'scripts/build-alchemac-app.py': 'scripts/build-alchemac-app.py',
    'scripts/export-alchemac-repo.py': 'scripts/export-alchemac-repo.py',
    'tools/app/make-icon.swift': 'tools/app/make-icon.swift',
    'tools/app/SelfTests.swift': 'tools/app/SelfTests.swift',
    'tools/app/request-close.swift': 'tools/app/request-close.swift',
}
APP_SOURCES = ['main.swift', 'App.swift', 'Runtime.swift', 'SessionController.swift', 'Profile.swift',
               'InputSource.swift', 'Addon.swift', 'prefix-profile.c', 'session-attach', 'README.md', 'LICENSE']

HADRON_README = f"""# Hadron changes

Alchemac runs on the Hadron runtime, release 0.3.0
(https://github.com/Broyojo/hadron, commit `{HADRON_BASE}`).

`alchemac-hadron.patch` is every change Alchemac makes to that checkout:

- `scripts/standalone-run`, `standalone-common.sh`, `prefix-init.sh`: start any Windows
  program in its own Wine prefix without Steam, with per-prefix locking, private runtime
  copies and a watchdog scoped to that prefix (see `docs/standalone.md`).
- Small changes to `paths.sh`, `play`, `stop`, `watchdog`, `hadron-procs.sh` and
  `runtime-versions.sh` so those tools stay within one prefix.
- `patches/fex/0006-…`: FEX cooperative suspension on conditional backedges. It fixes
  programs that hang while another thread suspends a JIT thread in a tight loop. This
  patch is kept downstream and is not submitted to FEX.

Apply with `git -C hadron apply alchemac-hadron.patch`, then build the runtime as Hadron
documents. Hadron and each component keep their own licenses.
"""

GITIGNORE = """.DS_Store
build/
outputs/
work/
*.dmg
*.app/
*.log
offserver*.txt
*.jks
keystore/
"""


def hadron_patch():
    run = lambda *a: subprocess.run(['git', '-C', str(HADRON), *a], check=True, capture_output=True, text=True).stdout
    if run('rev-parse', 'HEAD').strip() != HADRON_BASE:
        raise SystemExit('src/hadron is not at the Hadron 0.3.0 base commit')
    patch = run('diff', '--binary', HADRON_BASE)
    for name in run('ls-files', '--others', '--exclude-standard').splitlines():
        # git diff --no-index exits 1 when files differ, which they always do here.
        patch += subprocess.run(['git', '-C', str(HADRON), 'diff', '--binary', '--no-index', '/dev/null', name],
                                capture_output=True, text=True).stdout
    return patch


def scan(folder):
    problems = []
    home = str(Path.home())
    uuid = re.compile(r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', re.I)
    for path in folder.rglob('*'):
        if not path.is_file() or '.git' in path.parts:
            continue
        text = path.read_text(errors='ignore')
        if home in text:
            problems.append(f'{path.relative_to(folder)}: contains {home}')
        # Program-specific support ships as add-ons, never in the app repository.
        if re.search(PROGRAM_NAMES, text, re.I):
            problems.append(f'{path.relative_to(folder)}: names a specific program')
        if uuid.search(text):
            problems.append(f'{path.relative_to(folder)}: contains a UUID')
    return problems


def main():
    DEST.mkdir(parents=True, exist_ok=True)
    for child in DEST.iterdir():  # Replace the previous export, keeping the repository's .git.
        if child.name != '.git':
            shutil.rmtree(child) if child.is_dir() else child.unlink()
    for name, source in FILES.items():
        target = DEST / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / source, target)
    for name in APP_SOURCES:
        # Same layout as the workspace, so build-alchemac-app.py finds its sources.
        (DEST / 'app/alchemac').mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / 'app/alchemac' / name, DEST / 'app/alchemac' / name)
    (DEST / 'hadron').mkdir()
    (DEST / 'hadron/alchemac-hadron.patch').write_text(hadron_patch())
    (DEST / 'hadron/README.md').write_text(HADRON_README)
    (DEST / '.gitignore').write_text(GITIGNORE)
    problems = scan(DEST)
    if problems:
        print('\n'.join(problems))
        raise SystemExit('Export refused: remove personal data before publishing.')
    print(DEST)


if __name__ == '__main__':
    main()
