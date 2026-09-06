#!/usr/bin/env bash
# Partition discovery and the never-predict-a-partition-number safety rule.
#
# parted fills the LOWEST free GPT slot, not 'highest existing + 1'. Any disk
# whose numbering has a hole - exactly what deleting a partition to free space
# leaves behind - hands back a number we did not choose. So: snapshot the
# partition table before, snapshot it after, and derive the new number by
# difference. Never guess it. Guessing is how an installer formats somebody
# else's partition.

# Turn `parted -ms <dev> unit B print` output into tab-separated rows.
# Input lines look like:
#   1:1048576B:1074790399B:1073741824B:fat32:ESP:boot, esp;
aw_parted_parse() {
  printf '%s\n' "$1" \
    | grep -E '^[0-9]+:' \
    | sed 's/;[[:space:]]*$//' \
    | awk -F: '{
        printf "%s", $1
        for (i = 2; i <= NF; i++) printf "\t%s", $i
        printf "\n"
      }'
}

aw_parted_numbers() {
  aw_parted_parse "$1" | cut -f1 | sort -n
}

# The safety rule. Returns the single partition number present in `after` but
# not in `before`. Fails loudly on zero or more than one: both mean the disk is
# not in the state we believe it is, and continuing risks formatting something
# we did not create.
aw_new_partition_number() {
  local before="$1" after="$2" new count
  new="$(comm -13 \
          <(aw_parted_numbers "$before") \
          <(aw_parted_numbers "$after"))"
  count="$(printf '%s' "$new" | grep -c '[0-9]' || true)"
  if [ "$count" -ne 1 ]; then
    aw_log error "expected exactly 1 new partition, found $count: [$(printf '%s' "$new" | tr '\n' ' ')]"
    return 1
  fi
  printf '%s\n' "$new"
}

# /dev/vda + 1 -> /dev/vda1 ; /dev/nvme0n1 + 1 -> /dev/nvme0n1p1
aw_partition_device() {
  local disk="$1" num="$2"
  case "$disk" in
    *nvme*n[0-9]*|*mmcblk[0-9]*|*loop[0-9]*) printf '%sp%s\n' "$disk" "$num" ;;
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
