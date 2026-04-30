#!/bin/bash
# Minimal standalone reproducer for a CMake/Ninja rpath-link reorder bug:
# the first reconfigure after a successful from-scratch build flips the
# order of paths in the auto-emitted -Wl,-rpath-link, flag, causing ninja
# to relink consumers.  Subsequent reconfigures are stable (the relinked
# command line agrees with the post-flip order, and the shadow file that
# triggered the flip stays on disk).
#
# Root cause is in cmOrderDirectoriesConstraint::FileMayConflict() in
# Source/cmOrderDirectories.cxx: it reads the filesystem to decide whether
# to add a conflict edge to the DFS topological sort that orders the
# rpath-link directories.  When the build copies a shadow of an external's
# transitive runtime dep into the in-tree shared-lib directory, that
# function flips its return value between the first and second configure.

set -euo pipefail
cd "$(dirname "$0")"

BUILD_ROOT="${BUILD_ROOT:-/tmp/rpath_reorder_min}"
EXT_DIR="${BUILD_ROOT}/ext_install"
BUILD_DIR="${BUILD_ROOT}/build"

CMAKE="${CMAKE:-cmake}"
NINJA="${NINJA:-ninja}"

banner() { printf '\n=== %s ===\n' "$*"; }

banner "Wipe ${BUILD_ROOT}"
rm -rf "${BUILD_ROOT}"
mkdir -p "${EXT_DIR}"

banner "Build the prebuilt 'external' libs.
       libext.so.1 has libext_internal.so.1 as a NEEDED entry, but
       libext_internal is not on the consumer's link line — so when CMake
       walks deps, the consumer must put EXT_DIR into -Wl,-rpath-link, for
       indirect-symbol resolution."
gcc -fPIC -shared -Wl,-soname,libext_internal.so.1 \
    -o "${EXT_DIR}/libext_internal.so.1" ext_src/ext_internal.c
gcc -fPIC -shared -Wl,-soname,libext.so.1 \
    -o "${EXT_DIR}/libext.so.1" ext_src/ext.c \
    "${EXT_DIR}/libext_internal.so.1"

banner "Configure 1 (from-scratch)"
"${CMAKE}" -S . -B "${BUILD_DIR}" -G Ninja -DEXT_DIR="${EXT_DIR}"

banner "Build"
"${CMAKE}" --build "${BUILD_DIR}"

banner "Snapshot 1: build.ninja after the from-scratch configure+build"
cp "${BUILD_DIR}/build.ninja" "${BUILD_ROOT}/build.ninja.cfg1"

banner "Confirm ninja sees no work"
"${NINJA}" -C "${BUILD_DIR}" -n -d explain || true

banner "Configure 2 (the trigger — no source changes)"
"${CMAKE}" -S . -B "${BUILD_DIR}" -G Ninja -DEXT_DIR="${EXT_DIR}"

banner "Snapshot 2: build.ninja after the second configure"
cp "${BUILD_DIR}/build.ninja" "${BUILD_ROOT}/build.ninja.cfg2"

banner "ninja -n -d explain after configure 2"
"${NINJA}" -C "${BUILD_DIR}" -n -d explain 2>&1 \
    | grep -E '^(ninja explain|\[)' || true

banner "rpath-link lines that differ between cfg1 and cfg2"
DIFF="${BUILD_ROOT}/build.ninja.diff"
diff "${BUILD_ROOT}/build.ninja.cfg1" "${BUILD_ROOT}/build.ninja.cfg2" \
    > "${DIFF}" || true
if grep -qE '^[<>] *.*rpath-link' "${DIFF}"; then
    grep -E '^[<>] *.*rpath-link' "${DIFF}"
    echo
    echo "*** BUG REPRODUCED: rpath-link order flipped between configures ***"
    exit 0
else
    echo "(no rpath-link diff in build.ninja — bug did NOT reproduce)"
    exit 1
fi
