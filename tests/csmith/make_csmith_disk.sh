#!/usr/bin/env bash
# make_csmith_disk.sh <mega-elf> <out-dir>
#
# Build the SCSI-disk csmith vehicle from a mega Linux binary (build_mega_linux.sh):
#   <out-dir>/csmith_disk.img   -- the mega binary raw at offset 0, padded to 512B
#   <out-dir>/csmith_golden.txt  -- golden checksums (uppercase, in order)
#   <out-dir>/csmith_init.sh     -- initramfs /init that LOOP-reads the mega from
#                                   /dev/sda (SCSI DMA) -> exec -> diff checksums vs
#                                   the (initramfs-resident, uncorrupted) golden.
#
# Point mips-axi at the disk with  SCSIDISK=<...>/csmith_disk.img  so it's /dev/sda.
# A checksum mismatch or short run == a caught SCSI-read (or mapped-exec) corruption.
set -u
MEGA=${1:?usage: make_csmith_disk.sh <mega-elf> <out-dir>}
OUTD=${2:?usage: make_csmith_disk.sh <mega-elf> <out-dir>}
mkdir -p "$OUTD"

SZ=$(stat -c%s "$MEGA")
BLKS=$(( (SZ + 511) / 512 ))
cp "$MEGA" "$OUTD/csmith_disk.img"
truncate -s $((BLKS * 512)) "$OUTD/csmith_disk.img"

# golden checksums only (uppercase, in mega print order)
grep -E "^TEST" "$MEGA.golden" | awk '{ck=$3; sub("ref=","",ck); print toupper(ck)}' > "$OUTD/csmith_golden.txt"
NG=$(wc -l < "$OUTD/csmith_golden.txt")

cat > "$OUTD/csmith_init.sh" <<EOF
#!/bin/busybox sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
/bin/busybox --install -s
mount -t proc  proc  /proc 2>/dev/null
mount -t sysfs sysfs /sys  2>/dev/null
mknod /dev/sda b 8 0 2>/dev/null
MEGABLKS=$BLKS
NG=$NG
echo "=== CSMITH DISK TEST START (blks=\$MEGABLKS tests=\$NG) ==="
iter=1
while [ \$iter -le 200 ]; do
  dd if=/dev/sda of=/tmp/mega bs=512 count=\$MEGABLKS 2>/dev/null
  chmod +x /tmp/mega
  /tmp/mega > /tmp/out 2>&1
  awk '/checksum =/{print toupper(\$3)}' /tmp/out > /tmp/got.txt
  NGOT=\$(wc -l < /tmp/got.txt)
  if [ "\$NGOT" -lt "\$NG" ]; then
    echo "ITER \$iter: *** SHORT/CRASH (\$NGOT/\$NG checksums) ***"
    head -40 /tmp/out
  elif ! diff /csmith_golden.txt /tmp/got.txt >/dev/null 2>&1; then
    echo "ITER \$iter: *** CHECKSUM MISMATCH ***"
    paste /csmith_golden.txt /tmp/got.txt | awk 'NR{if(\$1!=\$2)print "  test "NR-1": golden="\$1" got="\$2}'
  else
    echo "ITER \$iter: OK (\$NG tests)"
  fi
  iter=\$((iter + 1))
done
echo "=== CSMITH DISK TEST DONE ==="
exec setsid cttyhack sh
EOF
chmod +x "$OUTD/csmith_init.sh"

echo "wrote $OUTD/csmith_disk.img ($BLKS blocks), csmith_golden.txt ($NG tests), csmith_init.sh"
