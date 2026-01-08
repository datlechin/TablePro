#!/bin/bash
set -e

# Build script for creating architecture-specific releases
# Usage: ./build-release.sh [arm64|x86_64|both]

ARCH="${1:-both}"
PROJECT="TablePro.xcodeproj"
SCHEME="TablePro"
CONFIG="Release"
BUILD_DIR="build/Release"

echo "🏗️  Building TablePro for: $ARCH"

# Ensure libmariadb.a has correct architecture
prepare_mariadb() {
    local target_arch=$1
    echo "📦 Preparing libmariadb.a for $target_arch..."

    (
        cd Libs || exit 1
        if [ ! -f "libmariadb_universal.a" ]; then
            echo "❌ Error: libmariadb_universal.a not found!"
            echo "Run this first to create universal library:"
            echo "  lipo -create libmariadb_arm64.a libmariadb_x86_64.a -output libmariadb_universal.a"
            exit 1
        fi

        lipo libmariadb_universal.a -thin $target_arch -output libmariadb.a
        echo "✅ libmariadb.a is now $target_arch-only ($(ls -lh libmariadb.a | awk '{print $5}'))"
    )
}

build_for_arch() {
    local arch=$1
    echo ""
    echo "🔨 Building for $arch..."

    # Prepare architecture-specific mariadb library
    prepare_mariadb $arch

    # Build
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIG" \
        -arch "$arch" \
        ONLY_ACTIVE_ARCH=YES \
        clean build

    # Get binary path
    DERIVED_DATA=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings | grep -m 1 "BUILD_DIR" | awk '{print $3}')
    APP_PATH="${DERIVED_DATA}/${CONFIG}/TablePro.app"

    # Create release directory
    mkdir -p "$BUILD_DIR"

    # Copy and rename app
    OUTPUT_NAME="TablePro-${arch}.app"
    cp -R "$APP_PATH" "$BUILD_DIR/$OUTPUT_NAME"

    # Get size
    BINARY_PATH="$BUILD_DIR/$OUTPUT_NAME/Contents/MacOS/TablePro"
    SIZE=$(ls -lh "$BINARY_PATH" | awk '{print $5}')

    echo "✅ Built: $OUTPUT_NAME ($SIZE)"
    lipo -info "$BINARY_PATH"
}

# Main
case "$ARCH" in
    arm64)
        build_for_arch arm64
        ;;
    x86_64)
        build_for_arch x86_64
        ;;
    both)
        build_for_arch arm64
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        build_for_arch x86_64
        ;;
    *)
        echo "Usage: $0 [arm64|x86_64|both]"
        exit 1
        ;;
esac

echo ""
echo "🎉 Build complete!"
echo "📁 Output: $BUILD_DIR/"
ls -lh "$BUILD_DIR"
