// Reverse-interop reader: Go reads records written by Julia
// (write_test_data_julia.jl) and asserts byte-equal expected values.
//
// Catches serialization drift between SurrealDB.jl and surrealdb-go
// independently of the Python reader — different SDK, different decoder
// path, different chance to surface encoding bugs.
//
// Run:
//
//	go run test/interop/read_test_data.go

package main

import (
	"context"
	"fmt"
	"os"
	"reflect"

	"github.com/surrealdb/surrealdb.go"
)

type fixture struct {
	Kind  string      `json:"kind"`
	Value interface{} `json:"value"`
}

func main() {
	url := getEnv("SURREALDB_URL", "ws://localhost:8000")
	ns := getEnv("SURREALDB_NS", "test")
	db := getEnv("SURREALDB_DB", "test")

	client, err := surrealdb.FromEndpointURLString(context.Background(), url)
	check(err, "connect")

	check(client.Use(context.Background(), ns, db), "use")

	_, err = client.SignIn(context.Background(), &surrealdb.Auth{
		Username: "root", Password: "root",
	})
	check(err, "signin")

	rows, err := surrealdb.Select[[]fixture](context.Background(), client, "interop_jl")
	check(err, "select interop_jl")

	if rows == nil || len(*rows) == 0 {
		fmt.Fprintln(os.Stderr, "ERROR: interop_jl table empty (run write_test_data_julia.jl first)")
		os.Exit(2)
	}

	byKind := map[string]fixture{}
	for _, r := range *rows {
		byKind[r.Kind] = r
	}

	expected := map[string]interface{}{
		"int_positive":   int64(12345),
		"int_negative":   int64(-67890),
		"float_simple":   3.14159,
		"string_ascii":   "hello world",
		"string_unicode": "αβγ ✓ 中文 🦀",
		"bool_true":      true,
		"bool_false":     false,
		// null_value: SurrealDB drops null fields; expect missing or nil.
		"array_int":   []interface{}{int64(1), int64(2), int64(3), int64(4), int64(5)},
		"array_mixed": []interface{}{int64(1), "two", 3.0, true, nil},
	}

	failures := []string{}
	for kind, want := range expected {
		row, ok := byKind[kind]
		if !ok {
			failures = append(failures, fmt.Sprintf("%s: row not found", kind))
			continue
		}
		if !valuesEqual(row.Value, want) {
			failures = append(failures, fmt.Sprintf("%s: expected %v (%T), got %v (%T)",
				kind, want, want, row.Value, row.Value))
		}
	}

	// null is special: stored as missing or as nil, both acceptable.
	if row, ok := byKind["null_value"]; ok && row.Value != nil {
		failures = append(failures, fmt.Sprintf("null_value: expected nil or absent, got %v", row.Value))
	}

	// nested_object: spot-check leaves.
	if row, ok := byKind["nested_object"]; ok {
		if outer, ok := row.Value.(map[string]interface{}); ok {
			if inner, ok := outer["outer"].(map[string]interface{}); ok {
				if arr, ok := inner["inner"].([]interface{}); ok {
					if len(arr) < 3 {
						failures = append(failures, fmt.Sprintf("nested_object: inner too short: %v", arr))
					} else if leaf, ok := arr[2].(map[string]interface{}); !ok || leaf["deep"] != "leaf" {
						failures = append(failures, fmt.Sprintf("nested_object: nested leaf drift: %v", arr[2]))
					}
				}
			}
		}
	} else {
		failures = append(failures, "nested_object: row not found")
	}

	if len(failures) > 0 {
		fmt.Fprintln(os.Stderr, "interop reverse (go): FAIL")
		for _, f := range failures {
			fmt.Fprintf(os.Stderr, "  - %s\n", f)
		}
		os.Exit(1)
	}

	fmt.Fprintf(os.Stderr, "interop reverse (go): OK (%d fixtures verified)\n", len(expected)+1)
}

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func check(err error, op string) {
	if err != nil {
		fmt.Fprintf(os.Stderr, "FAIL: %s: %v\n", op, err)
		os.Exit(1)
	}
}

// valuesEqual is a recursive equality that tolerates integer-type drift
// across SDKs (int vs int64 vs uint64 vs float64-from-JSON). The Go SDK's
// CBOR/JSON path can decode SurrealDB ints to any of these depending on
// magnitude and codec; reflect.DeepEqual rejects same-magnitude values
// with different concrete types, producing confusing "[1 2 3] == [1 2 3]"
// failures.
//
// Semantics: numerics compare by value; slices and maps recurse;
// everything else falls through to DeepEqual.
func valuesEqual(a, b interface{}) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	switch av := a.(type) {
	case []interface{}:
		bv, ok := b.([]interface{})
		if !ok || len(av) != len(bv) {
			return false
		}
		for i := range av {
			if !valuesEqual(av[i], bv[i]) {
				return false
			}
		}
		return true
	case map[string]interface{}:
		bv, ok := b.(map[string]interface{})
		if !ok || len(av) != len(bv) {
			return false
		}
		for k, va := range av {
			vb, present := bv[k]
			if !present || !valuesEqual(va, vb) {
				return false
			}
		}
		return true
	}
	if af, aok := toFloat(a); aok {
		if bf, bok := toFloat(b); bok {
			return af == bf
		}
	}
	return reflect.DeepEqual(a, b)
}

func toFloat(x interface{}) (float64, bool) {
	switch v := x.(type) {
	case int:
		return float64(v), true
	case int32:
		return float64(v), true
	case int64:
		return float64(v), true
	case uint:
		return float64(v), true
	case uint32:
		return float64(v), true
	case uint64:
		return float64(v), true
	case float32:
		return float64(v), true
	case float64:
		return v, true
	}
	return 0, false
}
