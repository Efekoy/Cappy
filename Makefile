.PHONY: build test app install clean
DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
build:
	swift build
test:
	swift test
app:
	./scripts/build-app.sh release
install: app
	ditto "dist/AutoCaps.app" "/Applications/AutoCaps.app"
	@echo "Installed /Applications/AutoCaps.app"
clean:
	swift package clean
	rm -rf dist
