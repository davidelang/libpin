# kit tests

Throwaway `--git-home` fixtures. No network.

```bash
./kit/tests/run.sh
```

Most cases run with `--no-bwrap --no-landlock` (deliberate off switches). Sandbox cases exercise real bwrap + Landlock when present; missing tools are reported and the run continues. `--require-bwrap` / `--require-landlock` (`--require-libpin` is the same as `--require-landlock`) stop if that protection is not available.

Test-only printers (not in `usage()`). The bwrap/Landlock checks still run, so invoke them with `--no-bwrap --no-landlock`. They never read a pin.

```bash
# exactly 8 words; GROUPS is one argument (quote it)
./kit/fetch-deps --no-bwrap --no-landlock \
  --print-host-perm-suggestions PATH KIND OWNER GROUP MODE AGENT GROUPS SETFACL_OK

# exactly 3 words; STDERR last, may be ""
./kit/fetch-deps --no-bwrap --no-landlock \
  --print-owner-host-perm PATH NAME STDERR
```

`KIND` is `ancestor`, `repo`, or `file`. `SETFACL_OK` is `0` or `1`. Fewer arguments is a usage error (exit 2).

The host-owned-by-another-user case (mode 700, a uid this process is not) is a manual probe at the end of `run.sh`.
