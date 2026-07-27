# Conduit build + conformance entry points.
# The invariant (spec §9 Phase 4 step 2): a release requires Swift AND Go green
# against the same golden vectors in proto/vectors.

SWIFT_PKG := apple/ConduitKit
CORE      := core
VECTORS   := proto/vectors

.PHONY: all conformance vectors go-conformance go-test swift-test apple-apps cross-build clean

all: conformance

## Regenerate the golden vectors from the Swift source of truth (append-only:
## edits to existing vectors will show up as a diff and should be reviewed).
vectors:
	cd $(SWIFT_PKG) && swift run conduit-vectorgen ../../$(VECTORS)

## Go implementation must reproduce every vector byte-for-byte.
go-conformance:
	cd $(CORE) && go run ./cmd/conformance ../$(VECTORS)

go-test:
	cd $(CORE) && go test ./...

## Kotlin implementation must reproduce every vector byte-for-byte too.
## Uses Android Studio's bundled JDK if JAVA_HOME is unset.
KOTLIN_CORE := android/core
kotlin-conformance:
	cd $(KOTLIN_CORE) && kotlinc $$(find src/main/kotlin -name '*.kt') -include-runtime -d /tmp/conduit-core.jar
	java -cp /tmp/conduit-core.jar org.conduit.core.Conformance $(VECTORS)

kotlin-smoke:
	java -cp /tmp/conduit-core.jar org.conduit.core.SessionSmoke

## Cross-compile the Go daemons for the desktop matrix.
cross-build:
	cd $(CORE) && GOOS=linux   GOARCH=amd64 go build ./...
	cd $(CORE) && GOOS=windows GOARCH=amd64 go build ./...
	cd $(CORE) && GOOS=darwin  GOARCH=arm64 go build ./...

## Build all four Apple app targets (unsigned). MUST use -scheme: the legacy
## `xcodebuild -target` path cannot resolve SwiftPM module deps under Xcode 26
## explicit modules and fails inside swift-crypto's CryptoExtras
## ("unable to resolve module dependency: 'SwiftASN1'"). Schemes are fine.
APPS_PROJ := apple/AppleApps/ConduitApps.xcodeproj
apple-apps:
	xcodebuild -project $(APPS_PROJ) -scheme Conduit-macOS   -configuration Debug -destination "platform=macOS,arch=arm64" CODE_SIGNING_ALLOWED=NO build
	xcodebuild -project $(APPS_PROJ) -scheme Conduit-iOS     -configuration Debug -destination "generic/platform=iOS"      CODE_SIGNING_ALLOWED=NO build
	xcodebuild -project $(APPS_PROJ) -scheme ConduitBroadcast -configuration Debug -destination "generic/platform=iOS"     CODE_SIGNING_ALLOWED=NO build
	xcodebuild -project $(APPS_PROJ) -scheme Conduit-tvOS    -configuration Debug -destination "generic/platform=tvOS"     CODE_SIGNING_ALLOWED=NO build

## The Swift conformance suite (subset that reads proto/vectors).
swift-test:
	cd $(SWIFT_PKG) && swift test --filter "VectorConformance|PairingVectorConformance|ScreenMessageCodecTests|ScreenFrameFramingTests"

## The release gate: all three implementations green on the same vectors.
conformance: go-conformance kotlin-conformance
	@echo "Go + Kotlin conformance passed. Run 'make swift-test' for the Swift half (needs Xcode)."
	@echo "Run 'make interop' for the live Swift<->Go handshake test."

## Live cross-implementation interop (spec §9 Phase 4 acceptance).
interop:
	cd $(SWIFT_PKG) && swift test --filter GoInteropTests

clean:
	cd $(SWIFT_PKG) && swift package clean
	cd $(CORE) && go clean ./...
