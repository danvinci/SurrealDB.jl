"""
Reverse interop reader: Python reads records written by Julia
(`write_test_data_julia.jl`) and asserts byte-equal expected values.

Catches serialization drift in the Julia-side writer. Run after the Julia
writer has populated `interop_jl`.

Run:
    pip install surrealdb
    python test/interop/read_test_data.py
"""
import os
import sys
from surrealdb import Surreal

URL = os.environ.get("SURREALDB_URL", "ws://localhost:8000/rpc")
NS = os.environ.get("SURREALDB_NS", "test")
DB = os.environ.get("SURREALDB_DB", "test")

EXPECTED = {
    "int_positive":   12345,
    "int_negative":   -67890,
    "float_simple":   3.14159,
    "string_ascii":   "hello world",
    "string_unicode": "αβγ ✓ 中文 🦀",
    "bool_true":      True,
    "bool_false":     False,
    # null_value: SurrealDB drops null fields; expect missing or None.
    "array_int":      [1, 2, 3, 4, 5],
    "array_mixed":    [1, "two", 3.0, True, None],
}


def main():
    db = Surreal(URL)
    db.signin({"username": "root", "password": "root"})
    db.use(NS, DB)

    rows = db.select("interop_jl")
    if not rows:
        print("ERROR: interop_jl table empty (run write_test_data_julia.jl first)",
              file=sys.stderr)
        sys.exit(2)

    by_kind = {row.get("kind"): row for row in rows}

    failures = []
    for kind, expected in EXPECTED.items():
        if kind not in by_kind:
            failures.append(f"{kind}: row not found")
            continue
        actual = by_kind[kind].get("value")
        if actual != expected:
            failures.append(f"{kind}: expected {expected!r}, got {actual!r}")

    # null is a special case: SurrealDB drops null fields, so the value
    # key may be absent OR None.
    if "null_value" in by_kind:
        v = by_kind["null_value"].get("value")
        if v is not None:
            failures.append(f"null_value: expected None or absent, got {v!r}")

    # Nested object: spot-check leaves.
    if "nested_object" in by_kind:
        nested = by_kind["nested_object"].get("value", {})
        outer = nested.get("outer", {})
        inner = outer.get("inner", [])
        if len(inner) < 3 or inner[0] != 10 or inner[1] != 20:
            failures.append(f"nested_object: inner array drift: {inner!r}")
        elif not isinstance(inner[2], dict) or inner[2].get("deep") != "leaf":
            failures.append(f"nested_object: nested leaf drift: {inner[2]!r}")
    else:
        failures.append("nested_object: row not found")

    if failures:
        print("interop reverse: FAIL", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        sys.exit(1)

    print(f"interop reverse: OK ({len(EXPECTED) + 1} fixtures verified)",
          file=sys.stderr)


if __name__ == "__main__":
    main()
