cmake_minimum_required(VERSION 3.20)
project(rpath_reorder_min C)

set(CMAKE_BUILD_TYPE Debug)

# Switch CMake from baking DT_RPATH to emitting -Wl,-rpath-link, for
# link-time indirect-symbol resolution.  This is what puts the bug in the
# open: the rpath-link directory list is computed by an order-sensitive
# topological sort whose conflict graph is filesystem-dependent.
set(CMAKE_SKIP_RPATH ON)

set(IN_TREE_DIR "${CMAKE_BINARY_DIR}/in_tree_lib")

# Two in-tree shared libs.  `inner` PRIVATE-links `inner_priv`, so
# libinner.so.1 has libinner_priv.so.1 as a NEEDED entry but inner_priv is
# not exposed to consumers.  When `consumer` is linked against `inner`
# directly, the linker reads libinner.so.1, sees it NEEDS libinner_priv.so.1,
# and must search for it for indirect-symbol resolution — which is what
# forces CMake to add IN_TREE_DIR to the auto-emitted -Wl,-rpath-link, list.
add_library(inner_priv SHARED src/inner_priv.c)
set_target_properties(inner_priv PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${IN_TREE_DIR}"
    VERSION 1.0  SOVERSION 1)

add_library(inner SHARED src/inner.c)
set_target_properties(inner PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${IN_TREE_DIR}"
    VERSION 1.0  SOVERSION 1)
target_link_libraries(inner PRIVATE inner_priv)

# One imported external `Ext` whose IMPORTED_LINK_DEPENDENT_LIBRARIES
# property names a sibling `Ext_internal` in the same external dir.
# Ext_internal is the SONAME-bearing lib that flows through
# cmOrderDirectoriesConstraint::FileMayConflict() — it's a transitive
# runtime dep of Ext, not on the consumer's direct link line, so its dir
# must be added to rpath-link.
add_library(Ext_internal SHARED IMPORTED GLOBAL)
set_target_properties(Ext_internal PROPERTIES
    IMPORTED_LOCATION "${EXT_DIR}/libext_internal.so.1"
    IMPORTED_SONAME   libext_internal.so.1)

add_library(Ext SHARED IMPORTED GLOBAL)
set_target_properties(Ext PROPERTIES
    IMPORTED_LOCATION                 "${EXT_DIR}/libext.so.1"
    IMPORTED_SONAME                   libext.so.1
    IMPORTED_LINK_DEPENDENT_LIBRARIES "Ext_internal")

# `consumer` is the SHARED lib whose link command will flip between cfg1
# and cfg2 once the shadow copy lands in IN_TREE_DIR.  It PRIVATE-links
# both inner and Ext.  Both contribute a directory to rpath-link:
#   - inner's NEEDED entry libinner_priv.so.1 is in IN_TREE_DIR
#   - Ext's IMPORTED_LINK_DEPENDENT_LIBRARIES (Ext_internal) is in EXT_DIR
add_library(consumer SHARED src/consumer.c)
target_link_libraries(consumer PRIVATE inner Ext)

# Distribution-layout shadowing.  After the in-tree libs are built, copy
# libext_internal.so.1 from EXT_DIR into IN_TREE_DIR.  This is the trigger:
#
#   - Configure 1 (fresh): IN_TREE_DIR contains no copy of libext_internal.so.1.
#     FileMayConflict() hits its GEN_NOT_PLANNED branch and returns FALSE.
#     No conflict edge added.  IN_TREE_DIR is sorted FIRST in -Wl,-rpath-link,
#
#   - Build runs.  The shadow step copies libext_internal.so.1 into IN_TREE_DIR.
#
#   - Configure 2: libext_internal.so.1 now exists on disk in IN_TREE_DIR
#     as a different physical inode from EXT_DIR's copy.  FileMayConflict()
#     hits its DISK_DIFFERENT branch and returns TRUE.  A conflict edge
#     "EXT_DIR before IN_TREE_DIR" is added.  IN_TREE_DIR is sorted LAST.
#     consumer's link command line changes; ninja relinks it.
set(STAMP "${CMAKE_BINARY_DIR}/.shadow.stamp")
add_custom_command(OUTPUT "${STAMP}"
    COMMAND "${CMAKE_COMMAND}" -E copy
        "${EXT_DIR}/libext_internal.so.1"
        "${IN_TREE_DIR}/libext_internal.so.1"
    COMMAND "${CMAKE_COMMAND}" -E touch "${STAMP}"
    DEPENDS inner inner_priv
    COMMENT "Shadowing libext_internal.so.1 into ${IN_TREE_DIR}")
add_custom_target(shadow_external_internal_into_in_tree_dir ALL
    DEPENDS "${STAMP}")
