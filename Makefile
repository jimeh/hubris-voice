.PHONY: build test bundle clean

build:
	swift build

test:
	swift test

bundle:
	./Scripts/bundle.sh release

clean:
	swift package clean
