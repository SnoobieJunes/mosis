# Conduit build + conformance entry points.
# The invariant (spec §9 Phase 4 step 2): a release requires Swift AND Go green
# against the same golden vectors in proto/vectors.

SWIFT_PKG := apple/ConduitKit
CORE      := core
VECTORS   := proto/vectors

.PHONY: all conformance vectors go-conformance go-test kotlin-conformance kotlin-smoke swift-test interop apple-apps cross-build clean

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
## Falls back to Android Studio's bundled JDK when no `java` is on PATH — that
## fallback was only ever a comment until 2026-08-17, so on a Mac without a
## system JDK both targets died with "Unable to locate a Java Runtime".
KOTLIN_CORE := android/core
KOTLIN_JAR  := /tmp/conduit-core.jar
STUDIO_JBR  := /Applications/Android Studio.app/Contents/jbr/Contents/Home/bin
## `command -v java` is not enough of a test on macOS: /usr/bin/java is a stub
## that exists and then exits with "Unable to locate a Java Runtime". Run it.
JAVA        := $(shell java -version >/dev/null 2>&1 && command -v java || echo "$(STUDIO_JBR)/java")

## Build the jar both Kotlin targets run from. A file target, so `make
## kotlin-smoke` on a fresh checkout builds it instead of failing with a bare
## "Could not find or load main class" (2026-08-17).
$(KOTLIN_JAR): $(shell find $(KOTLIN_CORE)/src/main/kotlin -name '*.kt')
	cd $(KOTLIN_CORE) && kotlinc $$(find src/main/kotlin -name '*.kt') -include-runtime -d $(KOTLIN_JAR)

kotlin-conformance: $(KOTLIN_JAR)
	"$(JAVA)" -cp $(KOTLIN_JAR) org.conduit.core.Conformance $(VECTORS)

kotlin-smoke: $(KOTLIN_JAR)
	"$(JAVA)" -cp $(KOTLIN_JAR) org.conduit.core.SessionSmoke

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
## Same sandbox rule as `interop` above — PairingVectorConformance touches the
## PKCS#12 path.
swift-test:
	cd $(SWIFT_PKG) && swift test --disable-sandbox --filter "VectorConformance|PairingVectorConformance|ScreenMessageCodecTests|ScreenFrameFramingTests"

## The release gate: all three implementations green on the same vectors.
conformance: go-conformance kotlin-conformance
	@echo "Go + Kotlin conformance passed. Run 'make swift-test' for the Swift half (needs Xcode)."
	@echo "Run 'make interop' for the live Swift<->Go handshake test."

## Live cross-implementation interop (spec §9 Phase 4 acceptance).
## --disable-sandbox is REQUIRED, not optional: the sandbox *hangs* (not fails)
## the Network.framework and PKCS#12 paths this test drives (docs/TESTING.md §1).
## It was missing here until 2026-08-17, so `make interop` hung.
interop:
	cd $(SWIFT_PKG) && swift test --disable-sandbox --filter GoInteropTests

clean:
	cd $(SWIFT_PKG) && swift package clean
	cd $(CORE) && go clean ./...
