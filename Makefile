# Usage: make VERSION=1.2.0
#        make run VERSION=1.2.0

APP_NAME    := lucid
DISPLAY_NAME := Lucid
BUNDLE_ID   := com.local.lucid
OPTIMIZE    ?= ReleaseSafe

APP         := $(APP_NAME).app
CONTENTS    := $(APP)/Contents
EXE         := zig-out/bin/$(APP_NAME)
ICON_SVG    := assets/icon.svg
ICONSET     := zig-out/AppIcon.iconset
ICNS        := zig-out/AppIcon.icns

.PHONY: all build app plist icon sign run clean check-version

all: app

check-version:
ifndef VERSION
	$(error VERSION is not set. Usage: make VERSION=1.2.0)
endif

build:
	zig build -Doptimize=$(OPTIMIZE)

plist: check-version
	@mkdir -p "$(CONTENTS)"
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'    <key>CFBundleExecutable</key>' \
		'    <string>$(APP_NAME)</string>' \
		'    <key>CFBundleIconFile</key>' \
		'    <string>AppIcon</string>' \
		'    <key>CFBundleIdentifier</key>' \
		'    <string>$(BUNDLE_ID)</string>' \
		'    <key>CFBundleName</key>' \
		'    <string>$(DISPLAY_NAME)</string>' \
		'    <key>CFBundlePackageType</key>' \
		'    <string>APPL</string>' \
		'    <key>CFBundleShortVersionString</key>' \
		'    <string>$(VERSION)</string>' \
		'    <key>CFBundleVersion</key>' \
		'    <string>$(VERSION)</string>' \
		'    <key>NSCameraUsageDescription</key>' \
		'    <string>Required to capture and stream the connected iPad screen.</string>' \
		'</dict>' \
		'</plist>' \
		> "$(CONTENTS)/Info.plist"
	@plutil -lint "$(CONTENTS)/Info.plist"

icon: $(ICNS)

$(ICNS): $(ICON_SVG) assets/make_icon.swift
	@rm -rf "$(ICONSET)"
	swift assets/make_icon.swift "$(ICON_SVG)" "$(ICONSET)"
	iconutil -c icns "$(ICONSET)" -o "$(ICNS)"

app: check-version build plist icon
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	cp "$(EXE)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	cp "$(ICNS)" "$(CONTENTS)/Resources/AppIcon.icns"
	codesign --force --sign - "$(APP)"
	@echo "Built $(APP) version $(VERSION)"

run: app
	open "$(APP)"

clean:
	rm -rf "$(APP)" zig-out .zig-cache
