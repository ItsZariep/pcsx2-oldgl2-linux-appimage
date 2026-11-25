IMAGE_NAME := pcsx2-098
HOST_UID := $(shell id -u)
HOST_GID := $(shell id -g)
OUT_DIR := $(CURDIR)/out
SRC_DIR := $(CURDIR)/src-pcsx2

.PHONY: all prepare build debug dirs clean

all: build

prepare:
	docker build -t $(IMAGE_NAME) .

dirs:
	@mkdir -p "$(OUT_DIR)" "$(SRC_DIR)"

build: prepare dirs
	docker run --rm \
		-e HOST_UID="$(HOST_UID)" \
		-e HOST_GID="$(HOST_GID)" \
		-v "$(OUT_DIR):/out" \
		-v "$(SRC_DIR):/src/pcsx2" \
		$(IMAGE_NAME)

debug: prepare dirs
	docker run --rm \
		-e BUILD_TYPE=Devel \
		-e HOST_UID="$(HOST_UID)" \
		-e HOST_GID="$(HOST_GID)" \
		-v "$(OUT_DIR):/out" \
		-v "$(SRC_DIR):/src/pcsx2" \
		$(IMAGE_NAME)


appimage:
	appimagetool out/PCSX2.AppDir PCSX2-0.9.8-i686.AppImage
clean:
	rm -rf "$(OUT_DIR)"