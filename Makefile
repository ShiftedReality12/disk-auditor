# Command Line Tools ship swift-testing outside the default search path, and
# without the Foundation overlay module (its Modules folder is empty).
FW := $(shell xcode-select -p)/Library/Developer/Frameworks
TESTFLAGS := -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xswiftc -F$(FW) -Xlinker -F$(FW) -Xlinker -rpath -Xlinker $(FW)
PREFIX ?= $(HOME)/.local

build:
	swift build -c release

test:
	swift test $(TESTFLAGS)

APP := .build/Disk Auditor.app
# macOS files every permission grant under the app's signature. An ad-hoc
# signature changes with each build, so every rebuild was a stranger that
# had to ask again; a real certificate keeps one identity across builds.
SIGN ?= $(shell security find-identity -v -p codesigning | awk 'NR==1 && $$2 ~ /^[0-9A-F]+$$/ {print $$2}')

# A plain bundle around the SwiftPM binary: no Xcode project needed.
app: build
	install -d "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	install .build/release/DiskAuditor "$(APP)/Contents/MacOS/DiskAuditor"
	install -m 644 packaging/Info.plist "$(APP)/Contents/Info.plist"
	if [ -f packaging/AppIcon.icns ]; then install -m 644 packaging/AppIcon.icns "$(APP)/Contents/Resources/"; fi
	codesign --force --sign "$(if $(SIGN),$(SIGN),-)" "$(APP)"

install: app
	install -d $(PREFIX)/bin $(HOME)/Applications
	install .build/release/dsa $(PREFIX)/bin/dsa
	ditto "$(APP)" "$(HOME)/Applications/Disk Auditor.app"

# To the Trash, like everything this tool removes.
uninstall:
	trash $(PREFIX)/bin/dsa "$(HOME)/Applications/Disk Auditor.app"

.PHONY: build test app install uninstall
