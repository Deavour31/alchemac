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

Apply with `git -C hadron apply alchemac-hadron.patch`, then build the runtime as Hadron
documents. Hadron and each component keep their own licenses.
