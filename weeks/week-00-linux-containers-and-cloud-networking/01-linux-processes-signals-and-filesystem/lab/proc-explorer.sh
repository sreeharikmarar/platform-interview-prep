#!/bin/bash
#
# proc-explorer.sh — Explore /proc for a given PID
#
# Usage:
#   ./proc-explorer.sh <PID>
#   ./proc-explorer.sh            (defaults to PID 1)
#
# What this script shows:
#   - Process identity: PID, PPID, command line, executable path
#   - Process state: kernel state, number of threads, scheduler info
#   - Signal disposition: blocked, ignored, and caught signal masks
#     with decoded signal names for the caught/ignored sets
#   - Linux capabilities: all five capability sets decoded to human-readable names
#   - Namespace membership: inode numbers for all six namespaces
#   - Open file descriptors: count, type breakdown, and top entries
#   - Memory layout: RSS, virtual size, and VMA summary
#   - Cgroup membership: which cgroups this process belongs to
#
# Requires:
#   - /proc filesystem (Linux only; will not work on macOS host)
#   - capsh (from libcap2-bin): for human-readable capability decoding
#     Install: apt-get install libcap2-bin  OR  yum install libcap
#
# No root required unless inspecting another user's process that has
# mode 0400 /proc/<pid>/maps (this is rare; most entries are world-readable).

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Argument handling
# ──────────────────────────────────────────────────────────────────────────────

TARGET_PID="${1:-1}"

# Validate PID is a positive integer
if ! [[ "$TARGET_PID" =~ ^[0-9]+$ ]]; then
  echo "Error: PID must be a positive integer, got: $TARGET_PID" >&2
  exit 1
fi

# Verify the process exists
if [[ ! -d "/proc/$TARGET_PID" ]]; then
  echo "Error: No process with PID $TARGET_PID found in /proc" >&2
  exit 1
fi

PROC_DIR="/proc/$TARGET_PID"

# ──────────────────────────────────────────────────────────────────────────────
# Helper: print a section header
# ──────────────────────────────────────────────────────────────────────────────
section() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  $1"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ──────────────────────────────────────────────────────────────────────────────
# Helper: decode a signal bitmask to signal names
# The bitmask has bit N-1 set for signal N (SIGTERM=15 means bit 14).
# ──────────────────────────────────────────────────────────────────────────────
decode_signals() {
  local hex_mask="$1"
  local decimal_mask
  decimal_mask=$(printf '%d' "0x${hex_mask}" 2>/dev/null || echo 0)

  # Signal number to name mapping (POSIX + Linux-specific signals 1-31)
  local -a SIGNAL_NAMES=(
    ""            # index 0 unused (signals start at 1)
    "SIGHUP"      # 1
    "SIGINT"      # 2
    "SIGQUIT"     # 3
    "SIGILL"      # 4
    "SIGTRAP"     # 5
    "SIGABRT"     # 6
    "SIGBUS"      # 7
    "SIGFPE"      # 8
    "SIGKILL"     # 9
    "SIGUSR1"     # 10
    "SIGSEGV"     # 11
    "SIGUSR2"     # 12
    "SIGPIPE"     # 13
    "SIGALRM"     # 14
    "SIGTERM"     # 15
    "SIGSTKFLT"   # 16
    "SIGCHLD"     # 17
    "SIGCONT"     # 18
    "SIGSTOP"     # 19
    "SIGTSTP"     # 20
    "SIGTTIN"     # 21
    "SIGTTOU"     # 22
    "SIGURG"      # 23
    "SIGXCPU"     # 24
    "SIGXFSZ"     # 25
    "SIGVTALRM"   # 26
    "SIGPROF"     # 27
    "SIGWINCH"    # 28
    "SIGIO"       # 29
    "SIGPWR"      # 30
    "SIGSYS"      # 31
  )

  local result=""
  for signum in $(seq 1 31); do
    # Check if bit (signum-1) is set in the mask
    if (( (decimal_mask >> (signum - 1)) & 1 )); then
      local signame="${SIGNAL_NAMES[$signum]:-SIG$signum}"
      result="${result:+$result, }${signame}(${signum})"
    fi
  done

  echo "${result:-none}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Helper: decode a capability bitmask using capsh if available, else hex only
# ──────────────────────────────────────────────────────────────────────────────
decode_caps() {
  local hex_mask="$1"
  local label="$2"

  if command -v capsh &>/dev/null; then
    local decoded
    decoded=$(capsh --decode="$hex_mask" 2>/dev/null | sed 's/^0x[0-9a-f]*=//')
    echo "  $label: 0x$hex_mask"
    echo "    Decoded: $decoded"
  else
    echo "  $label: 0x$hex_mask  (install capsh from libcap2-bin for human-readable names)"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Section 1: Process Identity
# ──────────────────────────────────────────────────────────────────────────────
section "PROCESS IDENTITY"

# Command line (NUL-separated arguments)
cmdline=""
if [[ -r "$PROC_DIR/cmdline" ]]; then
  cmdline=$(tr '\0' ' ' < "$PROC_DIR/cmdline" | sed 's/ $//')
fi
echo "  PID:         $TARGET_PID"
echo "  Command:     ${cmdline:-(kernel thread or cmdline unreadable)}"

# Executable path via exe symlink (may require permission)
if [[ -L "$PROC_DIR/exe" ]]; then
  exe_path=$(readlink "$PROC_DIR/exe" 2>/dev/null || echo "(permission denied)")
  echo "  Executable:  $exe_path"
fi

# PPID and process name from status
if [[ -r "$PROC_DIR/status" ]]; then
  ppid=$(grep "^PPid:" "$PROC_DIR/status" | awk '{print $2}')
  name=$(grep "^Name:" "$PROC_DIR/status" | awk '{print $2}')
  echo "  Name:        $name"
  echo "  PPID:        $ppid"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Section 2: Process State
# ──────────────────────────────────────────────────────────────────────────────
section "PROCESS STATE"

if [[ -r "$PROC_DIR/status" ]]; then
  state_raw=$(grep "^State:" "$PROC_DIR/status" | sed 's/State:\s*//')
  threads=$(grep "^Threads:" "$PROC_DIR/status" | awk '{print $2}')
  voluntary_ctxt=$(grep "^voluntary_ctxt_switches:" "$PROC_DIR/status" | awk '{print $2}')
  nonvoluntary_ctxt=$(grep "^nonvoluntary_ctxt_switches:" "$PROC_DIR/status" | awk '{print $2}')

  echo "  State:                   $state_raw"
  echo "  Threads:                 $threads"
  echo "  Voluntary ctx switches:  ${voluntary_ctxt:-N/A}  (process yielded CPU voluntarily)"
  echo "  Nonvoluntary ctx swit.:  ${nonvoluntary_ctxt:-N/A}  (scheduler preempted the process)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Section 3: Signal Disposition
# ──────────────────────────────────────────────────────────────────────────────
section "SIGNAL DISPOSITION"

if [[ -r "$PROC_DIR/status" ]]; then
  sig_pnd=$(grep "^SigPnd:" "$PROC_DIR/status" | awk '{print $2}')
  sig_blk=$(grep "^SigBlk:" "$PROC_DIR/status" | awk '{print $2}')
  sig_ign=$(grep "^SigIgn:" "$PROC_DIR/status" | awk '{print $2}')
  sig_cgt=$(grep "^SigCgt:" "$PROC_DIR/status" | awk '{print $2}')

  echo "  SigPnd (pending):   0x$sig_pnd"
  if [[ "$sig_pnd" != "0000000000000000" ]]; then
    echo "    Pending signals: $(decode_signals "${sig_pnd: -16}")"
    echo "    WARNING: pending signals mean a signal was sent but not yet delivered"
  fi

  echo ""
  echo "  SigBlk (blocked):   0x$sig_blk"
  if [[ "$sig_blk" != "0000000000000000" ]]; then
    echo "    Blocked signals: $(decode_signals "${sig_blk: -16}")"
  fi

  echo ""
  echo "  SigIgn (ignored):   0x$sig_ign"
  if [[ "$sig_ign" != "0000000000000000" ]]; then
    echo "    Ignored signals: $(decode_signals "${sig_ign: -16}")"
  else
    echo "    Ignored signals: none"
  fi

  echo ""
  echo "  SigCgt (caught):    0x$sig_cgt"
  if [[ "$sig_cgt" != "0000000000000000" ]]; then
    echo "    Caught signals: $(decode_signals "${sig_cgt: -16}")"
  else
    echo "    Caught signals: none"
    echo "    NOTE: If this is PID 1 in a container, SIGTERM will be IGNORED"
    echo "    (no handler = default disposition = ignore for PID 1 in some shells)"
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# Section 4: Linux Capabilities
# ──────────────────────────────────────────────────────────────────────────────
section "LINUX CAPABILITIES"

if [[ -r "$PROC_DIR/status" ]]; then
  cap_inh=$(grep "^CapInh:" "$PROC_DIR/status" | awk '{print $2}')
  cap_prm=$(grep "^CapPrm:" "$PROC_DIR/status" | awk '{print $2}')
  cap_eff=$(grep "^CapEff:" "$PROC_DIR/status" | awk '{print $2}')
  cap_bnd=$(grep "^CapBnd:" "$PROC_DIR/status" | awk '{print $2}')
  cap_amb=$(grep "^CapAmb:" "$PROC_DIR/status" 2>/dev/null | awk '{print $2}' || echo "0000000000000000")

  echo "  Capability sets (hex bitmask; bit N = capability number N):"
  echo "  Full root = 000001ffffffffff; Container default is typically much less."
  echo ""

  # CapEff is the most important: these are the active capabilities
  decode_caps "$cap_eff" "CapEff (effective — currently active for permission checks)"
  echo ""
  decode_caps "$cap_prm" "CapPrm (permitted — max capabilities the process can enable)"
  echo ""
  decode_caps "$cap_bnd" "CapBnd (bounding — hard limit; caps cannot be added beyond this)"
  echo ""
  decode_caps "$cap_inh" "CapInh (inheritable — preserved across execve)"
  echo ""
  decode_caps "$cap_amb" "CapAmb (ambient — granted to exec'd child without file capabilities)"

  # Quick check for specific important capabilities
  echo ""
  echo "  Quick checks (based on CapEff):"
  local_decimal=$(printf '%d' "0x${cap_eff}" 2>/dev/null || echo 0)
  printf "    CAP_NET_ADMIN  (bit 12): %s\n" "$(( (local_decimal >> 12) & 1 )) (1=present, 0=absent)"
  printf "    CAP_SYS_ADMIN  (bit 21): %s\n" "$(( (local_decimal >> 21) & 1 )) (1=present, 0=absent)"
  printf "    CAP_SYS_PTRACE (bit 19): %s\n" "$(( (local_decimal >> 19) & 1 )) (1=present, 0=absent)"
  printf "    CAP_NET_RAW    (bit 13): %s\n" "$(( (local_decimal >> 13) & 1 )) (1=present, 0=absent)"
  printf "    CAP_SYS_MODULE (bit 16): %s\n" "$(( (local_decimal >> 16) & 1 )) (1=present, 0=absent)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Section 5: Namespace Membership
# ──────────────────────────────────────────────────────────────────────────────
section "NAMESPACE MEMBERSHIP"

echo "  Namespace inode numbers (identical inodes = shared namespace):"
echo ""

ns_dir="$PROC_DIR/ns"
if [[ -d "$ns_dir" ]]; then
  for ns_type in pid mnt net uts ipc user cgroup; do
    ns_link="$ns_dir/$ns_type"
    if [[ -L "$ns_link" ]]; then
      ns_target=$(readlink "$ns_link" 2>/dev/null || echo "(unreadable)")
      # Extract the inode number from e.g. "pid:[4026531836]"
      ns_inode=$(echo "$ns_target" | grep -oP '\d+' || echo "unknown")
      printf "    %-10s %s\n" "$ns_type:" "$ns_target"
    fi
  done

  echo ""
  echo "  Compare with your current shell (PID $$):"
  for ns_type in pid mnt net uts; do
    my_link="/proc/$$/ns/$ns_type"
    target_link="$ns_dir/$ns_type"
    if [[ -L "$my_link" && -L "$target_link" ]]; then
      my_ns=$(readlink "$my_link" 2>/dev/null || echo "?")
      target_ns=$(readlink "$target_link" 2>/dev/null || echo "?")
      if [[ "$my_ns" == "$target_ns" ]]; then
        shared="SHARED with your shell"
      else
        shared="DIFFERENT from your shell (isolated)"
      fi
      printf "    %-10s %s\n" "$ns_type:" "$shared"
    fi
  done
fi

# ──────────────────────────────────────────────────────────────────────────────
# Section 6: Open File Descriptors
# ──────────────────────────────────────────────────────────────────────────────
section "OPEN FILE DESCRIPTORS"

fd_dir="$PROC_DIR/fd"
if [[ -d "$fd_dir" && -r "$fd_dir" ]]; then
  fd_count=$(ls "$fd_dir" 2>/dev/null | wc -l)
  echo "  Total open FDs: $fd_count"

  # Count by type
  regular_files=0
  sockets=0
  pipes=0
  devices=0
  anon=0
  other=0

  echo ""
  echo "  FD breakdown (first 20 entries):"
  count=0
  for fd in $(ls "$fd_dir" 2>/dev/null | head -20); do
    target=$(readlink "$fd_dir/$fd" 2>/dev/null || echo "(unreadable)")
    # Classify
    case "$target" in
      socket:*)   sockets=$((sockets + 1));        type="socket" ;;
      pipe:*)     pipes=$((pipes + 1));            type="pipe" ;;
      /dev/*)     devices=$((devices + 1));        type="device" ;;
      anon_inode:*) anon=$((anon + 1));            type="anon_inode" ;;
      /*)         regular_files=$((regular_files + 1)); type="file" ;;
      *)          other=$((other + 1));            type="other" ;;
    esac
    printf "    fd/%-4s -> %s\n" "$fd" "$target"
    count=$((count + 1))
  done

  if [[ "$fd_count" -gt 20 ]]; then
    echo "    ... ($((fd_count - 20)) more FDs not shown)"
  fi

  echo ""
  echo "  Type summary (across all $fd_count FDs):"
  echo "    Regular files: $regular_files"
  echo "    Sockets:       $sockets"
  echo "    Pipes:         $pipes"
  echo "    Device files:  $devices"
  echo "    Anon inodes:   $anon (eventfd, epoll, timerfd, signalfd, etc.)"
  echo "    Other:         $other"

  # Check for FD leak symptoms
  fdlimit=$(grep "^Max open files" "$PROC_DIR/limits" 2>/dev/null | awk '{print $4}' || echo "unknown")
  echo ""
  echo "  ulimit -n (max open files): $fdlimit"
  if [[ "$fdlimit" != "unlimited" && "$fdlimit" != "unknown" ]]; then
    pct=$(( fd_count * 100 / fdlimit ))
    echo "  FD usage: ${pct}% of limit (${fd_count}/${fdlimit})"
    if [[ "$pct" -gt 80 ]]; then
      echo "  WARNING: FD usage above 80% — potential FD leak"
    fi
  fi
else
  echo "  Cannot read $fd_dir (permission denied or process has exited)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Section 7: Memory Usage
# ──────────────────────────────────────────────────────────────────────────────
section "MEMORY USAGE"

if [[ -r "$PROC_DIR/status" ]]; then
  vm_peak=$(grep "^VmPeak:" "$PROC_DIR/status" | awk '{print $2, $3}')
  vm_size=$(grep "^VmSize:" "$PROC_DIR/status" | awk '{print $2, $3}')
  vm_rss=$(grep "^VmRSS:"  "$PROC_DIR/status" | awk '{print $2, $3}')
  vm_swap=$(grep "^VmSwap:" "$PROC_DIR/status" | awk '{print $2, $3}')
  rss_anon=$(grep "^RssAnon:" "$PROC_DIR/status" | awk '{print $2, $3}')
  rss_file=$(grep "^RssFile:" "$PROC_DIR/status" | awk '{print $2, $3}')
  rss_shm=$(grep "^RssShmem:" "$PROC_DIR/status" | awk '{print $2, $3}')

  echo "  VmPeak:   ${vm_peak:-N/A}   (peak virtual memory size)"
  echo "  VmSize:   ${vm_size:-N/A}   (current virtual address space)"
  echo "  VmRSS:    ${vm_rss:-N/A}    (resident set — pages actually in RAM)"
  echo "  VmSwap:   ${vm_swap:-N/A}   (pages swapped to disk)"
  echo ""
  echo "  RSS breakdown:"
  echo "    RssAnon:  ${rss_anon:-N/A}  (anonymous: heap, stack, mmap MAP_ANONYMOUS)"
  echo "    RssFile:  ${rss_file:-N/A}  (file-backed: code, data, mmap files)"
  echo "    RssShmem: ${rss_shm:-N/A}  (shared memory, tmpfs, memfd)"
fi

# Memory maps summary — count VMAs by type
if [[ -r "$PROC_DIR/maps" ]]; then
  total_vmas=$(wc -l < "$PROC_DIR/maps")
  exec_vmas=$(grep -c " ..x" "$PROC_DIR/maps" 2>/dev/null || echo 0)
  stack_vmas=$(grep -c "\[stack\]" "$PROC_DIR/maps" 2>/dev/null || echo 0)
  heap_vmas=$(grep -c "\[heap\]" "$PROC_DIR/maps" 2>/dev/null || echo 0)
  lib_vmas=$(grep -c "\.so" "$PROC_DIR/maps" 2>/dev/null || echo 0)

  echo ""
  echo "  Virtual memory areas (VMAs): $total_vmas total"
  echo "    Executable regions:  $exec_vmas  (r-xp or r-x segments)"
  echo "    Heap:                $heap_vmas  ([heap] region)"
  echo "    Stack:               $stack_vmas  ([stack] region)"
  echo "    Shared libraries:    $lib_vmas  (*.so files mapped in)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Section 8: Cgroup Membership
# ──────────────────────────────────────────────────────────────────────────────
section "CGROUP MEMBERSHIP"

cgroup_file="$PROC_DIR/cgroup"
if [[ -r "$cgroup_file" ]]; then
  echo "  Cgroup hierarchies and paths:"
  echo ""
  while IFS=: read -r hierarchy_id subsystems cgroup_path; do
    if [[ -n "$subsystems" ]]; then
      printf "    hierarchy %-2s subsystems=%-20s path=%s\n" \
        "$hierarchy_id" "$subsystems" "$cgroup_path"
    else
      # cgroups v2: hierarchy 0, empty subsystems, single unified path
      printf "    cgroup v2 unified path: %s\n" "$cgroup_path"
    fi
  done < "$cgroup_file"

  # Check if this looks like a container (non-root cgroup path)
  if grep -q "/kubepods\|/docker\|/containerd\|/crio" "$cgroup_file" 2>/dev/null; then
    echo ""
    echo "  This process appears to be running inside a container."
  elif grep -qE "^0::/\$" "$cgroup_file" 2>/dev/null; then
    echo ""
    echo "  This process is in the root cgroup (likely a host process)."
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# Footer
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  proc-explorer.sh completed for PID $TARGET_PID"
echo "  Data read from: $PROC_DIR/"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
