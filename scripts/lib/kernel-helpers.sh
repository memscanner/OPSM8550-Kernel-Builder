#!/usr/bin/env bash
#
# Shared helper functions used by the kernel build pipeline.
# This file is sourced, not executed.
#

# ---- Small utilities ---------------------------------------------------------

ensure_line_in_file() {
  local file="$1"
  local line="$2"
  grep -qxF "$line" "$file" || printf '%s\n' "$line" >> "$file"
}

insert_line_before_first_match() {
  local file="$1"
  local match_line="$2"
  local insert_line="$3"
  local tmp_file

  grep -qxF "$insert_line" "$file" && return 0

  tmp_file="$(mktemp)"
  awk -v match_line="$match_line" -v insert_line="$insert_line" '
    !inserted && $0 == match_line {
      print insert_line
      inserted = 1
    }
    { print }
    END {
      if (!inserted) {
        print insert_line
      }
    }
  ' "$file" > "$tmp_file"
  mv "$tmp_file" "$file"
}

detect_kernelsu_driver_dir() {
  if test -d "common/drivers"; then
    echo "common/drivers"
  elif test -d "drivers"; then
    echo "drivers"
  else
    return 1
  fi
}

kernelsu_kconfig_source_path() {
  local driver_dir="$1"
  echo "${driver_dir}/kernelsu/Kconfig"
}

# ---- defconfig / .config manipulation ---------------------------------------

set_config_value() {
  local config_file="$1"
  local key="$2"
  local value="$3"

  if [[ "$value" == "n" ]]; then
    if grep -q "^${key}=" "$config_file"; then
      sed -i "s|^${key}=.*|# ${key} is not set|" "$config_file"
    elif grep -q "^# ${key} is not set$" "$config_file"; then
      :
    else
      echo "# ${key} is not set" >> "$config_file"
    fi
  else
    if grep -q "^${key}=" "$config_file"; then
      sed -i "s|^${key}=.*|${key}=${value}|" "$config_file"
    elif grep -q "^# ${key} is not set$" "$config_file"; then
      sed -i "s|^# ${key} is not set$|${key}=${value}|" "$config_file"
    else
      echo "${key}=${value}" >> "$config_file"
    fi
  fi
}

enable_config_values() {
  local config_file="$1"
  shift
  local key
  for key in "$@"; do
    set_config_value "$config_file" "$key" y
  done
}

disable_config_values() {
  local config_file="$1"
  shift
  local key
  for key in "$@"; do
    set_config_value "$config_file" "$key" n
  done
}

enable_susfs_configs() {
  local config_file="$1"
  enable_config_values "$config_file" \
    CONFIG_KSU_SUSFS \
    CONFIG_KSU_SUSFS_SUS_PATH \
    CONFIG_KSU_SUSFS_SUS_MOUNT \
    CONFIG_KSU_SUSFS_SUS_KSTAT \
    CONFIG_KSU_SUSFS_SPOOF_UNAME \
    CONFIG_KSU_SUSFS_ENABLE_LOG \
    CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT \
    CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
  disable_config_values "$config_file" \
    CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
}

enable_ksu_common_configs() {
  local config_file="$1"
  enable_config_values "$config_file" CONFIG_TMPFS_XATTR
}

enable_resukisu_kpm_configs() {
  local config_file="$1"
  enable_config_values "$config_file" \
    CONFIG_KPM \
    CONFIG_KALLSYMS \
    CONFIG_KALLSYMS_ALL
}

# ---------------------------------------------------------------------------
# ftrace levels -- a bisection in progress, on a device that keeps its stock
# vendor_dlkm (388 modules, CONFIG_MODVERSIONS=y, so symbol CRCs are enforced).
#
# Measured on ingres (SM8450):
#
#   none                                            -> BOOTS, verified working
#   FUNCTION_TRACER DYNAMIC_FTRACE FTRACE_SYSCALLS
#     STACK_TRACER DEBUG_FS                         -> does NOT boot
#   FUNCTION_TRACER DYNAMIC_FTRACE FTRACE_SYSCALLS
#     STACK_TRACER            (no DEBUG_FS)         -> does NOT boot
#
# The second result rules out the theory that DEBUG_FS alone was responsible,
# even though it was the option with the most outside evidence against it
# (the vendor's debugfs.config disables it deliberately, and AOSP documents
# enabling debugfs under "intrusive downstream debug features" with an
# ABI-mismatch warning). Something in the remaining four also breaks boot.
#
# Not variables -- the stock config already has these, and level "none" still
# gives you tracefs at /sys/kernel/tracing with ~1700 static tracepoints:
#   CONFIG_TRACING=y  CONFIG_TRACING_SUPPORT=y  CONFIG_FTRACE=y
#
# Next suspect, hence the "func" level: CONFIG_FTRACE_SYSCALLS. It generates
# trace-event metadata for every syscall, touching the trace_event_call and
# syscall_metadata structures -- and Qualcomm's vendor modules use tracepoints
# heavily. It is the only one of the four that plausibly reaches structures
# the modules themselves also see.
#
# By contrast STACK_TRACER only adds kernel/trace/trace_stack.c and registers
# a function hook; DYNAMIC_FTRACE cannot exist without FUNCTION_TRACER and
# actually reduces runtime cost. FUNCTION_TRACER itself changes code
# generation for every function rather than any struct layout, so if "func"
# also fails to boot, ftrace and a stock vendor_dlkm are simply incompatible
# here and there is no middle ground left to find.
#
# FTRACE_LEVEL:
#   none  -> touch nothing, keep the vendor config exactly as merged
#   func  -> FUNCTION_TRACER + DYNAMIC_FTRACE + STACK_TRACER   (DEFAULT)
#   trace -> func + FTRACE_SYSCALLS          (does not boot on ingres)
#   full  -> trace + DEBUG_FS                (does not boot on ingres)
# ---------------------------------------------------------------------------
enable_ftrace_debug_configs() {
  local config_file="$1"
  local level="${FTRACE_LEVEL:-func}"

  case "$level" in
    none)
      echo "[i] FTRACE_LEVEL=none: leaving the vendor tracing config untouched."
      return 0
      ;;
    func|trace|full)
      ;;
    *)
      echo "::error::Unknown FTRACE_LEVEL '${level}' (expected none|func|trace|full)"
      exit 1
      ;;
  esac

  # Parent symbols matter as much as the leaves: FUNCTION_TRACER depends on
  # FTRACE, which depends on TRACING_SUPPORT. olddefconfig silently drops any
  # symbol whose dependencies are unmet.
  enable_config_values "$config_file" \
    CONFIG_TRACING_SUPPORT \
    CONFIG_FTRACE \
    CONFIG_TRACING \
    CONFIG_GENERIC_TRACER \
    CONFIG_FUNCTION_TRACER \
    CONFIG_DYNAMIC_FTRACE \
    CONFIG_STACK_TRACER

  echo "[+] FTRACE_LEVEL=${level}: FUNCTION_TRACER + DYNAMIC_FTRACE + STACK_TRACER"
  echo "    Tracing interface: /sys/kernel/tracing"

  if [[ "$level" == "trace" || "$level" == "full" ]]; then
    enable_config_values "$config_file" CONFIG_FTRACE_SYSCALLS
    echo "[!] + CONFIG_FTRACE_SYSCALLS. This has been observed NOT to boot on"
    echo "[!] ingres with the stock vendor_dlkm."
  fi

  if [[ "$level" == "full" ]]; then
    enable_config_values "$config_file" CONFIG_DEBUG_FS
    echo "[!] + CONFIG_DEBUG_FS, overriding the vendor's debugfs.config."
    echo "[!] Also observed NOT to boot on ingres."
  fi
}

# ---------------------------------------------------------------------------
# BTF (BPF Type Format) -- kernel type info exposed at /sys/kernel/btf/vmlinux,
# needed by BPF CO-RE tools and anything that wants struct layouts at runtime.
#
# Only adds a .BTF section; struct layouts, symbol CRCs and therefore the
# stock vendor_dlkm ABI are untouched. Requires pahole on the build host
# (dwarves); the tree's scripts/pahole-flags.sh passes
# --skip_encoding_btf_enum64 for pahole >= 1.24, which 5.10 needs.
#
# DEBUG_INFO_BTF=true|false (default true)
# ---------------------------------------------------------------------------
enable_btf_configs() {
  local config_file="$1"

  if [[ "${DEBUG_INFO_BTF:-true}" != "true" ]]; then
    echo "[i] DEBUG_INFO_BTF=false: leaving BTF config untouched."
    return 0
  fi

  enable_config_values "$config_file" \
    CONFIG_DEBUG_INFO \
    CONFIG_DEBUG_INFO_BTF
  # Either of these makes DEBUG_INFO_BTF's dependencies unmet, and
  # olddefconfig would then silently drop it.
  disable_config_values "$config_file" \
    CONFIG_DEBUG_INFO_REDUCED \
    CONFIG_DEBUG_INFO_SPLIT

  echo "[+] Enabled CONFIG_DEBUG_INFO_BTF (-> /sys/kernel/btf/vmlinux)."
}

# 5.10's resolve_btfids aborts the vmlinux link on any BTF_ID() whose target
# is missing from BTF. Under LTO, pahole leaves out functions whose prototype
# it cannot trust (seen: vfs_fallocate, from bpf_d_path's allowlist), so the
# link fails with "FAILED unresolved symbol vfs_fallocate". Upstream changed
# this to a warning that patches in ID 0 ("tools/resolve_btfids: Emit warnings
# and patch zero id for missing symbols"); apply the same change here. The
# only effect of ID 0 is that the allowlist entry matches nothing, and a
# function that is absent from BTF cannot be attached to anyway.
patch_resolve_btfids_lenient() {
  local f="tools/bpf/resolve_btfids/main.c"

  [[ -f "$f" ]] || { echo "[i] ${f} not found; skipping resolve_btfids patch."; return 0; }
  if grep -q 'WARN: resolve_btfids: unresolved symbol' "$f"; then
    echo "[i] resolve_btfids already warns on unresolved symbols."
    return 0
  fi

  perl -0pi -e 's/\tif \(!id->id\) \{\n\t\tpr_err\("FAILED unresolved symbol %s\\n", id->name\);\n\t\treturn -EINVAL;\n\t\}\n/\tif (!id->id)\n\t\tpr_err("WARN: resolve_btfids: unresolved symbol %s\\n", id->name);\n/' "$f"

  if grep -q 'FAILED unresolved symbol' "$f"; then
    echo "::error::Could not patch ${f}; the unresolved-symbol check changed shape."
    grep -n -B2 -A3 'unresolved symbol' "$f" || true
    exit 1
  fi
  echo "[+] resolve_btfids: unresolved BTF_ID symbols now warn instead of failing."
}

apply_variant_configs() {
  local config_file="$1"

  enable_ftrace_debug_configs "$config_file"
  enable_btf_configs "$config_file"

  if [[ "$KSU_TYPE" == *susfs* ]]; then
    enable_susfs_configs "$config_file"
  fi

  if [[ "$KSU_TYPE" != "None" ]]; then
    enable_ksu_common_configs "$config_file"
  fi

  if [[ "$KSU_TYPE" == "ReSukiSU-with-susfs-KPM" ]]; then
    enable_resukisu_kpm_configs "$config_file"
  fi
}

require_config_enabled() {
  local config_file="$1"
  local key="$2"

  if ! grep -q "^${key}=y$" "$config_file"; then
    echo "::error::Expected ${key}=y in ${config_file}, but it was not enabled."
    grep -n "${key}" "$config_file" || true
    exit 1
  fi
}

require_config_disabled() {
  local config_file="$1"
  local key="$2"

  if grep -q "^${key}=y$" "$config_file"; then
    echo "::error::Expected ${key} to stay disabled in ${config_file}, but it is enabled."
    grep -n "${key}" "$config_file" || true
    exit 1
  fi
}
