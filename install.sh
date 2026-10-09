#!/usr/bin/env bash
#
# install.sh — build WebBound in Release and copy it to a stable location.
#
# Usage:
#   ./install.sh                 # installs to ~/bin/webbound
#   ./install.sh /custom/path    # installs to /custom/path
#
# Safe to rerun. Build output lives in ./build/ (not DerivedData), so you can
# delete the whole ./build/ directory at any time without side effects.
#
set -euo pipefail

cd "$(dirname "$0")"

DEST="${1:-$HOME/bin/webbound}"
PROJECT="WebBound.xcodeproj"
SCHEME="WebBound"
BUILD_DIR="build"

if [[ ! -d "$PROJECT" ]]; then
    echo "error: $PROJECT not found in $(pwd)" >&2
    exit 1
fi

echo "==> Building $SCHEME (Release) ..."
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    build \
    | sed -n '/error:/p;/warning:/p;/BUILD SUCCEEDED/p;/BUILD FAILED/p'

BIN_SRC="$BUILD_DIR/Build/Products/Release/WebBound"
if [[ ! -x "$BIN_SRC" ]]; then
    echo "error: built binary not found at $BIN_SRC" >&2
    exit 1
fi

echo "==> Installing to $DEST ..."
mkdir -p "$(dirname "$DEST")"
cp "$BIN_SRC" "$DEST"
chmod +x "$DEST"

echo
echo "Installed: $DEST"
echo "Size:      $(du -h "$DEST" | cut -f1)"
echo
echo "Try: $DEST --help"

# Friendly PATH hint — don't modify shell config, just mention it.
DEST_DIR="$(dirname "$DEST")"
case ":$PATH:" in
    *":$DEST_DIR:"*) ;;  # already on PATH
    *)
        echo
        echo "note: $DEST_DIR is not on your PATH."
        echo "      Add this to ~/.zshrc to run it as just 'webbound':"
        echo "          export PATH=\"$DEST_DIR:\$PATH\""
        ;;
esac
