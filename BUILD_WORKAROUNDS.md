# Build workarounds

This document lists the **build-time workarounds and source modifications** applied by the build script to get PCSX2 0.9.8 compiling and running with the Wheezy i386 toolchain (GCC 4.7).

It does not cover environment setup (container, certificates, packages) or AppDir packaging (bundled libraries, fontconfig, GTK theme, Pango modules).


| Workaround | Type | Fixes |
| --- | --- | --- |
| `-fno-omit-frame-pointer` | Compiler flag | Crash on plugin calls (stdcall/cdecl mismatch) |
| `-w -fpermissive` | Compiler flags | Old code rejected or flooded with warnings |
| Pad plugin inlining patch | Source patch (`sed`) | "inlining failed" errors |
| `<unistd.h>` injection | Source patch (`sed`) | Undeclared POSIX functions |
| `HashMap.h` `this->` patch | Source patch (`sed`) | Dependent-base lookup errors |


## Keep the frame pointer: `-fno-omit-frame-pointer`

```bash
export CFLAGS="-O2 -w -fpermissive -fno-omit-frame-pointer"
export CXXFLAGS="-O2 -w -fpermissive -fno-omit-frame-pointer"
```

### Symptom

The emulator crashes while scanning plugins:

- `penum.m_plugpath` is `libspu2x.so`.
- The crash is at `penum.CheckVersion(pid)`, the first call the scanner makes into the plugin's own `PS2EgetLibVersion2`.
- The five plugins scanned before it pass the same check.
- The function pointers returned by the plugin (`PS2EgetLibType`, `PS2EgetLibName`, `PS2EgetLibVersion2`) are valid addresses inside the plugin.
- Execution still ends up in `tbl_PluginInfo`, a **data table** in the main binary.
- An earlier Release build crashed with a SIGTRAP at `0x082af802`, also inside the main binary's data range.

A valid pointer that is called and then lands in data usually means the stack was out of sync across the call, so `ret` jumped to a wrong value.

### Cause: calling-convention mismatch in the original source

The core declares plugin entry points with `CALLBACK`, which on Linux is `__attribute__((stdcall))`. Some plugins export their functions without it, so the two sides disagree about who cleans up the stack.

```
src-pcsx2/common/include/Pcsx2Defs.h:238:  #define CALLBACK  __attribute__((stdcall))
src-pcsx2/common/include/PS2Eext.h:28:     #define EXPORT_C_(type) extern "C" type CALLBACK
src-pcsx2/common/include/PS2Eext.h:33:     #define EXPORT_C_(type) extern "C" __attribute__((externally_visible,visibility("default"))) type
src-pcsx2/plugins/spu2-x/src/PS2E-spu2.h:31: #define EXPORT_C_(type) extern "C" __attribute__((externally_visible,visibility("default"))) type
```

The `EXPORT_C_` definitions at `PS2Eext.h:33` and `PS2E-spu2.h:31` omit `CALLBACK`.

You can confirm this in the disassembly. A stdcall function with one argument ends in `ret $0x4`, and a cdecl function ends in a plain `ret`:

```bash
cd out/PCSX2.AppDir/usr/bin/plugins
for p in libspu2x.so libzerospu2.so libonepad.so; do
  echo "== $p"
  objdump -d --no-show-raw-insn "$p" | awk '/<PS2EgetLibVersion2/,/ret/' | tail -n 3
done
```

```
== libspu2x.so
000248d0 <PS2EgetLibVersion2>:
   248d0:	mov    $0x50104,%eax
   248d5:	ret                      <-- cdecl: callee pops nothing
== libzerospu2.so
0000b940 <PS2EgetLibVersion2>:
    b940:	mov    $0x6050004,%eax
    b945:	ret    $0x4              <-- stdcall: callee pops 4 bytes
== libonepad.so
00006ae0 <PS2EgetLibVersion2>:
    6ae0:	mov    $0x20001,%eax
    6ae5:	ret    $0x4              <-- stdcall
```

`libspu2x.so` returns with a plain `ret`, while the core calls it as stdcall and does not clean up the argument itself. Each call leaks 4 bytes of stack.

### Why it only breaks now

This bug exists in upstream. It went unnoticed because GCC before 4.6 kept the frame pointer on 32-bit x86 by default, so every function epilogue restored `esp` from `ebp` and hid the 4-byte imbalance.

Since GCC 4.6, `-O2` omits the frame pointer. The leaked bytes then make the function return to a garbage address, which is the crash into `tbl_PluginInfo`. The Wheezy toolchain (GCC 4.7) is past that change.

### Fix

Tell GCC to keep the frame pointer. This covers the core and every plugin at once, without having to find every mismatched export.

### Alternative not applied

Add `CALLBACK` to the `EXPORT_C_` definitions in `PS2Eext.h` and `PS2E-spu2.h`. This is the "correct" fix, but it requires auditing every plugin export. The compiler flag is smaller and safer.

## Silence and relax old code: `-w -fpermissive`

Part of the same `CFLAGS`/`CXXFLAGS`:

- `-w` disables all warnings. The 0.9.8 code base produces a very large number of them on newer GCC, which drowns real errors.
- `-fpermissive` downgrades several pedantic errors (mostly invalid conversions and old template rules) to warnings so the code still compiles.

## Pad plugins: demote forced inlining

Applies to `plugins/zeropad` and `plugins/onepad`.

### Symptom

```
inlining failed in call to always_inline ... : function body can be overwritten at link time
```

### Cause

The pad plugins mark functions `always_inline` or `__forceinline`. Newer GCC refuses to inline such functions when they can be overridden at link time (non-static `inline` combined with the plugin's symbol visibility).

### Fix

```bash
sed -i \
  -e 's/__attribute__[[:space:]]*((always_inline))/ /g' \
  -e 's/__attribute__[[:space:]]*((always_inline,[^)]*))/ /g' \
  -e 's/\b__forceinline\b/inline/g' \
  "$f"
```

- The `always_inline` attributes are removed, and the compiler decides.
- `__forceinline` becomes plain `inline`.

The script then greps `FindKey` in `plugins/zeropad/keyboard.cpp` to show that the patch took effect.

## Missing `<unistd.h>`

### Symptom

Errors about undeclared `usleep`, `getpagesize`, `sysconf`, `getcwd`, `chdir`, `unlink`, `isatty`, `ftruncate`, `getpid`, `lseek` and `fsync`.

### Cause

Older headers pulled in `<unistd.h>` indirectly. Modern libstdc++/glibc headers no longer do.

### Fix

The script finds every `.cpp` file under `common`, `pcsx2` and `plugins` that calls one of those functions and does not include `<unistd.h>`, then inserts the include before the first existing `#include`:

```bash
sed -i '0,/^#include/s//#include <unistd.h>\n#include/' "$f"
```

### Why not `-include unistd.h` globally?

A global `-include` also applies to the `.S` assembler files, where it breaks the build. The patch is therefore applied per file, to C++ sources only.

## `HashMap.h`: dependent-base members need `this->`

File: `common/include/Utilities/HashMap.h`, lines 585-625.

### Symptom

Calls to `set_empty_key`, `set_deleted_key` and `find` resolve incorrectly on modern GCC. For example, `find()` binds to `std::find` instead of the base-class member.

### Cause

Since GCC 4.7, names from a dependent base class are no longer found by unqualified lookup inside a template. Older GCC accepted this.

### Fix

```bash
sed -i -E '585,625{
  s/([^>.A-Za-z_])(set_empty_key|set_deleted_key|find)\(/\1this->\2(/g
}' "$H"
```

The regex only rewrites calls that are not already qualified (`.`, `->`, or part of a longer identifier), and only inside the affected line range.

> The line range is specific to the 0.9.8 source. If `PCSX2_REF` is changed (i.e. maybe 1.2 can also work in the future), check that the range still covers the right code.

## Build-layout notes

These are not workarounds for bugs, but they affect how the script behaves:

- **0.9.8 has no `install` rule.** The build outputs end up in `$SRC/bin`, and the script copies that directory into the AppDir.
- **The CMake build can produce only plugins.** If neither `bin/pcsx2` nor `bin/pcsx2-dev` exists after `make`, the script exits with code 2 and prints the CMake options to help find the missing core option.
- **The plugin CMakeLists need no changes.** For example, `onepad` links `${SDL_LIBRARY}` correctly, and its runtime failure was a packaging problem with SDL's PulseAudio dependencies, not a build problem.