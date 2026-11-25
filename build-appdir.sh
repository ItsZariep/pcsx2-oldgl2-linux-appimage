#!/bin/bash
# Runs INSIDE the Wheezy i386 container. Produces /out/PCSX2.AppDir
set -euo pipefail

SRC=/src/pcsx2
APPDIR=/out/PCSX2.AppDir
PREFIX=/opt/pcsx2-install
JOBS=${JOBS:-2}

# -fno-omit-frame-pointer: PCSX2 0.9.8 plugin ABI mixes stdcall/cdecl exports; GCC<4.6 hid the
# resulting stack imbalance by always keeping ebp. Keep it, or plugin calls return into garbage.
export CFLAGS="-O2 -w -fpermissive -fno-omit-frame-pointer"
export CXXFLAGS="-O2 -w -fpermissive -fno-omit-frame-pointer"

# BUILD_TYPE=Devel keeps symbols and enables PCSX2's assertions (for debugging crashes)
BUILD_TYPE="${BUILD_TYPE:-Release}"
if [ "$BUILD_TYPE" = "Devel" ]; then
	export CFLAGS="$CFLAGS -g"
	export CXXFLAGS="$CXXFLAGS -g"
fi

## fetch ##

if [ ! -d "$SRC" ] || [ -z "$(ls -A "$SRC" 2>/dev/null)" ]; then
	mkdir -p "$SRC"
	URL="https://codeload.github.com/PCSX2/pcsx2/tar.gz/refs/$PCSX2_REF"
	echo ">> downloading $URL"
	# wheezy's CA bundle is too old for github; skip verification for this download only
	wget --no-check-certificate -O /tmp/pcsx2.tar.gz "$URL"
	tar -xzf /tmp/pcsx2.tar.gz -C "$SRC" --strip-components=1
else
	echo ">> using pre-existing source in $SRC"
fi
cd "$SRC"

## source patches for old code vs newer GCC #

# "inlining failed ... function body can be overwritten at link time":
# demote forced inlining to plain inline in the pad plugins.
for f in plugins/zeropad/*.cpp plugins/zeropad/*.h; do
	[ -f "$f" ] || continue
	sed -i \
		-e 's/__attribute__[[:space:]]*((always_inline))/ /g' \
		-e 's/__attribute__[[:space:]]*((always_inline,[^)]*))/ /g' \
		-e 's/\b__forceinline\b/inline/g' \
		"$f"
done
grep -n "FindKey" plugins/zeropad/keyboard.cpp | head -n3 || true

# onepad: drop forced inlining entirely, so every function keeps an out-of-line body
# (fixes undefined _Z11type_of_keyii = type_of_key(int,int))
for f in plugins/onepad/*.cpp plugins/onepad/*.h; do
	[ -f "$f" ] || continue
	sed -i \
		-e 's/__attribute__[[:space:]]*((always_inline))/ /g' \
		-e 's/__attribute__[[:space:]]*((always_inline,[^)]*))/ /g' \
		-e 's/\b__forceinline\b//g' \
		"$f"
done
grep -rn "type_of_key" plugins/onepad | head

# getpagesize() needs <unistd.h>, do it per-file (a global -include breaks the .S assembler files)
for f in $(grep -rlE '\b(usleep|getpagesize|sysconf|getcwd|chdir|unlink|isatty|ftruncate|getpid|lseek|fsync)[[:space:]]*\(' \
		--include='*.cpp' common pcsx2 plugins 2>/dev/null); do
	if ! grep -q '<unistd.h>' "$f"; then
		sed -i '0,/^#include/s//#include <unistd.h>\n#include/' "$f"
		echo ">> added <unistd.h> to $f"
	fi
done

# HashMap.h: calls to dependent-base members need this-> on modern GCC (find() otherwise resolves to std::find)
H=common/include/Utilities/HashMap.h
if [ -f "$H" ]; then
	sed -i -E '585,625{
		s/([^>.A-Za-z_])(set_empty_key|set_deleted_key|find)\(/\1this->\2(/g
	}' "$H"
	echo ">> HashMap.h patched:"; grep -n 'this->' "$H" | head -n6 || true
fi

## configure + build ##

if [ -f CMakeLists.txt ]; then
	echo ">> CMake build system detected"
	mkdir -p "build-$BUILD_TYPE" && cd "build-$BUILD_TYPE"
	# GSdx requires internal SDL
	cmake .. \
		-DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
		-DCMAKE_INSTALL_PREFIX="$PREFIX" \
		-Wno-dev \
		-DCMAKE_CXX_FLAGS="$CXXFLAGS" -DCMAKE_C_FLAGS="$CFLAGS"
		# -DFORCE_INTERNAL_SDL=TRUE \  # Using this causes many errors, still not solved
	make -j"$JOBS"
	# 0.9.8 has no install rule: outputs go to $SRC/bin
	echo ">> CMake options of interest:"
	cmake -LH . | grep -iE -B1 'core|plugin|package|zzogl|zerogs|cg|glsl' || true
	echo ">> contents of $SRC/bin:"
	find "$SRC/bin" -maxdepth 2 | sort
	if [ ! -x "$SRC/bin/pcsx2" ] && [ ! -x "$SRC/bin/pcsx2-dev" ]; then
		echo "!! pcsx2 core binary was NOT built (only plugins). See CMake options above."
		exit 2
	fi
elif [ -f build.sh ] || [ -f autogen.sh ]; then
	echo ">> Legacy build system detected (see notes in README); trying build.sh"
	ls
	[ -x ./build.sh ] && ./build.sh all --prefix "$PREFIX" || { echo "Adapt this branch to the tag's build system"; exit 1; }
else
	echo "!! No known build system in $PCSX2_REF"; exit 1
fi

## assemble AppDir ##
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr" "$APPDIR/usr/lib-deps"
mkdir -p "$APPDIR/usr/bin"
cp -a "$SRC/bin/." "$APPDIR/usr/bin/"

BIN=$(find "$APPDIR/usr" -type f -name 'pcsx2*' -perm -u+x | head -n1)
echo ">> main binary: $BIN"

# Collect shared-lib deps of the binary and every plugin,
# EXCLUDING glibc/loader and GL/driver libs (both also may break anyways).
# Since Wheezy binds SDL to old Pulse, also include it, it is not use by spu2x

#EXCLUDE='^(libc|libm|libdl|libpthread|librt|libutil|libresolv|libnsl|ld-linux|libGL|libGLX|libGLU|libEGL|libGLESv2|libdrm|libX11|libxcb|libXau|libXdmcp|libXext|libXxf86vm|libX11-xcb|libgcc_s|libstdc\+\+|libgbm|libwayland|libnvidia|libasound|libpulse|libpulsecommon|libudev|libglapi|libxcb-[a-z0-9-]+|libpulsecommon-[0-9.]+|linux-gate)\.'
EXCLUDE='^(libc|libm|libdl|libpthread|librt|libutil|libresolv|libnsl|ld-linux|libGL|libGLX|libGLU|libEGL|libGLESv2|libdrm|libX11|libxcb|libXau|libXdmcp|libXext|libXxf86vm|libX11-xcb|libgcc_s|libstdc\+\+|libgbm|libwayland|libnvidia|libasound|libudev|libglapi|libxcb-[a-z0-9-]+|linux-gate)\.'


# NOTE: libstdc++/libgcc are excluded so a NEWER host version is used.
# Wheezy's are older than Arch's, bundling them would break host Mesa.

for f in "$BIN" $(find "$APPDIR/usr" -name '*.so*' -type f); do
	ldd "$f" 2>/dev/null | awk '/=> \//{print $3}' || true
done | sort -u | while read -r lib; do
	base=$(basename "$lib")
	if echo "$base" | grep -Eq "$EXCLUDE"; then continue; fi
	cp -nL "$lib" "$APPDIR/usr/lib-deps/"
done

PC=$(find /usr/lib -name 'libpulsecommon-*.so' | head -n1 || true)
[ -n "$PC" ] && cp -nL "$PC" "$APPDIR/usr/lib-deps/" || echo "warn: libpulsecommon not found"

# Libs loaded via dlopen / not seen by ldd (Cg runtime for ZZogl/ZeroGS)
for l in libCg.so libCgGL.so; do
	p=$(find /usr/lib /usr/lib32 -name "$l*" 2>/dev/null | head -n1 || true)
	[ -n "$p" ] && cp -nL "$p" "$APPDIR/usr/lib-deps/" || echo "warn: $l not found"
done

# wx/GTK2 runtime data bundled by name

# fontconfig: private minimal config (old fontconfig can't parse modern ones)
mkdir -p "$APPDIR/usr/etc/fonts"
cat > "$APPDIR/usr/etc/fonts/fonts.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
	<dir>/usr/share/fonts</dir>
	<dir>/usr/local/share/fonts</dir>
	<dir>~/.fonts</dir>
	<dir>~/.local/share/fonts</dir>
	<cachedir>~/.cache/pcsx2-appimage-fontconfig</cachedir>
	<alias><family>sans-serif</family><prefer><family>DejaVu Sans</family><family>Noto Sans</family><family>Liberation Sans</family></prefer></alias>
	<alias><family>monospace</family><prefer><family>DejaVu Sans Mono</family><family>Liberation Mono</family></prefer></alias>
</fontconfig>
EOF

# GTK2: 32-bit Clearlooks engine + small dark theme
ENG=$(find /usr/lib -type d -path '*gtk-2.0/2.10.0/engines' | head -n1 || true)
mkdir -p "$APPDIR/usr/lib/gtk-2.0/2.10.0" "$APPDIR/usr/lib/gio-empty"
[ -n "$ENG" ] && cp -a "$ENG" "$APPDIR/usr/lib/gtk-2.0/2.10.0/" || echo "warn: gtk2 engines not found"

mkdir -p "$APPDIR/usr/share/themes/PCSX2-Dark/gtk-2.0"
cat > "$APPDIR/usr/share/themes/PCSX2-Dark/gtk-2.0/gtkrc" <<'EOF'
style "dark"
{
	bg[NORMAL]      = "#2a2a2a"
	bg[PRELIGHT]    = "#3a3a3a"
	bg[ACTIVE]      = "#222222"
	bg[SELECTED]    = "#666666"
	bg[INSENSITIVE] = "#2a2a2a"

	fg[NORMAL]      = "#e0e0e0"
	fg[PRELIGHT]    = "#eeeeee"
	fg[ACTIVE]      = "#e0e0e0"
	fg[SELECTED]    = "#eeeeee"
	fg[INSENSITIVE] = "#808080"

	base[NORMAL]      = "#1a1a1a"
	base[PRELIGHT]    = "#1a1a1a"
	base[ACTIVE]      = "#666666"
	base[SELECTED]    = "#666666"
	base[INSENSITIVE] = "#262626"

	text[NORMAL]      = "#e0e0e0"
	text[PRELIGHT]    = "#eeeeee"
	text[ACTIVE]      = "#eeeeee"
	text[SELECTED]    = "#eeeeee"
	text[INSENSITIVE] = "#808080"

	engine "clearlooks" { }
}
style "tooltip" = "dark" { bg[NORMAL] = "#3a3a3a" fg[NORMAL] = "#e0e0e0" }

class "GtkWidget" style "dark"
widget "gtk-tooltip*" style "tooltip"
EOF

# Pango 1.30 loads its shaping modules dynamically
PMOD=$(find /usr/lib -type d -path '*pango/1.6.0/modules' | head -n1 || true)
if [ -n "$PMOD" ]; then
	mkdir -p "$APPDIR/usr/lib/pango/1.6.0"
	cp -a "$PMOD" "$APPDIR/usr/lib/pango/1.6.0/"
	# module deps (harfbuzz, pangoft2, ...) that the earlier ldd pass didn't see
	for m in "$APPDIR"/usr/lib/pango/1.6.0/modules/*.so; do
		ldd "$m" 2>/dev/null | awk '/=> \//{print $3}'
	done | sort -u | while read -r lib; do
		base=$(basename "$lib")
		if echo "$base" | grep -Eq "$EXCLUDE"; then continue; fi
		cp -nL "$lib" "$APPDIR/usr/lib-deps/"
	done
	# module list with a placeholder path (AppRun rewrites it at launch)
	PQ=$(command -v pango-querymodules || find /usr/bin /usr/lib -name 'pango-querymodules*' -type f | head -n1)
	"$PQ" "$PMOD"/*.so | sed "s#$PMOD#@PANGO_MODS@#g" > "$APPDIR/usr/lib/pango/pango.modules.in"
	echo ">> pango modules:"; grep -c '@PANGO_MODS@' "$APPDIR/usr/lib/pango/pango.modules.in" || true
else
	echo "warn: pango modules dir not found"
fi

install -m755 /opt/AppRun "$APPDIR/AppRun"
cat > "$APPDIR/pcsx2.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=PCSX2 0.9.8
Exec=AppRun
Icon=pcsx2
Categories=Game;Emulator;
EOF

# App icon
ICON="$SRC/pcsx2/gui/Resources/AppIcon64.png"
if [ -f "$ICON" ]; then
	cp -f "$ICON" "$APPDIR/pcsx2.png"
else
	echo "warn: $ICON not found, using placeholder icon"
	printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR\0\0\0\x01\0\0\0\x01\x08\x06\0\0\0\x1f\x15\xc4\x89\0\0\0\rIDATx\x9cc\xf8\xff\xff?\0\x05\xfe\x02\xfe\xa7\x9a\xa0\xa0\0\0\0\0IEND\xaeB`\x82' > "$APPDIR/pcsx2.png"
fi

echo ">> Bundled libs:"; ls "$APPDIR/usr/lib-deps" | wc -l
if [ -n "${HOST_UID:-}" ]; then
	chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$APPDIR"
fi
echo ">> AppDir ready at $APPDIR"
