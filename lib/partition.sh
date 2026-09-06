#!/usr/bin/env bash
# Partition discovery and the never-predict-a-partition-number safety rule.
#
# parted fills the LOWEST free GPT slot, not 'highest existing + 1'. Any disk
# whose numbering has a hole - exactly what deleting a partition to free space
# leaves behind - hands back a number we did not choose. So: snapshot the
# partition table before, snapshot it after, and derive the new number by
# difference. Never guess it. Guessing is how an installer formats somebody
# else's partition.
#
# Everything here is pure text processing over `parted -ms <dev> unit B print`
# output, so it is fully unit-testable without touching a disk.

# Device path from the header line, e.g. '/dev/vda'. Used to prove that two
# snapshots describe the same disk.
aw_parted_device() {
  printf '%s\n' "$1" | grep -E '^/dev/' | head -1 | cut -d: -f1
}

# Turn parted machine-readable output into tab-separated rows:
#   num  start  end  size  fs  name  flags
#
# Two input shapes have to be handled carefully:
#   * A partition NAME may contain colons ("Recovery: HP_TOOLS"), and awk -F:
#     would shift every field after it. Flags are always last and name always
#     starts at field 6, so the name is rejoined from 6..NF-1.
#   * `parted print free` emits free regions as rows whose first field looks
#     like a partition number ('1:17408B:1048575B:1031168B:free;'). Counting
#     those as partitions makes the set difference meaningless, so they are
#     dropped. This function takes a string, so nothing stops a caller passing
#     `print free` output - it must be safe against it rather than trusting
#     the caller.
aw_parted_parse() {
  printf '%s\n' "$1" \
    | grep -E '^[0-9]+:' \
    | sed 's/;[[:space:]]*$//' \
    | awk -F: '
        {
          if ($NF == "free" || $5 == "free") next
          if (NF < 6) next
          name = $6
          for (i = 7; i <= NF - 1; i++) name = name ":" $i
          flags = (NF >= 7) ? $NF : ""
          printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, $5, name, flags
        }'
}

# The set of partition numbers present, as a SET not a numeric sequence.
#
# Sorted with LC_ALL=C sort -u, deliberately: the only consumer is comm, which
# merges by byte order. Feeding comm numerically-sorted input silently corrupts
# the difference the moment any number reaches two digits (comm sees 11 < 2).
aw_parted_numbers() {
  aw_parted_parse "$1" | cut -f1 | LC_ALL=C sort -u
}

# The safety rule. Returns the single partition number present in `after` but
# not in `before`.
#
# Fails loudly on any of: a different disk, partitions that disappeared, no new
# partition, or more than one. Every one of those means the disk is not in the
# state we believe it is, and continuing risks formatting something we did not
# create.
aw_new_partition_number() {
  local before="$1" after="$2"
  local dev_before dev_after new gone count

  dev_before="$(aw_parted_device "$before")"
  dev_after="$(aw_parted_device "$after")"
  if [ -n "$dev_before" ] && [ -n "$dev_after" ] && [ "$dev_before" != "$dev_after" ]; then
    aw_log error "partition snapshots describe different disks: [$dev_before] then [$dev_after]"
    return 1
  fi

  # Partitions that vanished. This is the catastrophic case, so it is checked
  # before the additive one.
  if ! gone="$(comm -23 \
                <(aw_parted_numbers "$before") \
                <(aw_parted_numbers "$after") 2>/dev/null)"; then
    aw_log error "could not compare partition tables"
    return 1
  fi
  if [ -n "${gone//[[:space:]]/}" ]; then
    aw_log error "partitions disappeared between snapshots: [$(printf '%s' "$gone" | tr '\n' ' ')] - refusing to continue"
    return 1
  fi

  if ! new="$(comm -13 \
               <(aw_parted_numbers "$before") \
               <(aw_parted_numbers "$after") 2>/dev/null)"; then
    aw_log error "could not compare partition tables"
    return 1
  fi

  count="$(printf '%s\n' "$new" | grep -c '^[0-9][0-9]*$' || true)"
  if [ "$count" -ne 1 ]; then
    aw_log error "expected exactly 1 new partition, found $count: [$(printf '%s' "$new" | tr '\n' ' ')]"
    return 1
  fi
  printf '%s\n' "$new" | grep '^[0-9][0-9]*$'
}

# /dev/vda + 1 -> /dev/vda1 ; /dev/nvme0n1 + 1 -> /dev/nvme0n1p1
#
# Anchored on the final path component so that a path merely CONTAINING
# 'loop' or 'nvme' (say /dev/mapper/vgloop0) does not wrongly take the p
# suffix. Only the device's own name decides.
aw_partition_device() {
  local disk="$1" num="$2" base="${1##*/}"
  case "$base" in
    nvme[0-9]*n[0-9]*|mmcblk[0-9]*|loop[0-9]*) printf '%sp%s\n' "$disk" "$num" ;;
    *) printf '%s%s\n' "$disk" "$num" ;;
  esac
}

aw_assert_size_within() {
  local actual="$1" expected="$2" tolerance="$3" delta
  delta=$(( actual > expected ? actual - expected : expected - actual ))
  if [ "$delta" -gt "$tolerance" ]; then
    aw_log error "partition size $actual differs from requested $expected by $delta bytes (tolerance $tolerance)"
    return 1
  fi
  return 0
}
