# kit tests

Throwaway `--git-home` fixtures. No network.

```bash
./kit/tests/run.sh
```

Most cases run with `--no-bwrap --no-landlock`. Sandbox cases exercise real bwrap + Landlock.

The host-owned-by-another-user case needs `chown` and is a manual probe (see the comment at the end of `run.sh`).
