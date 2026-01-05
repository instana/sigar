#!/bin/bash
# Simple build script for Sigar on AIX using GCC
# Usage: ./build_aix_gcc.sh

set -e  # Exit on error

echo "=== Building Sigar for AIX with GCC ==="

# Set environment variables
export CC=gcc
export CFLAGS="-maix64 -O2 -mcpu=power7"
export LDFLAGS="-maix64 -shared -Wl,-brtl"
export OBJECT_MODE=64

echo "Compiler: $CC"
echo "CFLAGS: $CFLAGS"
echo "LDFLAGS: $LDFLAGS"
echo ""

# Create build directory
BUILD_DIR="build_aix"
rm -rf $BUILD_DIR
mkdir -p $BUILD_DIR

echo "Step 1: Compiling AIX-specific source..."
$CC $CFLAGS -I./include -c src/os/aix/aix_sigar.c -o $BUILD_DIR/aix_sigar.o

echo "Step 2: Compiling common source files..."
$CC $CFLAGS -I./include -I./src/os/aix -c src/sigar.c -o $BUILD_DIR/sigar.o
$CC $CFLAGS -I./include -I./src/os/aix -c src/sigar_cache.c -o $BUILD_DIR/sigar_cache.o
$CC $CFLAGS -I./include -I./src/os/aix -c src/sigar_fileinfo.c -o $BUILD_DIR/sigar_fileinfo.o
$CC $CFLAGS -I./include -I./src/os/aix -c src/sigar_format.c -o $BUILD_DIR/sigar_format.o
$CC $CFLAGS -I./include -I./src/os/aix -c src/sigar_getline.c -o $BUILD_DIR/sigar_getline.o
$CC $CFLAGS -I./include -I./src/os/aix -c src/sigar_ptql.c -o $BUILD_DIR/sigar_ptql.o
$CC $CFLAGS -I./include -I./src/os/aix -c src/sigar_signal.c -o $BUILD_DIR/sigar_signal.o
$CC $CFLAGS -I./include -I./src/os/aix -c src/sigar_util.c -o $BUILD_DIR/sigar_util.o

echo "Step 3: Linking shared library..."
$CC $LDFLAGS -o $BUILD_DIR/libsigar-ppc64-aix-5.so \
    $BUILD_DIR/sigar.o \
    $BUILD_DIR/sigar_cache.o \
    $BUILD_DIR/sigar_fileinfo.o \
    $BUILD_DIR/sigar_format.o \
    $BUILD_DIR/sigar_getline.o \
    $BUILD_DIR/sigar_ptql.o \
    $BUILD_DIR/sigar_signal.o \
    $BUILD_DIR/sigar_util.o \
    $BUILD_DIR/aix_sigar.o \
    -lperfstat -lodm -lcfg -lpthread

echo ""
echo "Step 4: Verifying library..."
file $BUILD_DIR/libsigar-ppc64-aix-5.so

echo ""
echo "Step 5: Checking symbols..."
dump -Tv $BUILD_DIR/libsigar-ppc64-aix-5.so | grep -c "sigar_" || true

echo ""
echo "=== Build Complete ==="
echo "Library location: $BUILD_DIR/libsigar-ppc64-aix-5.so"
echo ""
echo "To install for Instana agent:"
echo "  cp $BUILD_DIR/libsigar-ppc64-aix-5.so /opt/instana-agent/lib/"
echo "  chmod 755 /opt/instana-agent/lib/libsigar-ppc64-aix-5.so"
echo ""
echo "To test the library:"
echo "  export LIBPATH=$PWD/$BUILD_DIR:\$LIBPATH"
echo "  # Then run your application"

# Made with Bob
