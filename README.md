# Minimal reproducer: CMake/Ninja link-search-path reorder relink

This repo reproduces a no-op reconfigure that changes only the ordering of
directories inside CMake's generated link search-path flags for a shared
library link step. In the default setup, both `-Wl,-rpath,...` and
`-Wl,-rpath-link,...` reorder. Ninja then treats the link command as changed
and relinks the target.

The relink is one-shot: after that relink runs, later reconfigures are stable
again.

Confirmed against CMake `4.2.3` and `4.3.2`.

If you add `set(CMAKE_SKIP_RPATH ON)` back to `CMakeLists.txt`, the repro
still occurs, but the visible change narrows to `-Wl,-rpath-link,...`.

## Run it

```sh
./run.sh
```

Optional overrides:

```sh
CMAKE=/path/to/cmake NINJA=/path/to/ninja BUILD_ROOT=/some/dir ./run.sh
```

## Expected output

```text
ninja explain: command line changed for libconsumer.so
[1/1] Linking C shared library libconsumer.so

link-search-path lines that differ between cfg1 and cfg2:
<  ... -Wl,-rpath,build/in_tree_lib:ext_install ... -Wl,-rpath-link,build/in_tree_lib:ext_install
>  ... -Wl,-rpath,ext_install:build/in_tree_lib ... -Wl,-rpath-link,ext_install:build/in_tree_lib

*** BUG REPRODUCED: link search-path order flipped between configures ***
```

## Files

- `CMakeLists.txt`: minimal project
- `run.sh`: reproducer driver
- `BUG_REPORT.md`: short issue text for filing upstream
