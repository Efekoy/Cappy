.PHONY: build test app install uninstall clean
DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
build:
	swift build
test:
	swift test
app:
	./scripts/build-app.sh release
install: app
	./scripts/install-app.sh
uninstall:
	@if [ -d "$(HOME)/Library/Input Methods/Cappy.app" ]; then mv "$(HOME)/Library/Input Methods/Cappy.app" "$(HOME)/.Trash/Cappy-$$(date +%s).app"; fi
clean:
	swift package clean
	rm -rf dist
