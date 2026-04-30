cmake_minimum_required(VERSION 3.20)
project(rpath_reorder_min C)

# Disable runtime RPATH handling so the generated link line exposes the
# auto-computed `-Wl,-rpath-link,...` directories.  The repro is that this
# directory ordering changes between the first and second configure because
# CMake's ordering logic consults filesystem state.
set(CMAKE_SKIP_RPATH ON)

set(IN_TREE_DIR "${CMAKE_BINARY_DIR}/in_tree_lib")

# Two in-tree shared libs.  `inner` PRIVATE-links `inner_priv`, so
# `libinner.so` has `libinner_priv.so` as a NEEDED entry, but
# `inner_priv` is not on a consumer's direct link line.  When `consumer`
# links to `inner`, the linker still has to find `libinner_priv.so` for
# indirect-symbol resolution, which is why CMake adds `IN_TREE_DIR` to the
# generated `-Wl,-rpath-link,...` list.
add_library(inner_priv SHARED src/inner_priv.c)
set_target_properties(inner_priv PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${IN_TREE_DIR}")

add_library(inner SHARED src/inner.c)
set_target_properties(inner PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${IN_TREE_DIR}")
target_link_libraries(inner PRIVATE inner_priv)

# One imported external `Ext` whose `IMPORTED_LINK_DEPENDENT_LIBRARIES`
# names a sibling library in the same external dir.  That indirect shared-
# library dependency brings `EXT_DIR` into the generated
# `-Wl,-rpath-link,...` list, even though it is not on the consumer's
# direct link line.
add_library(Ext SHARED IMPORTED)
set_target_properties(Ext PROPERTIES
    IMPORTED_LOCATION                 "${EXT_DIR}/libext.so.1"
    IMPORTED_LINK_DEPENDENT_LIBRARIES "${EXT_DIR}/libext_internal.so.1")

# `consumer` is the shared library whose link command changes between cfg1
# and cfg2 once the shadow copy lands in `IN_TREE_DIR`.  It PRIVATE-links
# both `inner` and `Ext`, so both directories appear in `-Wl,-rpath-link,...`:
#   - `inner` contributes `IN_TREE_DIR` via `libinner_priv.so`
#   - `Ext` contributes `EXT_DIR` via `libext_internal.so.1`
add_library(consumer SHARED src/consumer.c)
target_link_libraries(consumer PRIVATE inner Ext)

# Simulate a distribution layout step by copying `libext_internal.so.1`
# from `EXT_DIR` into `IN_TREE_DIR` after the first build.
# This changes the filesystem state that CMake sees on the next configure.
#
#   - Configure 1 (fresh): `IN_TREE_DIR` does not contain
#     `libext_internal.so.1`, so no ordering constraint is added between
#     `EXT_DIR` and `IN_TREE_DIR`.
#
#   - Build runs.  A post-build step copies `libext_internal.so.1` into
#     `IN_TREE_DIR`.
#
#   - Configure 2: `libext_internal.so.1` now exists in both directories
#     as two different files, so CMake adds an ordering constraint that
#     places `EXT_DIR` before `IN_TREE_DIR`.  The `-Wl,-rpath-link,...`
#     flag changes, and Ninja relinks `consumer`.
add_custom_command(TARGET consumer POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy
        "${EXT_DIR}/libext_internal.so.1"
        "${IN_TREE_DIR}/libext_internal.so.1"
    COMMENT "Shadowing libext_internal.so.1 into ${IN_TREE_DIR}")
