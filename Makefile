.PHONY: build test bundle clean

build:
	swift build

test:
	./Tests/BundleMetadataTests.sh
	./Tests/SigningIdentityResolverTests.sh
	swift test

bundle:
	./Scripts/bundle.sh release

clean:
	swift package clean
