# examples

Documentation templates for common pin shapes. Runnable copies for smoke tests also live under `../kit/` next to the tools.

| Example | Kind | Runnable path |
|---------|------|---------------|
| [files-pin/](files-pin/) | Non-git `[[source]]` | `kit/files-pin/` |
| (git toy) | Seed git + patch + build | `kit/example/` |

Copy into a consumer `third_party/` alongside the kit tools, then:

```bash
./fetch-deps ro files-pin
```
