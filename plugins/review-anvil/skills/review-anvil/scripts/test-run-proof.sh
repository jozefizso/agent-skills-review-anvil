#!/usr/bin/env bash
# Deterministic fixtures for the review-anvil proof runner boundary.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$ROOT/run-proof.sh"

fail() {
    printf 'test-run-proof: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local actual="$1" expected="$2" context="$3"
    [[ "$actual" == "$expected" ]] || \
        fail "$context: got '$actual', want '$expected'"
}

assert_contains() {
    local path="$1" needle="$2" context="$3"
    grep -Fq "$needle" "$path" || fail "$context: missing '$needle' in $path"
}

assert_file_missing() {
    local path="$1"
    [[ ! -e "$path" && ! -L "$path" ]] || fail "expected path to be absent: $path"
}

make_snapshot() {
    local path="$1"
    mkdir -p "$path"
    git -C "$path" init -q
    git -C "$path" config user.name 'Proof Test'
    git -C "$path" config user.email 'proof@example.invalid'
    printf 'reviewed\n' >"$path/source.txt"
    git -C "$path" add source.txt
    git -C "$path" commit -q -m snapshot
}

make_proof() {
    local path="$1"
    mkdir -p "$path"
    printf '{"protocol":1,"target":"RAV-R1-F001"}\n' >"$path/manifest.json"
    printf 'print("proof")\n' >"$path/probe.py"
}

write_runner() {
    local path="$1" network="${2:-disabled}" body="${3:-printf 'probe-ok\\n'}" reads="${4:-source-proof-runtime-only}" extra="${5:-}" capability_body="${6:-:}"
    [[ -z "$extra" ]] || extra=$'\n'"$extra"
    cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${REVIEW_ANVIL_PROOF_MODE:-}" == capabilities ]]; then
$capability_body
    cat <<'CAPS'
PROTOCOL=1
NETWORK=$network
SOURCE=read-only
PROOF_INPUTS=read-only
READS=$reads
WRITES=proof-runtime-only
RESULT=runner-authored
ENVIRONMENT=sanitized
RESOURCES=bounded$extra
CAPS
    exit 0
fi
$body
printf '{"protocol":1,"target":"RAV-R1-F001","status":"completed","probe_exit_code":0}\n' >"\$REVIEW_ANVIL_PROOF_RUNTIME/execution.json"
EOF
    chmod +x "$path"
}

run_wrapper() {
    local stdout_file="$1" stderr_file="$2"
    shift 2

    set +e
    "$HELPER" "$@" >"$stdout_file" 2>"$stderr_file"
    local status=$?
    set -e
    printf '%s' "$status"
}

test_valid_runner_gets_sanitized_environment() {
    local tmp snapshot snapshot_real proof proof_real runner result stdout stderr status
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    snapshot="$tmp/snapshot"
    proof="$tmp/proof"
    runner="$tmp/runner"
    result="$proof/result.env"
    stdout="$tmp/wrapper.out"
    stderr="$tmp/wrapper.err"
    make_snapshot "$snapshot"
    make_proof "$proof"
    write_runner "$runner" disabled \
        'printf "secret=%s\\nhome=%s\\nsource=%s\\nproof=%s\\nruntime=%s\\n" "${SECRET_TOKEN-unset}" "$HOME" "$REVIEW_ANVIL_SOURCE" "$REVIEW_ANVIL_PROOF_DIR" "$REVIEW_ANVIL_PROOF_RUNTIME"'

    SECRET_TOKEN=must-not-leak status="$(run_wrapper "$stdout" "$stderr" \
        "$result" 5 "$snapshot" "$proof" -- "$runner")"
    snapshot_real="$(cd "$snapshot" && pwd -P)"
    proof_real="$(cd "$proof" && pwd -P)"

    assert_eq "$status" "0" "valid runner exit"
    assert_contains "$stdout" "STATUS=ok" "valid runner status"
    assert_contains "$result" "STATUS=ok" "valid result"
    assert_contains "$result" "TREE_UNCHANGED=yes" "unchanged result"
    assert_contains "$result" "PROOF_UNCHANGED=yes" "immutable proof result"
    assert_contains "$result" "RUNTIME_REMOVED=yes" "runtime cleanup result"
    assert_contains "$result.stdout" "secret=unset" "sanitized environment"
    assert_contains "$result.stdout" "home=$proof_real/runtime/home" "isolated home"
    assert_contains "$result.stdout" "source=$snapshot_real" "source path"
    assert_contains "$result.stdout" "proof=$proof_real" "proof path"
    assert_contains "$result.stdout" "runtime=$proof_real/runtime" "runtime path"
    assert_file_missing "$proof/runtime"
    assert_eq "$(git -C "$snapshot" status --porcelain --untracked-files=all)" "" "snapshot status"
}

test_relative_runner_is_rejected() {
    local tmp snapshot proof result stdout stderr status
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    snapshot="$tmp/snapshot"
    proof="$tmp/proof"
    result="$proof/result.env"
    stdout="$tmp/wrapper.out"
    stderr="$tmp/wrapper.err"
    make_snapshot "$snapshot"

    status="$(run_wrapper "$stdout" "$stderr" "$result" 5 "$snapshot" "$proof" -- relative-runner)"

    assert_eq "$status" "2" "relative runner exit"
    assert_contains "$stderr" "runner command must be an absolute path" "relative runner error"
    assert_file_missing "$result"
}

test_runner_inside_snapshot_is_rejected() {
    local tmp snapshot proof runner result stdout stderr status
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    snapshot="$tmp/snapshot"
    proof="$tmp/proof"
    runner="$snapshot/runner"
    result="$proof/result.env"
    stdout="$tmp/wrapper.out"
    stderr="$tmp/wrapper.err"
    make_snapshot "$snapshot"
    write_runner "$runner"

    status="$(run_wrapper "$stdout" "$stderr" "$result" 5 "$snapshot" "$proof" -- "$runner")"

    assert_eq "$status" "2" "repository runner exit"
    assert_contains "$stderr" "runner command must be outside the source and proof directories" "repository runner error"
    assert_file_missing "$result"
}

test_incomplete_capabilities_are_rejected() {
    local tmp snapshot proof runner result stdout stderr status
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    snapshot="$tmp/snapshot"
    proof="$tmp/proof"
    runner="$tmp/runner"
    result="$proof/result.env"
    stdout="$tmp/wrapper.out"
    stderr="$tmp/wrapper.err"
    make_snapshot "$snapshot"
    make_proof "$proof"
    write_runner "$runner" enabled

    status="$(run_wrapper "$stdout" "$stderr" "$result" 5 "$snapshot" "$proof" -- "$runner")"

    assert_eq "$status" "3" "capability rejection exit"
    assert_contains "$stdout" "STATUS=capability-rejected" "capability rejection status"
    assert_contains "$result" "STATUS=capability-rejected" "capability rejection result"
    assert_file_missing "$result.stdout"
}

test_broad_read_capability_is_rejected() {
    local tmp snapshot proof runner result stdout stderr status
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    snapshot="$tmp/snapshot"
    proof="$tmp/proof"
    runner="$tmp/runner"
    result="$proof/result.env"
    stdout="$tmp/wrapper.out"
    stderr="$tmp/wrapper.err"
    make_snapshot "$snapshot"
    make_proof "$proof"
    write_runner "$runner" disabled 'printf probe-ok' all-files

    status="$(run_wrapper "$stdout" "$stderr" "$result" 5 "$snapshot" "$proof" -- "$runner")"

    assert_eq "$status" "3" "broad read capability exit"
    assert_contains "$stdout" "STATUS=capability-rejected" "broad read capability status"
    assert_contains "$result" "STATUS=capability-rejected" "broad read capability result"
}

test_contradictory_capabilities_are_rejected() {
    local tmp snapshot proof runner result stdout stderr status
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    snapshot="$tmp/snapshot"
    proof="$tmp/proof"
    runner="$tmp/runner"
    result="$proof/result.env"
    stdout="$tmp/wrapper.out"
    stderr="$tmp/wrapper.err"
    make_snapshot "$snapshot"
    make_proof "$proof"
    write_runner "$runner" disabled 'printf probe-ok' source-proof-runtime-only 'NETWORK=enabled'

    status="$(run_wrapper "$stdout" "$stderr" "$result" 5 "$snapshot" "$proof" -- "$runner")"

    assert_eq "$status" "3" "contradictory capability exit"
    assert_contains "$stdout" "STATUS=capability-rejected" "contradictory capability status"
}

test_proof_input_mutation_invalidates_result() {
    local tmp snapshot proof runner result stdout stderr status
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    snapshot="$tmp/snapshot"
    proof="$tmp/proof"
    runner="$tmp/runner"
    result="$proof/result.env"
    stdout="$tmp/wrapper.out"
    stderr="$tmp/wrapper.err"
    make_snapshot "$snapshot"
    make_proof "$proof"
    write_runner "$runner" disabled \
        'printf "{\"protocol\":1,\"target\":\"CHANGED\"}\n" >"$REVIEW_ANVIL_PROOF_DIR/manifest.json"'

    status="$(run_wrapper "$stdout" "$stderr" "$result" 5 "$snapshot" "$proof" -- "$runner")"

    assert_eq "$status" "6" "proof mutation exit"
    assert_contains "$stdout" "STATUS=proof-mutated" "proof mutation status"
    assert_contains "$result" "PROOF_UNCHANGED=no" "proof mutation result"
}

test_probe_result_symlink_cannot_overwrite_host_file() {
    local tmp snapshot proof runner result victim stdout stderr status
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    snapshot="$tmp/snapshot"
    proof="$tmp/proof"
    runner="$tmp/runner"
    result="$proof/result.env"
    victim="$tmp/victim"
    stdout="$tmp/wrapper.out"
    stderr="$tmp/wrapper.err"
    make_snapshot "$snapshot"
    make_proof "$proof"
    printf 'keep\n' >"$victim"
    write_runner "$runner" disabled \
        "ln -sf '$victim' \"\$REVIEW_ANVIL_PROOF_DIR/result.env\""

    status="$(run_wrapper "$stdout" "$stderr" "$result" 5 "$snapshot" "$proof" -- "$runner")"

    assert_eq "$status" "0" "result symlink exit"
    assert_eq "$(cat "$victim")" "keep" "result symlink victim"
    [[ -f "$result" && ! -L "$result" ]] || fail "result must replace a probe-created symlink"
}

test_snapshot_mutation_invalidates_result() {
    local tmp snapshot proof runner result stdout stderr status
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    snapshot="$tmp/snapshot"
    proof="$tmp/proof"
    runner="$tmp/runner"
    result="$proof/result.env"
    stdout="$tmp/wrapper.out"
    stderr="$tmp/wrapper.err"
    make_snapshot "$snapshot"
    make_proof "$proof"
    write_runner "$runner" disabled \
        'printf "mutated\\n" >"$REVIEW_ANVIL_SOURCE/source.txt"; printf "attempted mutation\\n"'

    status="$(run_wrapper "$stdout" "$stderr" "$result" 5 "$snapshot" "$proof" -- "$runner")"

    assert_eq "$status" "4" "mutation exit"
    assert_contains "$stdout" "STATUS=source-mutated" "mutation status"
    assert_contains "$result" "STATUS=source-mutated" "mutation result"
    assert_contains "$result" "TREE_UNCHANGED=no" "mutation tree result"
}

test_timeout_is_bounded() {
    local tmp snapshot proof runner result stdout stderr status
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    snapshot="$tmp/snapshot"
    proof="$tmp/proof"
    runner="$tmp/runner"
    result="$proof/result.env"
    stdout="$tmp/wrapper.out"
    stderr="$tmp/wrapper.err"
    make_snapshot "$snapshot"
    make_proof "$proof"
    write_runner "$runner" disabled 'exec sleep 5'

    status="$(run_wrapper "$stdout" "$stderr" "$result" 2 "$snapshot" "$proof" -- "$runner")"

    assert_eq "$status" "124" "timeout exit"
    assert_contains "$stdout" "STATUS=timeout" "timeout status"
    assert_contains "$result" "STATUS=timeout" "timeout result"
    assert_contains "$result" "TREE_UNCHANGED=yes" "timeout tree result"
    assert_contains "$result" "RUNTIME_REMOVED=yes" "timeout runtime cleanup"
}

test_term_trap_still_counts_as_timeout() {
    local tmp snapshot proof runner result stdout stderr status
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    snapshot="$tmp/snapshot"
    proof="$tmp/proof"
    runner="$tmp/runner"
    result="$proof/result.env"
    stdout="$tmp/wrapper.out"
    stderr="$tmp/wrapper.err"
    make_snapshot "$snapshot"
    make_proof "$proof"
    write_runner "$runner" disabled \
        'trap "exit 0" TERM; while :; do sleep 1; done'

    status="$(run_wrapper "$stdout" "$stderr" "$result" 2 "$snapshot" "$proof" -- "$runner")"

    assert_eq "$status" "124" "TERM-trapping timeout exit"
    assert_contains "$stdout" "STATUS=timeout" "TERM-trapping timeout status"
}

test_timeout_terminates_runner_descendants() {
    local tmp snapshot proof runner result survivor stdout stderr status
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    snapshot="$tmp/snapshot"
    proof="$tmp/proof"
    runner="$tmp/runner"
    result="$proof/result.env"
    survivor="$tmp/survivor"
    stdout="$tmp/wrapper.out"
    stderr="$tmp/wrapper.err"
    make_snapshot "$snapshot"
    make_proof "$proof"
    write_runner "$runner" disabled \
        "(trap '' TERM; sleep 8; printf survived >'$survivor') & wait"

    status="$(run_wrapper "$stdout" "$stderr" "$result" 2 "$snapshot" "$proof" -- "$runner")"
    sleep 1

    assert_eq "$status" "124" "descendant timeout exit"
    assert_file_missing "$survivor"
    assert_file_missing "$proof/runtime"
}

test_normal_exit_terminates_runner_descendants() {
    local tmp snapshot proof runner result survivor stdout stderr status
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    snapshot="$tmp/snapshot"
    proof="$tmp/proof"
    runner="$tmp/runner"
    result="$proof/result.env"
    survivor="$tmp/survivor"
    stdout="$tmp/wrapper.out"
    stderr="$tmp/wrapper.err"
    make_snapshot "$snapshot"
    make_proof "$proof"
    write_runner "$runner" disabled \
        "(trap '' TERM; sleep 1; printf survived >'$survivor') &"

    status="$(run_wrapper "$stdout" "$stderr" "$result" 5 "$snapshot" "$proof" -- "$runner")"
    sleep 2

    assert_eq "$status" "0" "normal descendant cleanup exit"
    assert_file_missing "$survivor"
    assert_file_missing "$proof/runtime"
}

test_runtime_special_entries_are_not_retained() {
    local tmp snapshot proof runner result victim stdout stderr status
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    snapshot="$tmp/snapshot"
    proof="$tmp/proof"
    runner="$tmp/runner"
    result="$proof/result.env"
    victim="$tmp/victim"
    stdout="$tmp/wrapper.out"
    stderr="$tmp/wrapper.err"
    make_snapshot "$snapshot"
    make_proof "$proof"
    printf 'keep\n' >"$victim"
    write_runner "$runner" disabled \
        "ln -s '$victim' \"\$REVIEW_ANVIL_PROOF_RUNTIME/absolute-link\"; mkfifo \"\$REVIEW_ANVIL_PROOF_RUNTIME/pipe\"; mkdir \"\$REVIEW_ANVIL_PROOF_RUNTIME/locked\"; chmod 000 \"\$REVIEW_ANVIL_PROOF_RUNTIME/locked\"; trap 'chmod 000 \"\$REVIEW_ANVIL_PROOF_RUNTIME\"' EXIT"

    status="$(run_wrapper "$stdout" "$stderr" "$result" 5 "$snapshot" "$proof" -- "$runner")"

    assert_eq "$status" "0" "special runtime entries exit"
    assert_eq "$(cat "$victim")" "keep" "special runtime victim"
    assert_file_missing "$proof/runtime"
    [[ -f "$proof/execution.json" && ! -L "$proof/execution.json" ]] || \
        fail "validated execution metadata was not retained safely"
}

test_phases_share_one_deadline() {
    local tmp snapshot proof runner result stdout stderr status
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    snapshot="$tmp/snapshot"
    proof="$tmp/proof"
    runner="$tmp/runner"
    result="$proof/result.env"
    stdout="$tmp/wrapper.out"
    stderr="$tmp/wrapper.err"
    make_snapshot "$snapshot"
    make_proof "$proof"
    write_runner "$runner" disabled 'sleep 3' source-proof-runtime-only '' 'sleep 1'

    status="$(run_wrapper "$stdout" "$stderr" "$result" 3 "$snapshot" "$proof" -- "$runner")"

    assert_eq "$status" "124" "shared phase deadline exit"
    assert_contains "$stdout" "STATUS=timeout" "shared phase deadline status"
}

test_output_size_is_bounded() {
    local tmp snapshot proof runner result stdout stderr status bytes
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    snapshot="$tmp/snapshot"
    proof="$tmp/proof"
    runner="$tmp/runner"
    result="$proof/result.env"
    stdout="$tmp/wrapper.out"
    stderr="$tmp/wrapper.err"
    make_snapshot "$snapshot"
    make_proof "$proof"
    write_runner "$runner" disabled \
        'dd if=/dev/zero bs=1048576 count=2 2>/dev/null'

    status="$(run_wrapper "$stdout" "$stderr" "$result" 5 "$snapshot" "$proof" -- "$runner")"
    bytes="$(wc -c <"$result.stdout" | tr -d ' ')"

    assert_eq "$status" "1" "oversized output exit"
    assert_contains "$stdout" "STATUS=failed" "oversized output status"
    [[ "$bytes" -le 1048576 ]] || \
        fail "oversized output exceeded 1048576 bytes: $bytes"
}

test_missing_manifest_is_rejected() {
    local tmp snapshot proof runner result stdout stderr status
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    snapshot="$tmp/snapshot"
    proof="$tmp/proof"
    runner="$tmp/runner"
    result="$proof/result.env"
    stdout="$tmp/wrapper.out"
    stderr="$tmp/wrapper.err"
    make_snapshot "$snapshot"
    write_runner "$runner"

    status="$(run_wrapper "$stdout" "$stderr" "$result" 5 "$snapshot" "$proof" -- "$runner")"

    assert_eq "$status" "2" "missing manifest exit"
    assert_contains "$stderr" "proof bundle must contain a regular manifest.json" "missing manifest error"
    assert_file_missing "$result"
}

test_missing_execution_result_is_rejected() {
    local tmp snapshot proof runner result stdout stderr status
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    snapshot="$tmp/snapshot"
    proof="$tmp/proof"
    runner="$tmp/runner"
    result="$proof/result.env"
    stdout="$tmp/wrapper.out"
    stderr="$tmp/wrapper.err"
    make_snapshot "$snapshot"
    make_proof "$proof"
    write_runner "$runner" disabled 'exit 0'

    status="$(run_wrapper "$stdout" "$stderr" "$result" 5 "$snapshot" "$proof" -- "$runner")"

    assert_eq "$status" "5" "missing execution result exit"
    assert_contains "$stdout" "STATUS=protocol" "missing execution result status"
    assert_contains "$result" "STATUS=protocol" "missing execution result record"
}

test_malformed_execution_result_is_rejected() {
    local tmp snapshot proof runner result stdout stderr status
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    snapshot="$tmp/snapshot"
    proof="$tmp/proof"
    runner="$tmp/runner"
    result="$proof/result.env"
    stdout="$tmp/wrapper.out"
    stderr="$tmp/wrapper.err"
    make_snapshot "$snapshot"
    make_proof "$proof"
    write_runner "$runner" disabled \
        'printf "{}\n" >"$REVIEW_ANVIL_PROOF_RUNTIME/execution.json"; exit 0'

    status="$(run_wrapper "$stdout" "$stderr" "$result" 5 "$snapshot" "$proof" -- "$runner")"

    assert_eq "$status" "5" "malformed execution result exit"
    assert_contains "$stdout" "STATUS=protocol" "malformed execution result status"
    assert_file_missing "$proof/runtime"
    assert_file_missing "$proof/execution.json"
    assert_contains "$result" "STATUS=protocol" "malformed execution result record"
    assert_contains "$result" "RUNTIME_REMOVED=yes" "protocol runtime cleanup"
}

test_dirty_snapshot_is_rejected_before_runner() {
    local tmp snapshot proof runner result stdout stderr status
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    snapshot="$tmp/snapshot"
    proof="$tmp/proof"
    runner="$tmp/runner"
    result="$proof/result.env"
    stdout="$tmp/wrapper.out"
    stderr="$tmp/wrapper.err"
    make_snapshot "$snapshot"
    make_proof "$proof"
    printf 'dirty\n' >>"$snapshot/source.txt"
    write_runner "$runner"

    status="$(run_wrapper "$stdout" "$stderr" "$result" 5 "$snapshot" "$proof" -- "$runner")"

    assert_eq "$status" "2" "dirty snapshot exit"
    assert_contains "$stderr" "source snapshot must start clean" "dirty snapshot error"
    assert_file_missing "$result"
}

test_valid_runner_gets_sanitized_environment
test_relative_runner_is_rejected
test_runner_inside_snapshot_is_rejected
test_incomplete_capabilities_are_rejected
test_snapshot_mutation_invalidates_result
test_broad_read_capability_is_rejected
test_contradictory_capabilities_are_rejected
test_proof_input_mutation_invalidates_result
test_probe_result_symlink_cannot_overwrite_host_file
test_missing_manifest_is_rejected
test_timeout_is_bounded
test_term_trap_still_counts_as_timeout
test_output_size_is_bounded
test_timeout_terminates_runner_descendants
test_normal_exit_terminates_runner_descendants
test_runtime_special_entries_are_not_retained
test_phases_share_one_deadline
test_missing_execution_result_is_rejected
test_malformed_execution_result_is_rejected
test_dirty_snapshot_is_rejected_before_runner

printf 'test-run-proof: all tests passed\n'
