## What & why

<!-- One or two sentences. The PR title becomes the squash-commit
     subject on main, so make it imperative and specific. -->

## Checklist

- [ ] `tools/lint.sh` passes
- [ ] `native test` passes
- [ ] `native check --strict` passes
- [ ] `tools/verify.sh` run locally against a live `native dev -Dautomation=true`
      — or N/A because: <!-- e.g. docs-only -->
- [ ] Behavior change ⇒ test added/extended in `src/tests.zig`
- [ ] API/behavior change ⇒ version bumped in **both** `app.zon` and
      `src/server.zig` openapi (lint enforces they match)
- [ ] Docs updated where they'd otherwise go stale (README,
      `agents_md`/`llms_txt`/`openapi_json` in-code docs — the drift
      tests catch routes, not prose)
