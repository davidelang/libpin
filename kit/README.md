# libpin kit — drop-in `third_party/` tooling

Copy or rsync this directory to your project’s `third_party/` (or use it in place for demos).

## Tools

| File | Role |
|------|------|
| `fetch-deps` | Materialize pins (git / `[[source]]` / seed-src), RO/RW, build, check, outdated |
| `get-artifacts` | Collect `[[artifact]]` rows from `libpin.toml` (required sha256) |
| `libpin-sandbox` | bwrap outer + Landlock inner (write-probe nest detection) |
| `libpin-bwrap` | bubblewrap helper |
| `libpin-landlock` | Landlock mutation confinement (Python) |
| `VERSION` | Companion stamp; must match the embedded `LIBPIN_VERSION` in every script |
| `tests/run.sh` | Throwaway `--git-home` fixtures |
| `hooks/pre-commit-git-home-leak` | Staged `libpin.toml` must not contain an expanded `GIT_HOME` |

## Bundled pins

| Dir | Purpose |
|-----|---------|
| `example/` | Toy git-style pin (seed-src, no network) |
| `files-pin/` | Minimal non-git `[[source]]` pin |

## Quick demo

```bash
cd "$(dirname "$0")"   # this kit directory
./fetch-deps ro example files-pin
./fetch-deps build example
cat example/artifact/hello.bin
cat files-pin/src/hello.txt
./libpin-landlock --status
./tests/run.sh
```

## Docs

See the parent repo:

- [../docs/QUICKSTART.md](../docs/QUICKSTART.md)
- [../docs/PIN_FORMAT.md](../docs/PIN_FORMAT.md)
- [../docs/SANDBOX.md](../docs/SANDBOX.md)
- [../docs/GUIDE.md](../docs/GUIDE.md)
- [../docs/CASE_STUDY_VEHICLEEXPENSES.md](../docs/CASE_STUDY_VEHICLEEXPENSES.md)

## Requirements

bash, python3 ≥ 3.11 (`tomllib` only), git (for git pins), curl. Sandbox: `bubblewrap` and a Landlock-capable kernel, or pass `--no-bwrap --no-landlock`.
