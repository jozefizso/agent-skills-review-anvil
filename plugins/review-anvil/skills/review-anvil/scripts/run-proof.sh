#!/usr/bin/env bash
# run-proof.sh — invoke a trusted isolated runner for one review-anvil proof bundle
#
# Usage:
#   run-proof.sh <result_file> <timeout_seconds> <source_snapshot> <proof_dir> \
#     -- <absolute_runner> [args...]
#
# The trusted runner must expose the exact capability record below. It must run
# reviewed code with source and author-supplied proof inputs read-only, expose
# only `<proof_dir>/runtime` as writable, and author execution.json itself after
# the probe exits. run-proof.sh independently bounds the runner process group,
# verifies source state and proof-input hashes, and publishes captures with
# atomic no-follow replacement.
#
#   PROTOCOL=1
#   NETWORK=disabled
#   SOURCE=read-only
#   PROOF_INPUTS=read-only
#   READS=source-proof-runtime-only
#   WRITES=proof-runtime-only
#   RESULT=runner-authored
#   ENVIRONMENT=sanitized
#   RESOURCES=bounded
#
# The runner is invoked with REVIEW_ANVIL_PROOF_MODE set to `capabilities` and
# `run`. Run mode receives REVIEW_ANVIL_SOURCE, REVIEW_ANVIL_PROOF_DIR,
# REVIEW_ANVIL_PROOF_RUNTIME, REVIEW_ANVIL_PROOF_MANIFEST,
# REVIEW_ANVIL_TIMEOUT_SECONDS, REVIEW_ANVIL_DEADLINE_MONOTONIC, and
# REVIEW_ANVIL_MAX_OUTPUT_BYTES in an otherwise sanitized environment. Both
# phases share that one monotonic deadline.
# After the probe exits, the runner writes
# `<proof_dir>/runtime/execution.json` with protocol 1, the manifest target,
# `status: "completed"`, and the probe's integer `probe_exit_code`. The runner
# process exits zero when orchestration completed even if the probe did not.
# The wrapper copies only a validated regular execution result into the retained
# bundle, then safely deletes the untrusted runtime tree on every exit.
# Cleanup restores owner access on real runtime directories before unlinking
# them. A cleanup failure returns exit 7 and cannot produce accepted evidence.

set -u

die() { printf 'run-proof: %s\n' "$*" >&2; exit 2; }

result="${1:-}"
secs="${2:-}"
source="${3:-}"
proof="${4:-}"
sep="${5:-}"
[[ -n "$result" && -n "$secs" && -n "$source" && -n "$proof" && "$sep" == "--" ]] || \
    die 'usage: run-proof.sh <result_file> <timeout_seconds> <source_snapshot> <proof_dir> -- <absolute_runner> [args...]'
shift 5
[[ $# -ge 1 ]] || die 'no runner command given after --'
[[ "$secs" =~ ^[1-9][0-9]*$ ]] || \
    die "timeout must be a positive integer number of seconds, got '$secs'"
[[ "$result" == /* && "$source" == /* && "$proof" == /* ]] || \
    die 'result, source snapshot, and proof directory must be absolute paths'
[[ "$1" == /* ]] || die 'runner command must be an absolute path'

realpath_py='import os,sys; print(os.path.realpath(sys.argv[1]))'
source_real="$(python3 -c "$realpath_py" "$source")" || die 'cannot resolve source snapshot'
proof_real="$(python3 -c "$realpath_py" "$proof")" || die 'cannot resolve proof directory'
runner_real="$(python3 -c "$realpath_py" "$1")" || die 'cannot resolve runner command'
result_parent="$(python3 -c "$realpath_py" "$(dirname "$result")")" || die 'cannot resolve result parent'
result_name="$(basename "$result")"

[[ -d "$source_real" ]] || die "source snapshot is not a directory: $source"
[[ -x "$runner_real" ]] || die "runner command is not executable: $1"
[[ "$result_parent" == "$proof_real" && "$result_name" != '.' && "$result_name" != '..' ]] || \
    die 'result file must be a direct child of the proof directory'
result_real="$proof_real/$result_name"
case "$runner_real/" in
    "$source_real/"*|"$proof_real/"*)
        die 'runner command must be outside the source and proof directories'
        ;;
esac
case "$proof_real/" in
    "$source_real/"*) die 'proof directory must be outside the source snapshot' ;;
esac

script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
bounded_helper="$script_root/run-proof-command.py"
[[ -x "$bounded_helper" ]] || die 'trusted bounded-command helper is unavailable'

mkdir -p "$proof_real"
manifest="$proof_real/manifest.json"
[[ -f "$manifest" && ! -L "$manifest" ]] || \
    die 'proof bundle must contain a regular manifest.json'
runtime="$proof_real/runtime"
host_tmp=''
runtime_removed=yes
cleanup_runtime() {
    if python3 -c 'import os,shutil,stat,sys
p=sys.argv[1]
if not os.path.lexists(p):
    raise SystemExit(0)
s=os.lstat(p)
if stat.S_ISLNK(s.st_mode) or not stat.S_ISDIR(s.st_mode):
    os.unlink(p)
else:
    os.chmod(p,0o700)
    for base,dirs,_ in os.walk(p,topdown=True,followlinks=False):
        for name in dirs:
            child=os.path.join(base,name)
            child_stat=os.lstat(child)
            if stat.S_ISDIR(child_stat.st_mode):
                os.chmod(child,0o700)
    shutil.rmtree(p)
raise SystemExit(1 if os.path.lexists(p) else 0)' "$runtime"; then
        runtime_removed=yes
        return 0
    fi
    return 1
}
cleanup_all() {
    local exit_status=$? cleanup_status=0
    cleanup_runtime || cleanup_status=$?
    [[ -z "$host_tmp" ]] || rm -rf "$host_tmp"
    if [[ "$cleanup_status" -ne 0 ]]; then
        printf 'run-proof: failed to remove untrusted proof runtime: %s\n' "$runtime" >&2
        exit 7
    fi
    exit "$exit_status"
}
trap cleanup_all EXIT
cleanup_runtime || die 'cannot remove prior proof runtime safely'
python3 -c 'import os,sys
p=sys.argv[1]
os.mkdir(p, 0o700)
os.mkdir(os.path.join(p,"home"), 0o700)
os.mkdir(os.path.join(p,"tmp"), 0o700)' "$runtime" || die 'cannot create clean proof runtime directory'
runtime_removed=no

capabilities="${result_real}.capabilities"
capabilities_err="${capabilities}.stderr"
out="${result_real}.stdout"
err="${result_real}.stderr"
execution="$proof_real/execution.json"
for artifact in "$result_real" "$capabilities" "$capabilities_err" "$out" "$err" "$execution"; do
    rm -f "$artifact" || die "cannot remove prior artifact: $artifact"
done

host_tmp="$(mktemp -d /tmp/review-anvil-proof.XXXXXX)" || die 'cannot create host capture directory'
chmod 700 "$host_tmp"
host_capabilities="$host_tmp/capabilities"
host_capabilities_err="$host_tmp/capabilities.stderr"
host_out="$host_tmp/stdout"
host_err="$host_tmp/stderr"
host_execution="$host_tmp/execution.json"
host_result="$host_tmp/result.env"
phase_status_file="$host_tmp/phase.json"

proof_fingerprint() {
    python3 -c 'import hashlib,os,stat,sys
root=sys.argv[1]
excluded=set(sys.argv[2:])
h=hashlib.sha256()
for base,dirs,files in os.walk(root, topdown=True, followlinks=False):
    relbase=os.path.relpath(base,root)
    if relbase==".":
        dirs[:]=[d for d in dirs if d!="runtime"]
    for name in sorted(dirs):
        p=os.path.join(base,name)
        if os.path.islink(p): raise SystemExit(3)
    for name in sorted(files):
        p=os.path.join(base,name)
        rel=os.path.relpath(p,root)
        if rel in excluded: continue
        s=os.lstat(p)
        if not stat.S_ISREG(s.st_mode): raise SystemExit(3)
        h.update(rel.encode()+b"\0")
        with open(p,"rb") as f:
            for chunk in iter(lambda:f.read(65536),b""): h.update(chunk)
print(h.hexdigest())' "$proof_real" \
        "$result_name" "${result_name}.capabilities" \
        "${result_name}.capabilities.stderr" "${result_name}.stdout" \
        "${result_name}.stderr" execution.json
}

initial_proof_fingerprint="$(proof_fingerprint)" || \
    die 'proof inputs must contain only regular files and directories'

git -C "$source_real" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
    die 'source snapshot must be a Git worktree'
head_sha="$(git -C "$source_real" rev-parse HEAD)" || die 'source snapshot has no HEAD'
source_state() {
    git -C "$source_real" status --porcelain --untracked-files=all --ignored
}
[[ -z "$(source_state)" ]] || die 'source snapshot must start clean, including ignored files'

runner=("$runner_real" "${@:2}")
safe_path='/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin'
deadline_monotonic="$(python3 -c 'import sys,time; c=getattr(time,"CLOCK_MONOTONIC_RAW",time.CLOCK_MONOTONIC); print(time.clock_gettime(c)+int(sys.argv[1]))' "$secs")" || \
    die 'cannot establish proof deadline'
run_status=70
run_timed_out=no

run_bounded() {
    local mode="$1" stdout_path="$2" stderr_path="$3" parsed remaining
    rm -f "$phase_status_file" "$stdout_path" "$stderr_path"
    remaining="$(python3 -c 'import sys,time; c=getattr(time,"CLOCK_MONOTONIC_RAW",time.CLOCK_MONOTONIC); print(max(0.0,float(sys.argv[1])-time.clock_gettime(c)))' "$deadline_monotonic")" || {
        run_status=70
        run_timed_out=no
        return
    }
    env -i \
        PATH="$safe_path" \
        HOME="$runtime/home" \
        TMPDIR="$runtime/tmp" \
        LANG=C \
        LC_ALL=C \
        REVIEW_ANVIL_PROOF_MODE="$mode" \
        REVIEW_ANVIL_SOURCE="$source_real" \
        REVIEW_ANVIL_PROOF_DIR="$proof_real" \
        REVIEW_ANVIL_PROOF_RUNTIME="$runtime" \
        REVIEW_ANVIL_PROOF_MANIFEST="$manifest" \
        REVIEW_ANVIL_TIMEOUT_SECONDS="$remaining" \
        REVIEW_ANVIL_DEADLINE_MONOTONIC="$deadline_monotonic" \
        REVIEW_ANVIL_MAX_OUTPUT_BYTES=1048576 \
        python3 "$bounded_helper" "$phase_status_file" "$deadline_monotonic" \
            "$stdout_path" "$stderr_path" -- "${runner[@]}"
    if [[ $? -ne 0 || ! -f "$phase_status_file" ]]; then
        run_status=70
        run_timed_out=no
        return
    fi
    parsed="$(python3 -c 'import json,sys
v=json.load(open(sys.argv[1],encoding="utf-8"))
e=v.get("exit_code"); t=v.get("timed_out")
assert isinstance(e,int) and not isinstance(e,bool) and isinstance(t,bool)
print(e, "yes" if t else "no")' "$phase_status_file" 2>/dev/null)" || {
        run_status=70
        run_timed_out=no
        return
    }
    read -r run_status run_timed_out <<<"$parsed"
}

proof_unchanged() {
    local current
    current="$(proof_fingerprint)" || return 1
    [[ "$current" == "$initial_proof_fingerprint" ]]
}

source_unchanged() {
    [[ -z "$(source_state)" && "$(git -C "$source_real" rev-parse HEAD)" == "$head_sha" ]]
}

publish() {
    local from="$1" to="$2"
    [[ -f "$from" && ! -L "$from" ]] || return 1
    python3 -c 'import os,shutil,sys,tempfile
src,dst=sys.argv[1:]
parent=os.path.dirname(dst)
fd,tmp=tempfile.mkstemp(prefix=".review-anvil-publish.",dir=parent)
try:
    with os.fdopen(fd,"wb") as out, open(src,"rb") as inp:
        shutil.copyfileobj(inp,out)
    os.chmod(tmp,0o600)
    os.replace(tmp,dst)
except BaseException:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
    raise' "$from" "$to"
}

publish_captures() {
    [[ ! -e "$host_capabilities" ]] || publish "$host_capabilities" "$capabilities"
    [[ ! -e "$host_capabilities_err" ]] || publish "$host_capabilities_err" "$capabilities_err"
    [[ ! -e "$host_out" ]] || publish "$host_out" "$out"
    [[ ! -e "$host_err" ]] || publish "$host_err" "$err"
    [[ ! -e "$host_execution" ]] || publish "$host_execution" "$execution"
}

write_result() {
    local status="$1" exit_code="$2" tree="$3" proof_state="$4"
    {
        printf 'STATUS=%s\n' "$status"
        printf 'EXIT_CODE=%s\n' "$exit_code"
        printf 'HEAD_SHA=%s\n' "$head_sha"
        printf 'TREE_UNCHANGED=%s\n' "$tree"
        printf 'PROOF_UNCHANGED=%s\n' "$proof_state"
        printf 'RUNTIME_REMOVED=%s\n' "$runtime_removed"
        printf 'CAPABILITIES_FILE=%s\n' "$capabilities"
        printf 'STDOUT_FILE=%s\n' "$out"
        printf 'STDERR_FILE=%s\n' "$err"
        printf 'EXECUTION_FILE=%s\n' "$execution"
    } >"$host_result"
    publish "$host_result" "$result_real" || die 'cannot publish result safely'
}

finish() {
    local status="$1" command_status="$2" tree="$3" proof_state="$4" wrapper_status="$5"
    if ! cleanup_runtime; then
        rm -f "$host_execution"
        publish_captures || die 'cannot publish proof captures safely'
        write_result runtime-cleanup-failed "$command_status" "$tree" "$proof_state"
        printf 'STATUS=runtime-cleanup-failed\n'
        exit 7
    fi
    publish_captures || die 'cannot publish proof captures safely'
    write_result "$status" "$command_status" "$tree" "$proof_state"
    [[ "$command_status" == 0 ]] || printf 'EXIT_CODE=%s\n' "$command_status"
    printf 'STATUS=%s\n' "$status"
    exit "$wrapper_status"
}

run_bounded capabilities "$host_capabilities" "$host_capabilities_err"
capability_status=$run_status
capability_timeout=$run_timed_out

if ! source_unchanged; then
    finish source-mutated "$capability_status" no yes 4
fi
if ! proof_unchanged; then
    finish proof-mutated "$capability_status" yes no 6
fi
capability_ok=no
if [[ "$capability_timeout" == no && "$capability_status" == 0 ]] && \
    python3 -c 'import sys
expected=[
"PROTOCOL=1",
"NETWORK=disabled",
"SOURCE=read-only",
"PROOF_INPUTS=read-only",
"READS=source-proof-runtime-only",
"WRITES=proof-runtime-only",
"RESULT=runner-authored",
"ENVIRONMENT=sanitized",
"RESOURCES=bounded",
]
actual=open(sys.argv[1],encoding="utf-8").read().splitlines()
raise SystemExit(0 if actual==expected else 1)' "$host_capabilities" 2>/dev/null; then
    capability_ok=yes
fi
if [[ "$capability_ok" != yes ]]; then
    finish capability-rejected "$capability_status" yes yes 3
fi

rm -f "$runtime/execution.json"
run_bounded run "$host_out" "$host_err"
command_status=$run_status
command_timeout=$run_timed_out

if ! source_unchanged; then
    finish source-mutated "$command_status" no yes 4
fi
if ! proof_unchanged; then
    finish proof-mutated "$command_status" yes no 6
fi
if [[ "$command_timeout" == yes ]]; then
    finish timeout "$command_status" yes yes 124
fi
if [[ "$command_status" -ne 0 ]]; then
    finish failed "$command_status" yes yes 1
fi

runtime_execution="$runtime/execution.json"
runtime_root_ok=no
if python3 -c 'import os,stat,sys
p=sys.argv[1]
s=os.lstat(p)
if not stat.S_ISDIR(s.st_mode) or stat.S_ISLNK(s.st_mode):
    raise SystemExit(1)
os.chmod(p,0o700)' "$runtime" 2>/dev/null; then
    runtime_root_ok=yes
fi
execution_ok=no
if [[ "$runtime_root_ok" == yes && -f "$runtime_execution" && ! -L "$runtime_execution" ]] && \
    python3 -c 'import json,os,stat,sys
manifest_path,execution_path=sys.argv[1:]
s=os.lstat(execution_path)
if not stat.S_ISREG(s.st_mode):
    raise SystemExit(1)
m=json.load(open(manifest_path,encoding="utf-8"))
e=json.load(open(execution_path,encoding="utf-8"))
ok=(m.get("protocol")==1 and isinstance(m.get("target"),str) and
    e.get("protocol")==1 and e.get("target")==m.get("target") and
    e.get("status")=="completed" and
    isinstance(e.get("probe_exit_code"),int) and
    not isinstance(e.get("probe_exit_code"),bool))
raise SystemExit(0 if ok else 1)' "$manifest" "$runtime_execution" 2>/dev/null; then
    if publish "$runtime_execution" "$host_execution"; then
        execution_ok=yes
    fi
fi
if [[ "$execution_ok" != yes ]]; then
    finish protocol "$command_status" yes yes 5
fi

finish ok 0 yes yes 0
