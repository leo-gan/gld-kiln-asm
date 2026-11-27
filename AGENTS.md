# Repository Agent Rules (`gld-kiln-asm`)

## Mandatory Release Policy on Version Bump

Whenever the project version in `VERSION` is bumped:

1. Update the version consistently in all locations:
   - `VERSION`
   - `include/kiln_asm.h` (`KILN_ASM_VERSION`)
   - `arch/x86_64/abi_c.s` (`.Lver_str`)
   - `docs/index.md`
   - `docs/asm/api.md`
2. Run `./scripts/run-tests.sh` and merge the PR into `main` with all CI checks green.
3. **Mandatory:** Immediately publish the matching GitHub Release on `main` using the exact `VERSION` string as both tag and title (no `v` prefix, e.g., `0.2.0`), e.g.:
   ```bash
   gh release create "<VERSION>" --target main --title "<VERSION>" --notes "..."
   ```
4. Wait for `.github/workflows/publish.yml` to finish and verify via `gh release view <VERSION>` that all release assets (`libkiln_asm.a`, `libkiln_asm.so`, `kiln_asm.h`, `kiln_bench_nolibc`, `gld_kilngen_asm.py`, `SHA256SUMS`) are attached.

## Internal Docs

- Keep working design and planning notes inside `docs/internal/`, which is gitignored and excluded from MkDocs (`mkdocs.yml` `exclude_docs`). Never force-add `docs/internal/` to git.
