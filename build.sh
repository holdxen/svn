#!/bin/bash
# build.sh - One-step build script for subversion
# Usage: ./build.sh [clean]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Clean if requested
if [ "$1" = "clean" ]; then
    echo "=== Cleaning ==="
    rm -rf build .xmake
fi

# Step 1: Build serf and install dependencies
echo "=== Step 1: Building dependencies and serf ==="
xmake build -y svn-build

# Step 2: Install subversion
echo ""
echo "=== Step 2: Installing subversion ==="
xmake require -y subversion

# Step 3: Install all to build/install
echo ""
echo "=== Step 3: Installing to build/install ==="
xmake install -y subversion-install

echo ""
echo "============================================================"
echo "Build complete!"
echo "Output: $SCRIPT_DIR/build/install"
echo ""
echo "Usage:"
echo "  $SCRIPT_DIR/build/install/bin/svn --version"
echo "============================================================"
