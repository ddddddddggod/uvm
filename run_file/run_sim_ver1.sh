#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C
export LANG=C
export PATH="$PWD/.ot_dv_venv/bin:$PATH"

default_args=(
  hw/ip/kmac/dv/kmac_unmasked_sim_cfg.hjson
  --tool xcelium
  -i kmac_smoke
  --fixed-seed 1
  --reseed 1
  --max-parallel 1
)

if [[ $# -eq 0 ]]; then
  args=("${default_args[@]}")
else
  args=("$@")
fi

has_tool=0
tool_value=""
passthrough_only=0
build_only=0
vcs_xprop_off=0

for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --tool|-t)
      has_tool=1
      if (( i + 1 < ${#args[@]} )); then
        tool_value="${args[$((i + 1))]}"
      fi
      ;;
    --tool=*)
      has_tool=1
      tool_value="${args[$i]#--tool=}"
      ;;
    -h|--help|--version|-l|--list|-n|--dry-run|--fake|-ru|--run-only)
      passthrough_only=1
      ;;
    -bu|--build-only)
      build_only=1
      ;;
    --xprop-off)
      vcs_xprop_off=1
      ;;
  esac
done

if [[ "$has_tool" -eq 0 ]]; then
  args+=(--tool xcelium)
  tool_value="xcelium"
fi

if [[ "$tool_value" == "vcs" ]]; then
  # VCS O-2018.09 on iris needs GCC 11 for the current OpenTitan DPI build and
  # rejects the default xprop configuration together with mmsopt.
  if [[ "$vcs_xprop_off" -eq 0 ]]; then
    args+=(--xprop-off)
  fi
  echo "VCS mode: enabling devtoolset-11 and defaulting to --xprop-off." >&2
  exec scl enable devtoolset-11 -- dvsim "${args[@]}"
fi

if [[ "$tool_value" != "xcelium" ]]; then
  exec dvsim "${args[@]}"
fi

if [[ "$passthrough_only" -eq 1 ]]; then
  exec dvsim "${args[@]}"
fi

make_run_args() {
  run_args=()
  local idx
  for ((idx = 0; idx < ${#args[@]}; idx++)); do
    case "${args[$idx]}" in
      --purge|--build-only|-bu)
        continue
        ;;
      --purge=*)
        continue
        ;;
      *)
        run_args+=("${args[$idx]}")
        ;;
    esac
  done
}

make_no_purge_args() {
  no_purge_args=()
  local idx
  for ((idx = 0; idx < ${#args[@]}; idx++)); do
    case "${args[$idx]}" in
      --purge|--purge=*)
        continue
        ;;
      *)
        no_purge_args+=("${args[$idx]}")
        ;;
    esac
  done
}

rerun_xrun_after_patching() {
  local build_output="$1"
  local patched_db="$2"

  python3 - "$build_output" "$patched_db" <<'PY'
from __future__ import annotations

import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

build_output = Path(sys.argv[1])
patched_db = Path(sys.argv[2])
text = build_output.read_text(errors="ignore") if build_output.exists() else ""

patchable_markers = (
    "BADQAL",
    "extern constraint",
    "IMPMOD",
    "Export DPI function/task declaration",
    "simutil_get_scramble_nonce",
    "u_prim_sync_reqack_data",
    "$assertoff",
    "$asserton",
)
if not any(marker in text for marker in patchable_markers):
    print("No patchable Xcelium-20.09 compatibility failure was found.", file=sys.stderr)
    sys.exit(3)

def unique_existing(paths):
    seen = set()
    out = []
    for path in paths:
        path = path.resolve()
        if path in seen or not path.exists():
            continue
        seen.add(path)
        out.append(path)
    return out

def unique_paths(paths):
    seen = set()
    out = []
    for path in paths:
        path = path.resolve()
        if path in seen:
            continue
        seen.add(path)
        out.append(path)
    return out

def xcelium_db_dirs_from_cmd(build_dir, xrun_cmd):
    db_dirs = [build_dir / "xcelium.d"]
    try:
        tokens = shlex.split(xrun_cmd)
    except ValueError:
        return unique_paths(db_dirs)

    for idx, token in enumerate(tokens):
        if token == "-xmlibdirname" and idx + 1 < len(tokens):
            db_dir = Path(tokens[idx + 1])
            if not db_dir.is_absolute():
                db_dir = build_dir / "fusesoc-work" / db_dir
            db_dirs.append(db_dir)
    return unique_paths(db_dirs)

build_logs = []

for log_path in re.findall(r"(?:Log|log)\s+(\S+/build\.log)", text):
    build_logs.append(Path(log_path.rstrip(".,)")))

if not build_logs:
    for scratch_path in re.findall(r"\[scratch_path\]: \[[^\]]+\] \[([^\]]+)\]", text):
        scratch_dir = Path(scratch_path)
        build_logs.extend(scratch_dir.glob("*/build.log"))

build_logs = unique_existing(build_logs)
build_logs = [
    path for path in build_logs
    if " xrun " in path.read_text(errors="ignore")
    and any(marker in path.read_text(errors="ignore") for marker in patchable_markers)
]

if not build_logs:
    print("No current Xcelium build logs found to patch/re-run.", file=sys.stderr)
    sys.exit(3)

patterns = ("*.sv", "*.svh")
total_patched_files = 0
total_replacements = 0
extern_constraint_pattern = re.compile(r"\bextern\s+constraint\b")
assert_control_patterns = (
    re.compile(
        r'^\s*\$assert(?:off|on)\(0,\s*"tb\.dut\.gen_entropy\.'
        r'u_prim_sync_reqack_data\.u_prim_sync_reqack\.[^"]+"\);\s*$',
        re.MULTILINE,
    ),
)
ibex_if_stage_dpi_pattern = re.compile(
    r'`ifndef SYNTHESIS\n'
    r'(?:\s*//[^\n]*\n)*'
    r'\s*export "DPI-C" function simutil_get_scramble_key;\n'
    r'\s*export "DPI-C" function simutil_get_scramble_nonce;\n'
    r'\s*function automatic int simutil_get_scramble_key\(output bit \[127:0\] val\);\n'
    r'\s*return 0;\n'
    r'\s*endfunction\n'
    r'\s*function automatic int simutil_get_scramble_nonce\(output bit \[319:0\] nonce\);\n'
    r'\s*return 0;\n'
    r'\s*endfunction\n'
    r'`endif\n'
    r'(?P<indent>\s*)end'
)
ibex_if_stage_dpi_stub = """

`ifndef SYNTHESIS
module ibex_if_stage_scramble_dpi_stub;
  export "DPI-C" function simutil_get_scramble_key;
  export "DPI-C" function simutil_get_scramble_nonce;

  function automatic int simutil_get_scramble_key(output bit [127:0] val);
    val = '0;
    return 0;
  endfunction

  function automatic int simutil_get_scramble_nonce(output bit [319:0] nonce);
    nonce = '0;
    return 0;
  endfunction
endmodule : ibex_if_stage_scramble_dpi_stub
`endif
"""

def patch_ibex_if_stage_dpi_stub(path, data):
    if path.name != "ibex_if_stage.sv":
        return data, 0

    new_data, count = ibex_if_stage_dpi_pattern.subn(
        '`ifndef SYNTHESIS\n'
        '    ibex_if_stage_scramble_dpi_stub u_scramble_dpi_stub ();\n'
        '`endif\n'
        r'\g<indent>end',
        data,
        count=1,
    )
    if count == 0 or "module ibex_if_stage_scramble_dpi_stub" in new_data:
        return new_data, count

    new_data, append_count = re.subn(
        r'(?m)^endmodule\s*$',
        "endmodule" + ibex_if_stage_dpi_stub,
        new_data,
        count=1,
    )
    return new_data, count + append_count

for build_log in build_logs:
    build_dir = build_log.parent
    src_dir = build_dir / "fusesoc-work" / "src"
    if not src_dir.is_dir():
        print(f"ERROR: fusesoc source directory not found: {src_dir}", file=sys.stderr)
        sys.exit(2)

    patched_files = 0
    replacements = 0
    for pattern in patterns:
        for path in src_dir.rglob(pattern):
            data = path.read_text(errors="ignore")
            new_data, file_replacements = extern_constraint_pattern.subn("constraint", data)
            for rx in assert_control_patterns:
                new_data, count = rx.subn("", new_data)
                file_replacements += count
            new_data, count = patch_ibex_if_stage_dpi_stub(path, new_data)
            file_replacements += count
            if new_data != data:
                path.write_text(new_data)
                patched_files += 1
                replacements += file_replacements

    total_patched_files += patched_files
    total_replacements += replacements
    print(
        f"Patched {replacements} Xcelium-20.09 compatibility items in "
        f"{patched_files} files for {build_dir}.",
        flush=True,
    )

    build_text = build_log.read_text(errors="ignore")
    xrun_cmd = None
    for line in build_text.splitlines():
        stripped = line.strip()
        if " xrun " in stripped and stripped.startswith("cd "):
            xrun_cmd = stripped
            break

    if xrun_cmd is None:
        print(f"ERROR: could not extract xrun build command from {build_log}", file=sys.stderr)
        sys.exit(2)

    build_dir_resolved = build_dir.resolve()
    for db_dir in xcelium_db_dirs_from_cmd(build_dir, xrun_cmd):
        db_dir_resolved = db_dir.resolve()
        if (
            db_dir_resolved.name != "xcelium.d"
            or (
                db_dir_resolved != build_dir_resolved / "xcelium.d"
                and build_dir_resolved not in db_dir_resolved.parents
            )
        ):
            print(f"Skipping unexpected Xcelium DB path: {db_dir_resolved}", flush=True)
            continue
        if db_dir_resolved.exists():
            print(f"Removing stale Xcelium DB before rebuild: {db_dir_resolved}", flush=True)
            shutil.rmtree(db_dir_resolved)

    print(f"Re-running patched Xcelium build command for {build_dir}.", flush=True)
    subprocess.run(xrun_cmd, shell=True, check=True)
    with patched_db.open("a") as db:
        db.write(str(build_dir.resolve()) + "\n")

print(
    f"Total patched compatibility items: {total_replacements} in "
    f"{total_patched_files} files across {len(build_logs)} build(s).",
    flush=True,
)
PY
}

failed_builds_already_patched() {
  local build_output="$1"
  local patched_db="$2"

  python3 - "$build_output" "$patched_db" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

build_output = Path(sys.argv[1])
patched_db = Path(sys.argv[2])
text = build_output.read_text(errors="ignore") if build_output.exists() else ""

patchable_markers = (
    "BADQAL",
    "extern constraint",
    "IMPMOD",
    "Export DPI function/task declaration",
    "simutil_get_scramble_nonce",
    "u_prim_sync_reqack_data",
    "$assertoff",
    "$asserton",
)
if not any(marker in text for marker in patchable_markers):
    sys.exit(1)

patched = set()
if patched_db.exists():
    patched = {
        line.strip()
        for line in patched_db.read_text(errors="ignore").splitlines()
        if line.strip()
    }

def unique_existing(paths):
    seen = set()
    out = []
    for path in paths:
        path = path.resolve()
        if path in seen or not path.exists():
            continue
        seen.add(path)
        out.append(path)
    return out

build_logs = []
for log_path in re.findall(r"(?:Log|log)\s+(\S+/build\.log)", text):
    build_logs.append(Path(log_path.rstrip(".,)")))

if not build_logs:
    for scratch_path in re.findall(r"\[scratch_path\]: \[[^\]]+\] \[([^\]]+)\]", text):
        build_logs.extend(Path(scratch_path).glob("*/build.log"))

build_logs = unique_existing(build_logs)
build_logs = [
    path for path in build_logs
    if " xrun " in path.read_text(errors="ignore")
    and any(marker in path.read_text(errors="ignore") for marker in patchable_markers)
]

build_dirs = unique_existing(path.parent for path in build_logs)
if not build_dirs:
    sys.exit(1)

missing = [
    build_dir for build_dir in build_dirs
    if str(build_dir.resolve()) not in patched or not (build_dir / "xcelium.d").is_dir()
]

if missing:
    sys.exit(1)

print(
    "Build-only is failing only on already patched Xcelium build dir(s); "
    "refreshing them before run-only.",
    flush=True,
)
for build_dir in build_dirs:
    print(f"  {build_dir}", flush=True)
PY
}

tmp_output="$(mktemp)"
patched_builds_file="$(mktemp)"
trap 'rm -f "$tmp_output" "$patched_builds_file"' EXIT

run_build_until_success() {
  local max_passes="${XRUN_COMPAT_MAX_BUILD_PASSES:-8}"
  local pass
  local build_status
  local patch_status
  local -a current_build_args

  for ((pass = 1; pass <= max_passes; pass++)); do
    if [[ "$pass" -eq 1 ]]; then
      current_build_args=("${build_args[@]}")
    else
      current_build_args=("${build_retry_args[@]}")
    fi

    : > "$tmp_output"
    set +e
    dvsim "${current_build_args[@]}" 2>&1 | tee "$tmp_output"
    build_status=${PIPESTATUS[0]}
    set -e

    if [[ "$build_status" -eq 0 ]]; then
      return 0
    fi

    if failed_builds_already_patched "$tmp_output" "$patched_builds_file"; then
      echo "Refreshing already patched Xcelium build dir(s) before run-only."
      set +e
      rerun_xrun_after_patching "$tmp_output" "$patched_builds_file"
      patch_status=$?
      set -e
      if [[ "$patch_status" -ne 0 ]]; then
        return "$patch_status"
      fi
      return 0
    fi
    echo "Build-only pass ${pass}/${max_passes} failed; applying Xcelium 20.09 compatibility patch."
    set +e
    rerun_xrun_after_patching "$tmp_output" "$patched_builds_file"
    patch_status=$?
    set -e
    if [[ "$patch_status" -eq 3 ]]; then
      echo "No current Xcelium build log was found; leaving the dvsim failure unchanged." >&2
      return "$build_status"
    fi
    if [[ "$patch_status" -ne 0 ]]; then
      return "$patch_status"
    fi
  done

  echo "ERROR: build did not converge after ${max_passes} compatibility patch pass(es)." >&2
  return 1
}

run_full_until_success_or_unpatchable() {
  local max_passes="${XRUN_COMPAT_MAX_FULL_PASSES:-8}"
  local pass
  local run_status
  local patch_status
  local -a current_run_args=("$@")

  for ((pass = 1; pass <= max_passes; pass++)); do
    : > "$tmp_output"
    set +e
    dvsim "${current_run_args[@]}" 2>&1 | tee "$tmp_output"
    run_status=${PIPESTATUS[0]}
    set -e

    if [[ "$run_status" -eq 0 ]]; then
      return 0
    fi

    echo "Full dvsim pass ${pass}/${max_passes} failed; checking for a patchable Xcelium build failure."
    set +e
    rerun_xrun_after_patching "$tmp_output" "$patched_builds_file"
    patch_status=$?
    set -e

    if [[ "$patch_status" -eq 3 ]]; then
      return "$run_status"
    fi
    if [[ "$patch_status" -ne 0 ]]; then
      return "$patch_status"
    fi
  done

  echo "ERROR: full dvsim did not converge after ${max_passes} compatibility patch pass(es)." >&2
  return 1
}

run_only_or_rebuild_missing_db() {
  local run_status

  : > "$tmp_output"
  set +e
  dvsim "${run_args[@]}" --run-only 2>&1 | tee "$tmp_output"
  run_status=${PIPESTATUS[0]}
  set -e

  if [[ "$run_status" -eq 0 ]]; then
    return 0
  fi

  if grep -Eq 'NWRKDRA|NC library working directory could not be found' "$tmp_output"; then
    echo "Run-only failed because an Xcelium work library is missing; falling back to full dvsim without purge."
    make_no_purge_args
    run_full_until_success_or_unpatchable "${no_purge_args[@]}"
    return $?
  fi

  return "$run_status"
}

if [[ "$build_only" -eq 1 ]]; then
  build_args=("${args[@]}")
  make_no_purge_args
  build_retry_args=("${no_purge_args[@]}")
  run_build_until_success
  exit 0
fi

build_args=("${args[@]}" --build-only)
make_no_purge_args
build_retry_args=("${no_purge_args[@]}" --build-only)
run_build_until_success

make_run_args
run_only_or_rebuild_missing_db
