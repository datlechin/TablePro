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

    # Change to Libs directory
    cd Libs || {
        echo "❌ FATAL: Cannot access Libs directory"
        exit 1
    }

    # Check if universal library exists
    if [ ! -f "libmariadb_universal.a" ]; then
        echo "❌ ERROR: libmariadb_universal.a not found!"
        echo "Run this first to create universal library:"
        echo "  lipo -create libmariadb_arm64.a libmariadb_x86_64.a -output libmariadb_universal.a"
        cd - > /dev/null
        exit 1
    fi

    # Extract thin slice for target architecture
    if ! lipo libmariadb_universal.a -thin "$target_arch" -output libmariadb.a; then
        echo "❌ FATAL: Failed to extract $target_arch slice from universal library"
        echo "Ensure the universal library contains $target_arch architecture"
        cd - > /dev/null
        exit 1
    fi

    # Verify the output file was created
    if [ ! -f "libmariadb.a" ]; then
        echo "❌ FATAL: libmariadb.a was not created successfully"
        cd - > /dev/null
        exit 1
    fi

    # Get and display size
    local size
    size=$(ls -lh libmariadb.a 2>/dev/null | awk '{print $5}')
    if [ -z "$size" ]; then
        size="unknown"
    fi

    echo "✅ libmariadb.a is now $target_arch-only ($size)"

    cd - > /dev/null || exit 1
}

build_for_arch() {
    local arch=$1
    echo ""
    echo "🔨 Building for $arch..."

    # Prepare architecture-specific mariadb library
    prepare_mariadb "$arch"

    # Build with xcodebuild
    echo "Running xcodebuild..."
    if ! xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIG" \
        -arch "$arch" \
        ONLY_ACTIVE_ARCH=YES \
        clean build 2>&1 | tee "build-${arch}.log"; then
        echo "❌ FATAL: xcodebuild failed for $arch"
        echo "Check build-${arch}.log for details"
        exit 1
    fi
    echo "✅ Build succeeded for $arch"

    # Get binary path with validation
    DERIVED_DATA=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>&1 | grep -m 1 "BUILD_DIR" | awk '{print $3}')

    if [ -z "$DERIVED_DATA" ]; then
        echo "❌ FATAL: Failed to determine build directory from xcodebuild settings"
        echo "This usually indicates:"
        echo "  1. The Xcode project is corrupted"
        echo "  2. The scheme '$SCHEME' doesn't exist"
        echo "  3. Xcode changed its output format"
        echo ""
        echo "Run this command to debug:"
        echo "  xcodebuild -project '$PROJECT' -scheme '$SCHEME' -showBuildSettings | grep BUILD_DIR"
        exit 1
    fi

    APP_PATH="${DERIVED_DATA}/${CONFIG}/TablePro.app"
    echo "📂 Expected app path: $APP_PATH"

    # Verify app bundle exists
    if [ ! -d "$APP_PATH" ]; then
        echo "❌ ERROR: Built app not found at expected path: $APP_PATH"
        echo "Build may have failed silently"
        exit 1
    fi

    # Create release directory
    mkdir -p "$BUILD_DIR" || {
        echo "❌ FATAL: Failed to create release directory: $BUILD_DIR"
        exit 1
    }

    # Copy and rename app
    OUTPUT_NAME="TablePro-${arch}.app"
    echo "Copying app bundle to release directory..."
    if ! cp -R "$APP_PATH" "$BUILD_DIR/$OUTPUT_NAME"; then
        echo "❌ FATAL: Failed to copy app bundle"
        echo "Source: $APP_PATH"
        echo "Destination: $BUILD_DIR/$OUTPUT_NAME"
        exit 1
    fi

    # Verify the copy succeeded
    if [ ! -d "$BUILD_DIR/$OUTPUT_NAME" ]; then
        echo "❌ FATAL: App bundle was not copied successfully"
        exit 1
    fi

    # Verify binary exists inside the copied bundle
    BINARY_PATH="$BUILD_DIR/$OUTPUT_NAME/Contents/MacOS/TablePro"
    if [ ! -f "$BINARY_PATH" ]; then
        echo "❌ FATAL: Binary not found in copied app bundle: $BINARY_PATH"
        exit 1
    fi

    # Verify binary is not empty
    if [ ! -s "$BINARY_PATH" ]; then
        echo "❌ FATAL: Binary file is empty"
        exit 1
    fi

    # Verify binary is executable
    if [ ! -x "$BINARY_PATH" ]; then
        echo "❌ FATAL: Binary is not executable"
        exit 1
    fi

    # Get size
    SIZE=$(ls -lh "$BINARY_PATH" 2>/dev/null | awk '{print $5}')
    if [ -z "$SIZE" ]; then
        echo "⚠️  WARNING: Could not determine binary size"
        SIZE="unknown"
    fi

    echo "✅ Built: $OUTPUT_NAME ($SIZE)"

    # Verify and display architecture
    if ! lipo -info "$BINARY_PATH"; then
        echo "⚠️  WARNING: Could not verify binary architecture"
    fi
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

if ! ls -lh "$BUILD_DIR" 2>/dev/null; then
    echo "⚠️  WARNING: Could not list build directory contents"
    echo "Directory may be empty or inaccessible"
fi
