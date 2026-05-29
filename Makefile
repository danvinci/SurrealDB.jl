# Local CI parity. Runs the suite in containers matching the CI matrix legs
# (same Julia + pinned SurrealDB image), so a green local run means a green CI
# run. Requires docker (OrbStack/Desktop). Pins mirror .github/workflows/test.yml.

JULIA   ?= 1.10
SURREAL ?= v3.1.2
WIRE    ?= cbor

.PHONY: test-ci test-ci-unit test-ci-all test-embedded conformance

# Single server-gated leg. Override: make test-ci JULIA=1 SURREAL=v2.6.5 WIRE=json
test-ci:
	JULIA=$(JULIA) SURREAL=$(SURREAL) WIRE=$(WIRE) bash scripts/test-ci.sh remote

# Unit-only leg (no server); the version axis is what catches dep-resolve skew.
test-ci-unit:
	JULIA=$(JULIA) bash scripts/test-ci.sh unit

# Full server matrix, mirroring test.yml test-remote: {v2.6.5,v3.1.2} x {cbor,json}.
test-ci-all:
	JULIA=$(JULIA) SURREAL=v2.6.5 WIRE=cbor bash scripts/test-ci.sh remote
	JULIA=$(JULIA) SURREAL=v2.6.5 WIRE=json bash scripts/test-ci.sh remote
	JULIA=$(JULIA) SURREAL=v3.1.2 WIRE=cbor bash scripts/test-ci.sh remote
	JULIA=$(JULIA) SURREAL=v3.1.2 WIRE=json bash scripts/test-ci.sh remote

# Native-host embedded leg — mirrors CI's macos-latest embedded leg (macOS
# can't be containerized). Builds libsurrealdb_c if absent, re-develops onto the
# host path (the docker targets leave test/Manifest.toml pointing at the
# container's /work), then runs with the dylib auto-loaded and no server, so
# remote testsets self-skip and embedded runs. Linux/amd64 embedded waits on the
# libsurrealdb_c artifact (plans/ci-test-parity.md) — emulated builds are impractical.
test-embedded:
	@test -f deps/lib/libsurrealdb_c.dylib || julia --project=test deps/build_libsurreal.jl
	julia --project=test -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'
	env -u SURREALDB_URL julia --project=test test/runtests.jl

# Cross-SDK conformance against the pinned server (uses scripts/setup-server.sh).
conformance:
	bash scripts/run-conformance.sh
