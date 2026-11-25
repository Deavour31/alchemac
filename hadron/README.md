# Hadron changes

Alchemac runs on the Hadron runtime, release 0.3.0
(https://github.com/Broyojo/hadron, commit `2faae2af7dbcd0b6448bea5c86c20c33548a792c`).

`alchemac-hadron.patch` is every change Alchemac makes to that checkout:

- `scripts/standalone-run`, `standalone-common.sh`, `prefix-init.sh`: start any Windows
  program in its own Wine prefix without Steam, with per-prefix locking, private runtime
  copies and a watchdog scoped to that prefix (see `docs/standalone.md`).
- Small changes to `paths.sh`, `play`, `stop`, `watchdog`, `hadron-procs.sh` and
  `runtime-versions.sh` so those tools stay within one prefix.
- `patches/fex/0006-…`: FEX cooperative suspension on conditional backedges. It fixes
  programs that hang while another thread suspends a JIT thread in a tight loop. This
  patch is kept downstream and is not submitted to FEX.
- Wine locale data fix, applied to a built runtime by `tools/runtime/patch-locale-nls.py`:
  `nls/locale.nls` listed an empty era name for the Korean calendar, where Windows returns
  the Dangi era name. Delphi-built programs crash at startup in a Korean locale because of
  it. The script inserts the name (16 bytes) and checks the result by re-parsing the file.
- `patches/mtld3d/0004-…` to `0006-…`: three fixes to mtld3d's Direct3D 9 layer that
  WPF hardware rendering needs: reading back a render target or back buffer through
  `GetDC` when it is not lockable, keeping an additional swap chain's back buffer alive
  while the application still holds it, and renaming a contended staging resource before
  `UpdateSurface` and fill writes.
- `patches/mtld3d/0007-…`: lets the 32-bit (i686) `d3d9.dll` link against llvm-mingw's CRT
  instead of the MSVC CRT (no MSVC libraries or xwin needed), as the ARM64X one already does:
  it supplies the CRT pieces MSVC would (`__fltused`, `__tls_array`, the `type_info` vtable,
  the thread-exit TLS callback) under `--cfg mtld3d_mingw_crt`; the upstream MSVC build is
  unchanged. Only the native `d3d9.dll` files change. Build both without a Wine tree with
  `tools/runtime/build-mtld3d-d3d9.sh` and put them into a runtime with
  `tools/runtime/patch-mtld3d-d3d9.py [--i386 <i386-d3d9.dll>] <runtime> <new-runtime> d3d9.dll <patch>...`
  (`mtld3d.dll` and `mtld3d.so` are not rebuilt).
- `patches/wine/0050-…`: Wine's `win32u` now makes a window a real child of its parent when a
  `WH_CBT` hook turns an owned top-level window into a child while it is being created
  (as MFC dialogs do), like Windows. Before, the window stayed top-level with `WS_CHILD` set and
  the coordinates the program computed were wrong, so nested dialogs collapsed or were
  misplaced. Rebuild `win32u.so` from the Wine tree and put it into a runtime with
  `tools/runtime/patch-wine-unix-lib.py <runtime> <new-runtime> win32u.so <patch>...`.
- `patches/wine/0030-…` to `0049-…` (except 0037, 0039, 0043, 0046 and 0047) and `patches/fex/0007-…`:
  fixes taken from later Hadron releases, unchanged: freeing and reserving memory correctly in
  emulated processes (`MEM_DECOMMIT`/`MEM_RELEASE`, neighbouring pages, top-down allocations
  above 4 GB), loading images with shared sections, recovering from repeated stack overflows,
  IME detection, no visible window while `wineboot` updates a prefix, a Retina-mode screen size fix,
  a Metal swap chain leak, a thread-pool timeout, and a FEX crash in CPUID handling. 0043 and
  0046 are left out because they change the signed `wine` loader or switch the OpenGL renderer;
  0037 changes the default Retina behaviour. 0030 to 0033 and 0045 are included: a program that
  asks for another display mode now renders at that mode and its window is scaled to the display
  (emulated mode changes, with the related multi-display fixes) instead of changing the real mode.
  0039 and 0047 (Retina-mode cursor size and raw mouse movement in points) are kept in
  `patches/wine-excluded/` and not applied: Alchemac combines RetinaMode with 192 DPI, where 0039
  draws cursors at twice their size and 0047 halves raw mouse movement.
- Wine and FEX libraries rebuilt from these trees are put into a runtime with
  `tools/runtime/patch-runtime-files.py <runtime> <new-runtime> --file <built-file> <runtime-relative-path>... --patch <patch>...`.
  It strips build paths, checks each file's architecture against the one it replaces, never
  touches a file inside an `.app` bundle, and records the change in `RUNTIME-PATCH.json` and
  `BUILD-LINEAGE.json`.

Apply with `git -C hadron apply alchemac-hadron.patch`, then build the runtime as Hadron
documents. Hadron and each component keep their own licenses.
