#!/system/bin/sh
#
# begonia-layout.sh: find out at boot which partition layout the installed
# ROM uses, and load the matching recovery.fstab and twrp.flags entries.
#
# begonia ROMs come in two layouts:
#   dynamic  Android logical partitions ("super") spread over by-name/system
#            and by-name/vendor, LP metadata on by-name/system
#            (androidboot.super_partition=system)
#   legacy   plain system and vendor partitions (erofs or ext4)
#
# The check reads by-name/system only and fails safe:
#   dynamic  a valid LP geometry at 4096 (or its backup copy at 8192), a
#            valid slot-0 metadata header (primary or backup copy), and no
#            filesystem superblock magic in the first 4 KiB
#   legacy   no LP geometry magic at 4096 or 8192, and an erofs superblock
#            magic at 1024 (e2 e1 f5 e0) or an ext4 one at 1080 (53 ef)
#   unknown  everything else: device missing or unreadable, LP magic that
#            does not validate, valid LP metadata next to a filesystem
#            superblock (stale metadata under a static image), or no magic
#            at all. Nothing is appended, so neither raw nor logical
#            System/Vendor entries exist.
#
# LP format: system/core/fs_mgr/liblp: include/liblp/metadata_format.h
# (LpMetadataGeometry, LpMetadataHeader), reader.cpp ParseGeometry() and
# ReadMetadataHeader(), utility.cpp Get{Primary,Backup}*Offset().
# FlashPartitionTable() (writer.cpp) zeroes the first 4096 bytes, so a
# genuine dynamic layout never has a filesystem superblock there.
#
# Usage:
#   begonia-layout.sh              detect and apply; run once per boot by
#                                  init (init.recovery.mt6785.rc, on init)
#   begonia-layout.sh --check      print the mode (dynamic, legacy or
#                                  unknown) and nothing else; no side effects
#   begonia-layout.sh --check -v   the same, plus the reason on stderr
#
# Apply appends <etc>/recovery.fstab.<mode> and <etc>/twrp.flags.<mode> to
# recovery.fstab and twrp.flags (dynamic and legacy only), sets
# ro.boot.dynamic_partitions=true in dynamic mode only, then sets
# twrp.begonia.layout.reason and, last, twrp.begonia.layout. When
# twrp.begonia.layout is already set it does nothing, so a second run never
# appends twice. If a variant file is missing, the mode becomes unknown.
#
# Tools: the shell (mksh) and toybox/toolbox applets of a TWRP 12.1
# ramdisk only: dd, od, tr, sha256sum, tail, cat, sleep, getprop, setprop.
# Without sha256sum both checksums are skipped (the reason gets "+nosha256")
# and only the structure checks remain.
#
# Test-only environment (init and TWRP never set these):
#   BEGONIA_LAYOUT_DEV   device or image file to read instead of by-name/system
#   BEGONIA_LAYOUT_WAIT  tenths of a second to wait for the device to appear
#                        (default 50 when applying, 0 with --check)
#   BEGONIA_LAYOUT_ETC   directory holding recovery.fstab and twrp.flags
#   BEGONIA_LAYOUT_LOG   log file (default /dev/kmsg)

set -f

GEOMETRY_MAGIC=67446c61	# LP_METADATA_GEOMETRY_MAGIC 0x616c4467, little-endian
HEADER_MAGIC=30504c41	# LP_METADATA_HEADER_MAGIC 0x414C5030
EROFS_MAGIC=e2e1f5e0	# EROFS_SUPER_MAGIC_V1 0xE0F5E1E2 at 1024
EXT4_MAGIC=53ef		# EXT4_SUPER_MAGIC 0xEF53 at 1080

dev=
mode=unknown
reason=
have_sha=0
command -v sha256sum >/dev/null 2>&1 && have_sha=1

# rd OFFSET COUNT: COUNT bytes of $dev at OFFSET as hex tokens; fewer on a
# short read, none on an error
rd() {
	dd if="$dev" bs=1 skip="$1" count="$2" 2>/dev/null | od -An -v -tx1
}

# hx OFFSET COUNT: the same bytes as one hex string
hx() {
	rd "$1" "$2" | tr -d ' \n'
}

# u24 B0 B1 B2 B3: a little-endian u32 in decimal if it is below 2^24,
# otherwise nothing. Keeps mksh's 32-bit arithmetic away from overflow.
u24() {
	[ "$4" = 00 ] && echo $((0x$3$2$1))
}

# sum0 OFFSET SIZE CKOFF: sha256 of SIZE bytes at OFFSET, with the 32-byte
# checksum field at OFFSET+CKOFF read as zeroes (as liblp computes it)
sum0() {
	{
		dd if="$dev" bs=1 skip="$1" count="$3"
		dd if=/dev/zero bs=32 count=1
		dd if="$dev" bs=1 skip=$(($1 + $3 + 32)) count=$(($2 - $3 - 32))
	} 2>/dev/null | sha256sum 2>/dev/null
}

# cksum_ok OFFSET SIZE CKOFF: 0 if the stored checksum matches; always 0
# without sha256sum
cksum_ok() {
	[ $have_sha = 1 ] || return 0
	ck_want=$(hx $(($1 + $3)) 32)
	ck_got=$(sum0 "$1" "$2" "$3")
	ck_got=${ck_got%% *}
	[ ${#ck_want} -eq 64 ] && [ "$ck_got" = "$ck_want" ]
}

# geom OFFSET: 0 if a valid LpMetadataGeometry sits at OFFSET; sets g_max
# and g_slots, or g_why on failure. The checks of liblp ParseGeometry()
# (magic, struct_size 52, checksum, slot count not 0, metadata_max_size a
# multiple of 512) plus sanity limits: metadata_max_size and
# logical_block_size non-zero multiples of 512 below 16 MiB, slot count 1-3.
geom() {
	g_off=$1
	g_max= g_slots= g_lbs=
	set -- $(rd "$g_off" 52)
	if [ $# -ne 52 ]; then g_why=short; return 1; fi
	if [ "$1$2$3$4" != $GEOMETRY_MAGIC ]; then g_why=magic; return 1; fi
	if [ "$5$6$7$8" != 34000000 ]; then g_why=struct_size; return 1; fi
	shift 40
	g_max=$(u24 $1 $2 $3 $4)
	g_slots=$(u24 $5 $6 $7 $8)
	g_lbs=$(u24 $9 ${10} ${11} ${12})
	case $g_max in ''|0) g_why=metadata_max_size; return 1 ;; esac
	if [ $((g_max % 512)) -ne 0 ]; then g_why=metadata_max_size; return 1; fi
	case $g_slots in 1|2|3) ;; *) g_why=metadata_slot_count; return 1 ;; esac
	case $g_lbs in ''|0) g_why=logical_block_size; return 1 ;; esac
	if [ $((g_lbs % 512)) -ne 0 ]; then g_why=logical_block_size; return 1; fi
	if ! cksum_ok "$g_off" 52 8; then g_why=checksum; return 1; fi
	return 0
}

# hdr OFFSET: 0 if a valid LpMetadataHeader sits at OFFSET; sets h_why on
# failure. The first checks of liblp ReadMetadataHeader(): magic, major
# version 10, minor version 0-2, header_size 128 (10.0, 10.1) or 256
# (10.2), header checksum; plus tables_size <= metadata_max_size
# (ParseMetadata()). Needs g_max from geom.
hdr() {
	h_off=$1
	set -- $(rd "$h_off" 48)
	if [ $# -ne 48 ]; then h_why=short; return 1; fi
	if [ "$1$2$3$4" != $HEADER_MAGIC ]; then h_why=magic; return 1; fi
	case $5$6$7$8 in
	0a000000|0a000100) h_len=128 h_size=80000000 ;;
	0a000200) h_len=256 h_size=00010000 ;;
	*) h_why=version; return 1 ;;
	esac
	if [ "$9${10}${11}${12}" != $h_size ]; then h_why=header_size; return 1; fi
	h_tables=$(u24 ${45} ${46} ${47} ${48})
	if [ -z "$h_tables" ] || [ "$h_tables" -gt "$g_max" ]; then
		h_why=tables_size; return 1
	fi
	if ! cksum_ok "$h_off" $h_len 12; then h_why=checksum; return 1; fi
	return 0
}

# find_dev WAIT: set dev to the first candidate that exists, waiting up to
# WAIT tenths of a second for one to appear
find_dev() {
	fd_wait=$1
	case $fd_wait in ''|*[!0-9]*) fd_wait=0 ;; esac
	if [ -n "${BEGONIA_LAYOUT_DEV:-}" ]; then
		set -- "$BEGONIA_LAYOUT_DEV"
	else
		set -- /dev/block/by-name/system \
			/dev/block/platform/bootdevice/by-name/system
	fi
	fd_n=0
	while :; do
		for fd_d in "$@"; do
			if [ -e "$fd_d" ]; then dev=$fd_d; return 0; fi
		done
		[ $fd_n -ge $fd_wait ] && return 1
		sleep 0.1
		fd_n=$((fd_n + 1))
	done
}

# detect WAIT: set mode and reason
detect() {
	mode=unknown
	if ! find_dev "$1"; then reason=nodev; return; fi
	if [ ! -r "$dev" ] || [ -z "$(hx 0 1)" ]; then reason=noread; return; fi

	fs=none
	if [ "$(hx 1024 4)" = $EROFS_MAGIC ]; then
		fs=erofs
	elif [ "$(hx 1080 2)" = $EXT4_MAGIC ]; then
		fs=ext4
	fi

	if [ "$(hx 4096 4)" != $GEOMETRY_MAGIC ] &&
	   [ "$(hx 8192 4)" != $GEOMETRY_MAGIC ]; then
		if [ $fs = none ]; then
			reason=nomagic
		else
			mode=legacy reason=$fs
		fi
		return
	fi

	# LP geometry magic present: never legacy from here on.
	lp_check
	[ $have_sha = 1 ] || reason=$reason+nosha256
}

# lp_check: dynamic if the LP metadata validates and no filesystem
# superblock sits in the reserved first 4 KiB; the reason names what failed
# in the primary/backup copy
lp_check() {
	if geom 4096; then
		:
	elif why1=$g_why; geom 8192; then
		:
	else
		reason=lp-geometry:$why1/$g_why
		return
	fi
	# slot 0: primary copy right after the two geometry copies, backup
	# copy after all primary slots
	if hdr 12288; then
		:
	elif why1=$h_why; hdr $((12288 + g_max * g_slots)); then
		:
	else
		reason=lp-header:$why1/$h_why
		return
	fi
	if [ $fs = none ]; then
		mode=dynamic reason=lp
	else
		reason=lp+$fs
	fi
}

log() {
	echo "begonia-layout: $*" 2>/dev/null >>"${BEGONIA_LAYOUT_LOG:-/dev/kmsg}"
}

apply() {
	etc=${BEGONIA_LAYOUT_ETC:-/system/etc}
	prev=$(getprop twrp.begonia.layout 2>/dev/null)
	if [ -n "$prev" ]; then
		log "already ran (layout=$prev), nothing to do"
		return 0
	fi

	detect "${BEGONIA_LAYOUT_WAIT:-50}"

	if [ $mode != unknown ]; then
		for f in recovery.fstab twrp.flags; do
			if [ ! -f "$etc/$f" ] || [ ! -f "$etc/$f.$mode" ]; then
				log "missing $etc/$f or $etc/$f.$mode"
				reason=$reason,missing-$f.$mode
				mode=unknown
				break
			fi
		done
	fi
	if [ $mode != unknown ]; then
		for f in recovery.fstab twrp.flags; do
			# end the base file's last line before appending
			[ -n "$(tail -c 1 "$etc/$f")" ] && echo >>"$etc/$f"
			cat "$etc/$f.$mode" >>"$etc/$f" || log "appending $f.$mode failed"
		done
	fi

	if [ $mode = dynamic ]; then
		setprop ro.boot.dynamic_partitions true ||
			log "setprop ro.boot.dynamic_partitions failed"
	fi
	setprop twrp.begonia.layout.reason "$reason"
	setprop twrp.begonia.layout $mode || log "setprop twrp.begonia.layout failed"
	log "layout=$mode reason=$reason dev=${dev:-none}"
}

case $# in
0)
	apply
	;;
*)
	case $1 in
	--check)
		detect "${BEGONIA_LAYOUT_WAIT:-0}"
		if [ "${2:-}" = -v ]; then
			echo "begonia-layout: layout=$mode reason=$reason dev=${dev:-none}" >&2
		fi
		echo $mode
		;;
	*)
		echo "usage: begonia-layout.sh [--check [-v]]" >&2
		exit 2
		;;
	esac
	;;
esac
exit 0
