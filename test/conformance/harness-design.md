# Conformance-harness design — Julia SDK vs upstream language-tests

Question (b): how does the Julia SDK stay synced with the Rust SDK as both evolve?

## Layout

```
<sdk-root>/
  test/
    conformance/
      runtests.jl              # Pkg-test entry: dispatches phase-1 + phase-2
      Project.toml             # Pinned deps: TOML stdlib + SurrealDB
      runner.jl                # Phase-1 corpus runner (this scratch's probe_runner.jl, hardened)
      wire/                    # Phase-2 hand-translated wire tests
        signin_signup.jl
        crud.jl
        live.jl
        ...
      pinned.toml              # Upstream commit/tag + corpus subset
      coverage.toml            # 33-RPC-method matrix (see below)
      README.md                # Maintainer guide
```

`external/upstream/` is the read-only upstream checkout (clone via `bash scripts/setup-upstream.sh`). The runner discovers tests via `external/upstream/language-tests/tests/`.

## Upstream-version pinning

`test/conformance/pinned.toml`:

```toml
[upstream]
repo   = "https://github.com/surrealdb/surrealdb"
commit = "<sha-of-language-tests/ at last-known-good>"
tag    = "v3.0.4"                # human reference; commit is authoritative

[corpus]
included = [
  "language/",
  "reproductions/",
]
excluded = [
  # Tests known to require server features we don't gate (e.g. TiKV, MVCC).
  "language/api/",               # HTTP API tests — Rust-specific
  "upgrade/",                    # cross-version upgrade tests
]

[skip]
# Per-file skips with rationale. Reviewed each upstream bump.
"language/functions/method_syntax.surql" = "v3.0.4 server bug; tracked upstream-issue NNN"
```

Bump procedure: `make conformance-bump` script does `git -C external/upstream fetch && checkout <new-tag>`, runs the full conformance suite, and diffs the result table against the previous run. The maintainer reviews delta before merging the pin update.

## Discovery / running

`runner.jl` is the hardened version of `probe_runner.jl`:
- TOML extraction from `//!` and `/** */` comments (already implemented).
- `[env]` honoring: `namespace`, `database` (with the override discipline tightened so probes don't leak unique names into expected-value comparisons), `imports` (sequentially run as root before the test), `versioned`, `auth`, `signin`/`signup` (signin/signup must run; matters for ~10% of corpus that defines record-access tests).
- Roughly-eq engine mirroring `cmp.rs` (skip-datetime, skip-record-id-key, skip-uuid, float / decimal roughly-eq) — already implemented in the probe.
- Parsing-error result-class: compare error text by substring, not boolean only.
- Match-expression result-class: evaluate the match expression server-side with `LET $result = <actual>; RETURN <match-expr>`.

## CI

**Recommendation: yes, run on CI** as a non-blocking gate first (warn-only), then promote to blocking once stable.

Justification:
- Sample pass rate is 86% out-of-the-box, and the failures are mostly probe gaps, not SDK bugs. The signal-to-noise is already strong enough to ship.
- 1172 + 123 = 1295 corpus files × ~50 ms per test (estimated from probe sample) ≈ 65 s of wall-clock with serial execution. Parallelizable by namespace isolation; with 4-way parallelism, ~16 s. Fits comfortably in a `julia --project=conformance test/conformance/runtests.jl` step.
- CI must include the `surreal` CLI in the test environment (already a binary install on macOS/Linux runners).

GitHub Actions matrix: `conformance.yml` × {server v3.0.4, latest-rc} × {wire :json, :cbor} × {transport :ws, :http}. HTTP cells skip the live-query subtests via the existing `UnsupportedFeatureError` path.

## RPC-method coverage matrix

Tracked separately in `test/conformance/coverage.toml`:

```toml
# 33 valid methods (surrealdb-core/src/rpc/method.rs minus Unknown).
# `implemented` = SDK has a public function or method that dispatches the RPC.
# `tested` = at least one wire-probe test in test/conformance/wire/ exercises it.

[ping]            ; implemented = true ; tested = true   # via ping_interval loop
[info]            ; implemented = true ; tested = false  # gap
[use]             ; implemented = true ; tested = true
[signup]          ; implemented = true ; tested = true
[signin]          ; implemented = true ; tested = true
[authenticate]    ; implemented = true ; tested = true
[refresh]         ; implemented = true ; tested = false  # gap (typed Tokens, May 22)
[invalidate]      ; implemented = true ; tested = true
[revoke]          ; implemented = false; tested = false  # SDK gap
[reset]           ; implemented = false; tested = false  # SDK gap
[kill]            ; implemented = true ; tested = true
[live]            ; implemented = true ; tested = true
[set]             ; implemented = true ; tested = false  # gap (`let!`)
[unset]           ; implemented = true ; tested = false  # gap
[select]          ; implemented = true ; tested = true
[insert]          ; implemented = true ; tested = false  # gap
[create]          ; implemented = true ; tested = true
[upsert]          ; implemented = true ; tested = false  # gap
[update]          ; implemented = true ; tested = false  # gap
[merge]           ; implemented = true ; tested = true
[patch]           ; implemented = true ; tested = false  # gap
[delete]          ; implemented = true ; tested = false  # gap
[version]         ; implemented = true ; tested = true   # smoke-test
[query]           ; implemented = true ; tested = true
[relate]          ; implemented = true ; tested = false  # gap
[run]             ; implemented = true ; tested = false  # gap
[insert_relation] ; implemented = true ; tested = false  # gap
[attach]          ; implemented = true ; tested = false  # gap
[sessions]        ; implemented = true ; tested = false  # gap
[detach]          ; implemented = true ; tested = false  # gap
[begin]           ; implemented = true ; tested = true   # via transaction tests
[commit]          ; implemented = true ; tested = true
[cancel]          ; implemented = true ; tested = true
```

Today: **31/33 implemented (94%)**, **14/33 wire-tested (42%)**. Missing SDK methods: `revoke`, `reset` (both added to Rust core after the SDK's v3 alignment work). Reaching 100% wire coverage = ~20 small tests.

## Lifecycle: upstream evolves

Four scenarios, each with a defined behavior:

### 1. Upstream adds a new test
Default behavior: silent pass-or-fail on next `pinned.toml` bump. Discovery scans `language-tests/tests/`, picks up the new file, attempts to run it. If it fails, the maintainer triages (see workflow below). The default is loud: every new corpus entry surfaces in the next CI run after a bump.

### 2. Upstream changes an expected value
Detected by the diff against the previous run's per-test status table. If a previously-passing test now fails, the maintainer's first action is to look at the upstream commit for that file — git blame the change to the expected value, read the linked issue/PR, and decide whether this is (a) a legitimate behavior change the SDK must match, or (b) a server regression to skip.

### 3. Upstream renames a TOML field
Harness break — the new field is `_unused_keys` to TOML.parse, but the runner won't know to read it. Detection: when the `interpret_config` function sees an unfamiliar config shape, fall through to a "skip with diagnostic" mode rather than silently ignoring. Add the new field handler in the next probe-runner edit.

### 4. Upstream removes a feature the Julia SDK still supports
Lower urgency, but worth catching. The conformance suite proves SurrealQL parity, not API surface — additional API tests in `test/integration/` already exercise the SDK's full surface. Coverage matrix flags any drift.

## Failure-triage decision tree

When a conformance test fails:

```
Did the test pass on the previous pinned upstream?
├── No  → "Was never working" — add to [skip] in pinned.toml with rationale.
└── Yes → "Regression" — find the cause.
    │
    Did anything in the Julia SDK change since the previous run?
    ├── No  → Server / upstream regression. File issue upstream; skip with link.
    └── Yes → Bisect the SDK commits against this single test. If a Julia commit
              introduced the failure, it's a real SDK bug — fix it.
```

Two-level diagnostic. The runner output preserves the per-test status from the previous run (committed as `test/conformance/.last_results.json`) so the diff is mechanical, not from-memory.

## Maintenance posture

- **Pull upstream cadence**: monthly, or on demand when upstream cuts a tagged release. Lower cadence is fine — the SDK isn't tracking upstream master, only released versions.
- **What to do when a new TOML field appears**: read its schema definition (`language-tests/src/tests/schema/mod.rs`), decide whether the field matters for Julia conformance (e.g. `versioned` does; `planner-strategy` doesn't because it's a server-side execution choice), and either implement support or document the silent-skip in the runner.
- **Who authorizes a version bump**: the conformance test must show no new failures, OR the new failures must be classified (server bug, harness gap, SDK gap) and the SDK-gap subset fixed in the same PR. No bumps with unresolved SDK gaps.

## Cost summary

| Item | Effort |
|---|---|
| Land `test/conformance/runner.jl` from `probe_runner.jl` + hardening | 1 session |
| Hand-translate 33 wire tests (one per RPC method) for 100% coverage | 1-2 sessions |
| Add `imports`, `versioned`, `auth`, `signin`/`signup` env plumbing | 1 session |
| Add match-expression server-side eval | 0.5 session |
| Wire into CI as warn-only, then promote to blocking | 0.5 session |
| Total to 100% conformance machinery | **~5 sessions** |
