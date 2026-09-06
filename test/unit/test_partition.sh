#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../.."
# shellcheck source=test/unit/harness.sh
. "$HERE/harness.sh"
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=lib/partition.sh
. "$ROOT/lib/partition.sh"

BLANK='BYT;
/dev/vda:21474836480B:virtblk:512:512:gpt:Virtio Block Device:;'

ONE='BYT;
/dev/vda:21474836480B:virtblk:512:512:gpt:Virtio Block Device:;
1:1048576B:1074790399B:1073741824B:fat32:ESP:boot, esp;'

TWO='BYT;
/dev/vda:21474836480B:virtblk:512:512:gpt:Virtio Block Device:;
1:1048576B:1074790399B:1073741824B:fat32:ESP:boot, esp;
2:1074790400B:21474835967B:20400045568B::archwright:;'

# A disk with a numbering hole - the case the safety rule exists for.
HOLE='BYT;
/dev/vda:21474836480B:virtblk:512:512:gpt:Virtio Block Device:;
1:1048576B:1074790399B:1073741824B:fat32:ESP:boot, esp;
3:5368709120B:21474835967B:16106126848B:ntfs:Windows:msftdata;'

HOLE_FILLED='BYT;
/dev/vda:21474836480B:virtblk:512:512:gpt:Virtio Block Device:;
1:1048576B:1074790399B:1073741824B:fat32:ESP:boot, esp;
2:1074790400B:5368709119B:4293918720B::archwright:;
3:5368709120B:21474835967B:16106126848B:ntfs:Windows:msftdata;'

assert_eq "$(aw_parted_numbers "$BLANK" | tr '\n' ',')" "" "blank disk has no partitions"
assert_eq "$(aw_parted_numbers "$ONE" | tr '\n' ',')" "1," "one partition"
assert_eq "$(aw_parted_numbers "$TWO" | tr '\n' ',')" "1,2," "two partitions"
assert_eq "$(aw_parted_numbers "$HOLE" | tr '\n' ',')" "1,3," "numbering hole preserved"

assert_eq "$(aw_parted_parse "$ONE" | cut -f4)" "1073741824B" "parse: size field"
assert_eq "$(aw_parted_parse "$ONE" | cut -f6)" "ESP" "parse: name field"
assert_eq "$(aw_parted_parse "$ONE" | cut -f7)" "boot, esp" "parse: flags field"

# The core safety rule.
assert_eq "$(aw_new_partition_number "$BLANK" "$ONE")" "1" "first partition is 1"
assert_eq "$(aw_new_partition_number "$ONE" "$TWO")" "2" "second partition is 2"

# parted filled the HOLE at 2, NOT 4. Predicting 'highest existing + 1' would
# have returned 4 - a partition that does not exist - and the run would then
# have formatted whatever it found, or nothing.
assert_eq "$(aw_new_partition_number "$HOLE" "$HOLE_FILLED")" "2" "parted fills the lowest free slot"

assert_fails aw_new_partition_number "$ONE" "$ONE" "no new partition is an error"
assert_fails aw_new_partition_number "$BLANK" "$TWO" "two new partitions is an error"

# Device naming.
assert_eq "$(aw_partition_device /dev/vda 1)" "/dev/vda1" "vd naming"
assert_eq "$(aw_partition_device /dev/sda 2)" "/dev/sda2" "sd naming"
assert_eq "$(aw_partition_device /dev/nvme0n1 1)" "/dev/nvme0n1p1" "nvme naming"
assert_eq "$(aw_partition_device /dev/mmcblk0 3)" "/dev/mmcblk0p3" "mmcblk naming"

# Size tolerance: 1 MiB either way.
if aw_assert_size_within 1073741824 1073741824 1048576; then _pass
else _fail "size exact" "should pass"; fi
if aw_assert_size_within 1073741824 1074266112 1048576; then _pass
else _fail "size within tolerance" "should pass"; fi
assert_fails aw_assert_size_within 1073741824 1090519040 1048576 "size outside tolerance fails"

finish_tests
