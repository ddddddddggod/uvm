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
  # ADDED: VCS 20.09 compatibility settings.
  # Keep the existing GCC 11 environment and disable the default xprop mode.
  if [[ "$vcs_xprop_off" -eq 0 ]]; then
    args+=(--xprop-off)
  fi

  # ADDED: VCS 20.09 CSRNG coverage compatibility handling.
  #
  # VCS 20.09 has compatibility issues with several newer functional
  # coverage expressions in csrng_cov_if.sv. Patch the ORIGINAL source
  # temporarily before FuseSoC copies it into scratch. This also works
  # when --purge is used.
  vcs_cov_file=""
  while IFS= read -r candidate; do
    if grep -q "single_masks(num_hw_apps)" "$candidate" ||
       grep -Eq '!binsof\(cp_(hw[0-9]+|sw)_cmd_depth\)' "$candidate" ||
       grep -Eq 'with \(!((hw[0-9]+)|sw)_cmd_rdy\)' "$candidate"; then
      vcs_cov_file="$candidate"
      break
    fi
  done < <(
    find "$PWD/hw" \
      -type f \
      -name "csrng_cov_if.sv" \
      2>/dev/null
  )

  vcs_cov_backup=""

  # ADDED: OpenSSL 1.0.2k compatibility handling for the AES C model.
  #
  # OpenTitan's AES model uses:
  #
  #   EVP_CTRL_AEAD_GET_TAG
  #   EVP_CTRL_AEAD_SET_TAG
  #
  # but OpenSSL 1.0.2k on this server only provides:
  #
  #   EVP_CTRL_GCM_GET_TAG
  #   EVP_CTRL_GCM_SET_TAG
  #
  # Patch the ORIGINAL AES model source temporarily so FuseSoC copies
  # the compatible version into scratch. The source is restored later.
  # ADDED: Use the exact persistent AES model source path.
  # This avoids accidentally patching a generated scratch copy.
  vcs_crypto_file="$PWD/hw/ip/aes/model/crypto.c"

  if [[ ! -f "$vcs_crypto_file" ]]; then
    echo "ERROR: AES model source not found: $vcs_crypto_file" >&2
    vcs_crypto_file=""
  fi

  vcs_crypto_backup=""

  if [[ -n "$vcs_crypto_file" ]]; then
    echo "VCS 20.09: AES model OpenSSL 1.0.2 compatibility patch required." >&2
    echo "VCS 20.09: Persistent AES model source file: $vcs_crypto_file" >&2

    vcs_crypto_backup="$(mktemp)"
    cp "$vcs_crypto_file" "$vcs_crypto_backup"

    python3 - "$vcs_crypto_file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = path.read_text(errors="ignore")

compat = (
    "\n/* ADDED: OpenSSL 1.0.2 compatibility */\n"
    "#ifndef EVP_CTRL_AEAD_GET_TAG\n"
    "#define EVP_CTRL_AEAD_GET_TAG EVP_CTRL_GCM_GET_TAG\n"
    "#endif\n\n"
    "#ifndef EVP_CTRL_AEAD_SET_TAG\n"
    "#define EVP_CTRL_AEAD_SET_TAG EVP_CTRL_GCM_SET_TAG\n"
    "#endif\n"
)

if "ADDED: OpenSSL 1.0.2 compatibility" not in data:
    include_pos = data.find("#include <openssl/evp.h>")
    if include_pos == -1:
        print(
            f"ERROR: #include <openssl/evp.h> not found in {path}",
            file=sys.stderr,
        )
        sys.exit(1)

    line_end = data.find("\n", include_pos)
    if line_end == -1:
        line_end = len(data)

    data = data[:line_end + 1] + compat + data[line_end + 1:]
    path.write_text(data)

    print(
        f"Applied OpenSSL 1.0.2 AES-model compatibility patch to {path}",
        file=sys.stderr,
    )
else:
    print(
        f"OpenSSL compatibility patch already present in {path}",
        file=sys.stderr,
    )
PY
  else
    echo "VCS 20.09: No AES model OpenSSL patch target was found." >&2
  fi

  if [[ -n "$vcs_cov_file" ]]; then
    echo "VCS 20.09: CSRNG coverage compatibility patch required." >&2
    echo "VCS 20.09: Source file: $vcs_cov_file" >&2

    vcs_cov_backup="$(mktemp)"
    cp "$vcs_cov_file" "$vcs_cov_backup"

    python3 - "$vcs_cov_file" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
data = path.read_text(errors="ignore")
patched = 0

# ADDED: VCS 20.09 compatibility patch #1.
# VCS 20.09 does not accept a function call directly in this bins definition.
old_single_masks = "bins single_exc[] = single_masks(num_hw_apps);"
new_single_masks = (
    "// ADDED: VCS 20.09 compatibility workaround.\n"
    "// VCS 20.09 does not support single_masks() directly in this\n"
    "// coverage bins definition.\n"
    "// bins single_exc[] = single_masks(num_hw_apps);"
)

if old_single_masks in data:
    data = data.replace(old_single_masks, new_single_masks, 1)
    patched += 1
    print(
        "Applied VCS 20.09 CSRNG single_masks() coverage patch.",
        file=sys.stderr,
    )

# ADDED: VCS 20.09 compatibility patch #2.
#
# Generalize the old-VCS workaround to every CSRNG command interface:
# both HW applications (hw0, hw1, ...) and the SW command interface.
#
# Examples:
#
#   !binsof(cp_hw0_cmd_depth) intersect {2}
#   !binsof(cp_hw1_cmd_depth) intersect {2}
#   !binsof(cp_sw_cmd_depth)  intersect {2}
#
# become:
#
#   binsof(cp_<interface>_cmd_depth) intersect {0, 1}
#
# This preserves the intended meaning: "command FIFO is not full".
binsof_rx = re.compile(
    r'!binsof\(cp_(hw\d+|sw)_cmd_depth\)\s+intersect\s+\{2\}'
)

def replace_binsof(match):
    intf = match.group(1)
    return f"binsof(cp_{intf}_cmd_depth) intersect {{0, 1}}"

data, binsof_count = binsof_rx.subn(replace_binsof, data)

if binsof_count:
    patched += binsof_count
    print(
        f"Applied VCS 20.09 CSRNG !binsof() coverage patch "
        f"to {binsof_count} command interface(s).",
        file=sys.stderr,
    )


# ADDED: VCS 20.09 compatibility patch #3.
#
# Generalize the cross-coverage workaround to both HW and SW command
# interfaces.
#
# Original form:
#
#   ignore_bins not_full_and_not_ready =
#       binsof(cp_<interface>_cmd_depth) intersect {0, 1}
#       with (!<interface>_cmd_rdy);
#
# VCS 20.09 resolves <interface>_cmd_rdy as a coverpoint in this cross
# and rejects the logical '!' operator.
#
# Replace it with an explicit bin selection:
#
#   ignore_bins not_full_and_not_ready =
#       binsof(cp_<interface>_cmd_depth) intersect {0, 1} &&
#       binsof(<interface>_cmd_rdy) intersect {0};
#
cross_rx = re.compile(
    r'ignore_bins\s+not_full_and_not_ready\s*=\s*'
    r'binsof\(cp_(hw\d+|sw)_cmd_depth\)\s+intersect\s+\{0,\s*1\}\s*'
    r'with\s*\(\s*!\1_cmd_rdy\s*\)\s*;',
    re.MULTILINE,
)

def replace_cross(match):
    intf = match.group(1)
    return (
        "ignore_bins not_full_and_not_ready = "
        f"binsof(cp_{intf}_cmd_depth) intersect {{0, 1}} &&\n"
        "                                           "
        f"binsof({intf}_cmd_rdy) intersect {{0}};"
    )

data, cross_count = cross_rx.subn(replace_cross, data)

if cross_count:
    patched += cross_count
    print(
        f"Applied VCS 20.09 CSRNG command-ready cross coverage patch "
        f"to {cross_count} command interface(s).",
        file=sys.stderr,
    )

if patched == 0:
    print(
        "VCS 20.09: No CSRNG coverage compatibility statements "
        "were found to patch.",
        file=sys.stderr,
    )
else:
    path.write_text(data)
    print(
        f"Applied {patched} VCS 20.09 CSRNG compatibility patch(es) "
        f"to {path}",
        file=sys.stderr,
    )
PY
  else
    echo \
      "VCS 20.09: No CSRNG coverage compatibility patch was required." \
      >&2
  fi

  # ADDED: Always restore the original CSRNG coverage source
  # and AES model source after the VCS run.
  restore_vcs_sources() {
    if [[ -n "${vcs_cov_backup:-}" &&
          -n "${vcs_cov_file:-}" &&
          -f "$vcs_cov_backup" ]]; then
      cp "$vcs_cov_backup" "$vcs_cov_file"
      rm -f "$vcs_cov_backup"
      echo "VCS 20.09: Restored original CSRNG coverage source." >&2
    fi

    if [[ -n "${vcs_crypto_backup:-}" &&
          -n "${vcs_crypto_file:-}" &&
          -f "$vcs_crypto_backup" ]]; then
      cp "$vcs_crypto_backup" "$vcs_crypto_file"
      rm -f "$vcs_crypto_backup"
      echo "VCS 20.09: Restored original AES model source." >&2
    fi
  }

  trap restore_vcs_sources EXIT INT TERM

  echo \
    "VCS mode: using VCS 20.09 compatibility settings and devtoolset-11." \
    >&2

  set +e
  scl enable devtoolset-11 -- dvsim "${args[@]}"
  vcs_status=$?
  set -e

  restore_vcs_sources
  trap - EXIT INT TERM

  exit "$vcs_status"
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
