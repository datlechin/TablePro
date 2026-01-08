# Building TablePro

## Architecture Support

TablePro supports both Apple Silicon (ARM64) and Intel (x86_64) Macs.

### Build Options

#### Option 1: Separate Builds (Recommended for Distribution)

Build architecture-specific binaries to minimize download size:

```bash
# Build Apple Silicon version only (~6MB)
./build-release.sh arm64

# Build Intel version only (~6MB)
./build-release.sh x86_64

# Build both architectures
./build-release.sh both
```

**Output:**
- `build/Release/TablePro-arm64.app` - For Apple Silicon Macs
- `build/Release/TablePro-x86_64.app` - For Intel Macs

**Benefits:**
- ✅ Smaller file size (~6MB each vs 12MB universal)
- ✅ Users only download what they need
- ✅ Faster downloads
- ✅ Less disk space

#### Option 2: Universal Binary (Single Build)

Build one app that runs on both architectures:

```bash
xcodebuild -project TablePro.xcodeproj \
           -scheme TablePro \
           -configuration Release \
           -arch arm64 -arch x86_64 \
           ONLY_ACTIVE_ARCH=NO \
           build
```

> **Note:** For this universal build to succeed, the MariaDB static library must also be a universal binary.  
> Ensure that `Libs/libmariadb_universal.a` exists (or create it first, similar to what `build-release.sh` expects) and that your Xcode project links against this universal library instead of an architecture-specific `libmariadb.a`.  
> For example, if you have separate per-architecture libraries, you can create the universal one with:
>
> ```bash
> lipo -create \
>   path/to/arm64/libmariadb.a \
>   path/to/x86_64/libmariadb.a \
>   -output Libs/libmariadb_universal.a
> ```
**Output:**
- `TablePro.app` - Runs on both Apple Silicon and Intel (~12MB)

**Benefits:**
- ✅ One download for all users
- ✅ Simpler distribution
- ❌ 2x file size

## Size Comparison

| Build Type | Size | Notes |
|------------|------|-------|
| ARM64-only | 5.9MB | Apple Silicon Macs only |
| x86_64-only | 6.0MB | Intel Macs only |
| Universal | ~12MB | Both architectures |

## Dependencies

### Apple Silicon Mac (ARM64)
```bash
brew install mariadb-connector-c libpq
```

### Intel Mac (x86_64)
```bash
# Install Rosetta first
softwareupdate --install-rosetta

# Install x86_64 Homebrew
arch -x86_64 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install dependencies
arch -x86_64 /usr/local/bin/brew install mariadb-connector-c libpq
```

### Building on Apple Silicon for Intel

To build Intel binaries on an Apple Silicon Mac, you need both Homebrew installations:
1. ARM64 Homebrew at `/opt/homebrew` (default)
2. x86_64 Homebrew at `/usr/local` (for cross-compilation)

## Distribution Recommendations

**For GitHub Releases:**
```
✅ TablePro-v0.1.13-arm64.zip (~2MB zipped, ~6MB unzipped)
✅ TablePro-v0.1.13-x86_64.zip (~2MB zipped, ~6MB unzipped)
```

**For simple distribution:**
```
✅ TablePro-v0.1.13-universal.zip (~4MB zipped, ~12MB unzipped)
```

Most modern apps (Discord, Slack, VSCode) distribute separate builds to save bandwidth.

## Build Optimizations

Release builds are optimized with:
- `DEPLOYMENT_POSTPROCESSING = YES` - Enables symbol stripping
- `COPY_PHASE_STRIP = YES` - Strips symbols during copy
- `DEAD_CODE_STRIPPING = YES` - Removes unused code

These settings reduce binary size by ~60% (from 9.4MB to 3.7MB per architecture).

## Quick Start

```bash
# Development (current architecture)
xcodebuild -project TablePro.xcodeproj -scheme TablePro build

# Release builds
./build-release.sh both
```
