#!/bin/bash
# BlackFlag DNF bootstrap driver.
#
#   ./build-all.sh            run every stage in order
#   ./build-all.sh 30 40      run only those stages
#   BF_JOBS=4 ./build-all.sh  override parallelism
#
# Stages are resumable: each package drops a stamp in work/stamps/, and a stage
# that finds a stamp skips that package.  Delete a stamp to force a rebuild.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/common.sh"

[ "$(id -u)" -eq 0 ] || die "must run as root (installs into /usr)"

ALL="00 10 20 30 40 50 60"
WANT="${*:-$ALL}"

start=$(date +%s)
for s in $WANT; do
    script=$(ls "$HERE/stages/${s}-"*.sh 2>/dev/null | head -1)
    [ -n "$script" ] || die "no stage script for '$s'"
    echo
    echo -e "${C_B}#################### STAGE $s : $(basename "$script") ####################${C_N}"
    bash "$script" || die "stage $s failed"
done
echo
msg "bootstrap finished in $(( ($(date +%s) - start) / 60 )) min"
