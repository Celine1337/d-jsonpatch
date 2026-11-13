#!/usr/bin/env bash
# Self-contained test suite for d-jsonpatch. Requires the LDC (D) compiler.
set -uo pipefail
cd "$(dirname "$0")"
export TC="$HOME/.local/toolchains"
export PATH="$TC/ldc/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
command -v ldc2 >/dev/null 2>&1 || { echo "FAIL: ldc2 not found"; exit 1; }
./build.sh >/dev/null
BIN="./bin/d-jsonpatch"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); }
bad(){ fail=$((fail+1)); echo "FAIL: $1"; }
# exact output + exit code
checkeq(){ # name expected_exit expected_exact actual_exit actual_out
  local name="$1" want_rc="$2" want="$3" rc="$4" out="$5"
  if [ "$rc" != "$want_rc" ]; then bad "$name (exit $rc, want $want_rc)"; return; fi
  if [ "$out" != "$want" ]; then bad "$name (output '$out', want '$want')"; return; fi
  ok
}
# substring on output + exit code
check(){ # name expected_exit expected_substring actual_exit actual_out
  local name="$1" want_rc="$2" want="$3" rc="$4" out="$5"
  if [ "$rc" != "$want_rc" ]; then bad "$name (exit $rc, want $want_rc)"; return; fi
  if [ -n "$want" ] && ! printf '%s' "$out" | grep -qF -- "$want"; then
    bad "$name (output missing '$want')"; return
  fi
  ok
}

cat > "$TMP/doc.json" <<'EOF'
{"a":1,"b":{"c":"x"},"arr":[1,2,3]}
EOF
cat > "$TMP/doc2.json" <<'EOF'
{"a/b":1,"c~d":2}
EOF
cat > "$TMP/doc3.json" <<'EOF'
{"b":1,"a":2}
EOF

# empty patch -> deterministic sorted-key output
printf '[]' > "$TMP/p.json"
out=$($BIN "$TMP/doc.json" "$TMP/p.json"); rc=$?
checkeq "empty patch sorts keys" 0 '{"a":1,"arr":[1,2,3],"b":{"c":"x"}}' "$rc" "$out"

printf '[{"op":"add","path":"/d","value":42}]' > "$TMP/p.json"
out=$($BIN "$TMP/doc.json" "$TMP/p.json"); rc=$?
checkeq "add object key" 0 '{"a":1,"arr":[1,2,3],"b":{"c":"x"},"d":42}' "$rc" "$out"

printf '[{"op":"replace","path":"/a","value":9}]' > "$TMP/p.json"
out=$($BIN "$TMP/doc.json" "$TMP/p.json"); rc=$?
checkeq "replace value" 0 '{"a":9,"arr":[1,2,3],"b":{"c":"x"}}' "$rc" "$out"

printf '[{"op":"remove","path":"/b"}]' > "$TMP/p.json"
out=$($BIN "$TMP/doc.json" "$TMP/p.json"); rc=$?
checkeq "remove object key" 0 '{"a":1,"arr":[1,2,3]}' "$rc" "$out"

printf '[{"op":"add","path":"/arr/1","value":99}]' > "$TMP/p.json"
out=$($BIN "$TMP/doc.json" "$TMP/p.json"); rc=$?
checkeq "add at array index" 0 '{"a":1,"arr":[1,99,2,3],"b":{"c":"x"}}' "$rc" "$out"

printf '[{"op":"add","path":"/arr/-","value":4}]' > "$TMP/p.json"
out=$($BIN "$TMP/doc.json" "$TMP/p.json"); rc=$?
checkeq "append with dash" 0 '{"a":1,"arr":[1,2,3,4],"b":{"c":"x"}}' "$rc" "$out"

printf '[{"op":"remove","path":"/arr/0"}]' > "$TMP/p.json"
out=$($BIN "$TMP/doc.json" "$TMP/p.json"); rc=$?
checkeq "remove array element" 0 '{"a":1,"arr":[2,3],"b":{"c":"x"}}' "$rc" "$out"

printf '[{"op":"move","from":"/a","path":"/z"}]' > "$TMP/p.json"
out=$($BIN "$TMP/doc.json" "$TMP/p.json"); rc=$?
checkeq "move key" 0 '{"arr":[1,2,3],"b":{"c":"x"},"z":1}' "$rc" "$out"

printf '[{"op":"copy","from":"/b","path":"/b2"}]' > "$TMP/p.json"
out=$($BIN "$TMP/doc.json" "$TMP/p.json"); rc=$?
checkeq "copy object" 0 '{"a":1,"arr":[1,2,3],"b":{"c":"x"},"b2":{"c":"x"}}' "$rc" "$out"

printf '[{"op":"test","path":"/a","value":1},{"op":"add","path":"/ok","value":true}]' > "$TMP/p.json"
out=$($BIN "$TMP/doc.json" "$TMP/p.json"); rc=$?
checkeq "test passes then add" 0 '{"a":1,"arr":[1,2,3],"b":{"c":"x"},"ok":true}' "$rc" "$out"

printf '[{"op":"test","path":"/a","value":1.0}]' > "$TMP/p.json"
out=$($BIN "$TMP/doc.json" "$TMP/p.json"); rc=$?
checkeq "test numeric cross-type" 0 '{"a":1,"arr":[1,2,3],"b":{"c":"x"}}' "$rc" "$out"

printf '[{"op":"add","path":"/b/new","value":"y"}]' > "$TMP/p.json"
out=$($BIN "$TMP/doc.json" "$TMP/p.json"); rc=$?
checkeq "nested add" 0 '{"a":1,"arr":[1,2,3],"b":{"c":"x","new":"y"}}' "$rc" "$out"

# pointer escapes ~1 -> / and ~0 -> ~
printf '[{"op":"test","path":"/a~1b","value":1},{"op":"replace","path":"/c~0d","value":3}]' > "$TMP/p.json"
out=$($BIN "$TMP/doc2.json" "$TMP/p.json"); rc=$?
checkeq "pointer escapes" 0 '{"a/b":1,"c~d":3}' "$rc" "$out"

# replace the whole root document
printf '[{"op":"replace","path":"","value":[1,2]}]' > "$TMP/p.json"
out=$($BIN "$TMP/doc.json" "$TMP/p.json"); rc=$?
checkeq "replace root" 0 '[1,2]' "$rc" "$out"

# determinism: unsorted input keys come out sorted
printf '[]' > "$TMP/p.json"
out=$($BIN "$TMP/doc3.json" "$TMP/p.json"); rc=$?
checkeq "deterministic key order" 0 '{"a":2,"b":1}' "$rc" "$out"

# --- failure cases: exit 1, error on stderr, NO result on stdout ---
printf '[{"op":"test","path":"/a","value":2}]' > "$TMP/p.json"
out=$($BIN "$TMP/doc.json" "$TMP/p.json" 2>"$TMP/err"); rc=$?
err=$(cat "$TMP/err")
if [ "$rc" = 1 ] && [ -z "$out" ] && printf '%s' "$err" | grep -qF "test failed"; then ok; else bad "failed test exits 1 with no output"; fi

printf '[{"op":"remove","path":"/nope"}]' > "$TMP/p.json"
out=$($BIN "$TMP/doc.json" "$TMP/p.json" 2>&1); rc=$?
check "invalid path exits 1" 1 "path not found" "$rc" "$out"

printf '[{"op":"remove","path":"/arr/9"}]' > "$TMP/p.json"
out=$($BIN "$TMP/doc.json" "$TMP/p.json" 2>&1); rc=$?
check "array index out of bounds" 1 "out of bounds" "$rc" "$out"

printf '[{"op":"move","from":"/b","path":"/b/child"}]' > "$TMP/p.json"
out=$($BIN "$TMP/doc.json" "$TMP/p.json" 2>&1); rc=$?
check "move into own child" 1 "own child" "$rc" "$out"

printf '{"not":"an array"}' > "$TMP/p.json"
out=$($BIN "$TMP/doc.json" "$TMP/p.json" 2>&1); rc=$?
check "patch must be array" 1 "must be a JSON array" "$rc" "$out"

printf '{bad json' > "$TMP/bad.json"
out=$($BIN "$TMP/bad.json" "$TMP/p.json" 2>&1); rc=$?
check "malformed doc exits 1" 1 "invalid JSON" "$rc" "$out"

# --- usage / file errors: exit 2 ---
out=$($BIN "$TMP/missing.json" "$TMP/p.json" 2>/dev/null); rc=$?
check "missing doc exits 2" 2 "" "$rc" "$out"

out=$($BIN 2>/dev/null); rc=$?
check "no args exits 2" 2 "" "$rc" "$out"

echo "----------------------------------------"
echo "d-jsonpatch: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && echo "ALL CHECKS PASSED" || exit 1