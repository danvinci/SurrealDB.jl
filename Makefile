# Local CI parity. Runs the suite in containers matching the CI matrix legs
# (same Julia + pinned SurrealDB image), so a green local run means a green CI
# run. Requires docker (OrbStack/Desktop). Pins mirror .github/workflows/test.yml.

JULIA   ?= 1.10
SURREAL ?= v3.1.2
WIRE    ?= cbor

.PHONY: test-ci test-ci-unit test-ci-all conformance

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

# Cross-SDK conformance against the pinned server (uses scripts/setup-server.sh).
conformance:
	bash scripts/run-conformance.sh
