# Minimal reproducer: CMake/Ninja rpath-link reorder relink storm

A standalone CMake project that demonstrates an unwanted relink on the
first no-op `cmake -S … -B …` reconfigure after a from-scratch build.
The link command line for a shared library changes — but only the
ordering of paths inside the auto-emitted `-Wl,-rpath-link,…` flag —
and ninja therefore considers the library dirty and relinks it.

The flip is one-shot, not a steady state: after the relink actually
runs, ninja's `.ninja_log` records the new command line, and subsequent
reconfigures stay stable (FileMayConflict's return value flipped on
the cfg1→cfg2 boundary because the shadow file went from absent to
present, but cfg2 onwards it stays present so the conflict graph
doesn't change again).

Confirmed against CMake 4.2.3 and 4.3.2 (the latest release).

## Run it

```sh
./run.sh
```

The script builds a pair of pre-baked "external" shared libraries with
the system gcc, then runs CMake configure+build, snapshots `build.ninja`,
runs CMake configure a second time (no source changes), snapshots again,
and prints the diff.  When the bug fires, the script ends with
`*** BUG REPRODUCED: rpath-link order flipped between configures ***`.

Override defaults:

```
CMAKE=/path/to/cmake NINJA=/path/to/ninja BUILD_ROOT=/some/dir ./run.sh
```

## Expected output

```
ninja explain: command line changed for libconsumer.so
[1/1] Linking C shared library libconsumer.so

rpath-link lines that differ between cfg1 and cfg2:
<  ... -Wl,-rpath-link,build/in_tree_lib:ext_install
>  ... -Wl,-rpath-link,ext_install:build/in_tree_lib

*** BUG REPRODUCED: rpath-link order flipped between configures ***
```

## Root cause

`cmOrderDirectoriesConstraint::FileMayConflict()` in
`Source/cmOrderDirectories.cxx`:

```cpp
bool cmOrderDirectoriesConstraint::FileMayConflict(
    std::string const& dir, std::string const& name)
{
  std::string file = cmStrCat(dir, '/', name);
  if (cmSystemTools::FileExists(file, true)) {
    // DISK_DIFFERENT branch.  Returns true iff the file in `dir` is a
    // different physical inode from this->FullPath.  Fires on cfg2 once
    // the build has dropped a shadow copy of the constraint's reference
    // file into `dir`.
    return !cmSystemTools::SameFile(this->FullPath, file);
  }
  // GEN_NOT_PLANNED branch.  Returns false when `dir` neither has the
  // file on disk nor in the planned generated content set.  Fires on
  // cfg1 (fresh tree, build hasn't run yet).
  std::set<std::string> const& files =
    (this->GlobalGenerator->GetDirectoryContent(dir, false));
  auto fi = files.find(name);
  return fi != files.end();
}
```

The function's return value feeds the conflict graph behind the DFS
topological sort in `cmOrderDirectories::OrderDirectories()`.  A different
return value between configures = different graph = different ordering of
the rpath-link list = different link command line = ninja relinks every
consumer of the affected library.

## Setup

```
CMAKE_SKIP_RPATH = ON                       (forces rpath-link emission)

  inner_priv (SHARED, IN_TREE_DIR, leaf)
       ^                                     libinner.so.1 NEEDS libinner_priv.so.1
       │ PRIVATE                             but inner_priv is not on consumer's
       │                                     direct link line, so IN_TREE_DIR
  inner      (SHARED, IN_TREE_DIR)            ends up in -Wl,-rpath-link,
       ^
       │ PRIVATE
       │
  consumer   (SHARED, target whose link
              command flips)

  Ext_internal (IMPORTED SHARED in EXT_DIR)
       ^                                     libext.so.1 NEEDS libext_internal.so.1
       │ via IMPORTED_LINK_DEPENDENT_LIBRARIES via IMPORTED_LINK_DEPENDENT_LIBRARIES
       │ on Ext                              so EXT_DIR ends up in rpath-link
       │
  Ext          (IMPORTED SHARED in EXT_DIR)
       ^
       │ PRIVATE
       │
  consumer
```

After the build, the shadow step copies `libext_internal.so.1` from
`EXT_DIR` into `IN_TREE_DIR`.  Configure 2 then sees the same SONAME-bearing
file in two different on-disk locations, both of which are in the rpath-link
candidate set, and adds a conflict edge that flips the topological sort.

## Files

```
CMakeLists.txt         project definition (~70 lines, mostly comments)
src/inner_priv.c       leaf in-tree shared lib
src/inner.c            in-tree shared lib that PRIVATE-links inner_priv
src/consumer.c         the relink target — SHARED lib that PRIVATE-links
                       inner and Ext
ext_src/ext.c          "external" main shared lib, NEEDED's libext_internal
ext_src/ext_internal.c "external" sibling shared lib, leaf
run.sh                 the experiment driver
```
