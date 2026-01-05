# Building Sigar Native Library for AIX

This document describes how to compile the native Sigar shared library (`libsigar-ppc64-aix-5.so`) for AIX systems.

## Prerequisites

### System Requirements
- AIX 7.1 or later (tested on AIX 7.3)
- IBM XL C/C++ compiler or GCC for AIX
- GNU Make or AIX make
- Root or sudo access (for system header access)

### Required Packages
```bash
# Install required development tools (if using GCC)
yum install gcc-c++ make

# Or ensure IBM XL C/C++ compiler is installed
which xlc
```

## Build Environment Setup

### 1. Set Environment Variables

For **IBM XL C/C++ Compiler** (recommended):
```bash
export CC=xlc_r
export CXX=xlC_r
export CFLAGS="-q64 -O2 -qarch=ppc64 -qtune=pwr7"
export LDFLAGS="-q64 -brtl -G"
export OBJECT_MODE=64
```

For **GCC** (alternative):
```bash
export CC=gcc
export CXX=g++
export CFLAGS="-maix64 -O2 -mcpu=power7"
export LDFLAGS="-maix64 -shared -Wl,-brtl"
export OBJECT_MODE=64
```

### 2. Configure Library Path
```bash
export LIBPATH=/usr/lib:/lib
export LD_LIBRARY_PATH=/usr/lib:/lib
```

## Building the Library

### Method 1: Quick Build with Script (Recommended)

The easiest way to build with GCC:

```bash
# Make the script executable
chmod +x build_aix_gcc.sh

# Run the build
./build_aix_gcc.sh

# The library will be in: build_aix/libsigar-ppc64-aix-5.so
```

The script automatically:
- Sets correct compiler flags for AIX 64-bit
- Compiles all source files
- Links the shared library
- Verifies the output

### Method 2: Manual Compilation (Advanced)

#### Step 1: Compile Object Files

```bash
cd src/os/aix

# Compile AIX-specific source
${CC} ${CFLAGS} -I../../../include -c aix_sigar.c -o aix_sigar.o

# Compile common source files
cd ../../
${CC} ${CFLAGS} -I../../include -I../../src/os/aix -c sigar.c -o sigar.o
${CC} ${CFLAGS} -I../../include -I../../src/os/aix -c sigar_cache.c -o sigar_cache.o
${CC} ${CFLAGS} -I../../include -I../../src/os/aix -c sigar_fileinfo.c -o sigar_fileinfo.o
${CC} ${CFLAGS} -I../../include -I../../src/os/aix -c sigar_format.c -o sigar_format.o
${CC} ${CFLAGS} -I../../include -I../../src/os/aix -c sigar_getline.c -o sigar_getline.o
${CC} ${CFLAGS} -I../../include -I../../src/os/aix -c sigar_ptql.c -o sigar_ptql.o
${CC} ${CFLAGS} -I../../include -I../../src/os/aix -c sigar_signal.c -o sigar_signal.o
${CC} ${CFLAGS} -I../../include -I../../src/os/aix -c sigar_util.c -o sigar_util.o
```

#### Step 2: Link Shared Library

```bash
# Link all object files into shared library
${CC} ${LDFLAGS} -o libsigar-ppc64-aix-5.so \
    sigar.o \
    sigar_cache.o \
    sigar_fileinfo.o \
    sigar_format.o \
    sigar_getline.o \
    sigar_ptql.o \
    sigar_signal.o \
    sigar_util.o \
    os/aix/aix_sigar.o \
    -lperfstat -lodm -lcfg
```

#### Step 3: Verify the Library

```bash
# Check library architecture
file libsigar-ppc64-aix-5.so
# Should output: 64-bit XCOFF executable or object module

# Check symbols
dump -Tv libsigar-ppc64-aix-5.so | grep sigar_

# Test loading
slibclean  # Clear shared library cache
export LIBPATH=.:${LIBPATH}
```

### Method 3: Using CMake (if available)

```bash
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=xlc_r \
      -DCMAKE_C_FLAGS="-q64 -O2" \
      ..
make
```

## Building Java JNI Bindings

If you need the Java Native Interface bindings:

```bash
cd bindings/java/src/jni

# Set JAVA_HOME
export JAVA_HOME=/opt/instana-agent/jvm  # or your Java installation

# Compile JNI wrapper
${CC} ${CFLAGS} \
    -I${JAVA_HOME}/include \
    -I${JAVA_HOME}/include/aix \
    -I../../../../include \
    -c javasigar.c -o javasigar.o

# Link with sigar library
${CC} ${LDFLAGS} -o libsigar-ppc64-aix-5.so \
    javasigar.o \
    -L../../../../src -lsigar \
    -lperfstat -lodm -lcfg
```

## Compiler-Specific Notes

### IBM XL C/C++ Compiler Flags

- `-q64`: Generate 64-bit code
- `-qarch=ppc64`: Target PowerPC 64-bit architecture
- `-qtune=pwr7`: Optimize for POWER7 processors
- `-O2`: Optimization level 2
- `-brtl`: Enable runtime linking
- `-G`: Create shared object

### GCC Compiler Flags

- `-maix64`: Generate 64-bit AIX code
- `-mcpu=power7`: Target POWER7 CPU
- `-shared`: Create shared library
- `-Wl,-brtl`: Pass runtime linking flag to linker

## Required AIX System Libraries

The Sigar library links against these AIX system libraries:

- **libperfstat.a**: Performance statistics library
- **libodm.a**: Object Data Manager library  
- **libcfg.a**: Configuration library

These are typically located in `/usr/lib` or `/usr/lib64`.

## Troubleshooting

### Issue: "Symbol not found" errors

**Solution**: Ensure all required system libraries are linked:
```bash
ldd libsigar-ppc64-aix-5.so
# or
dump -H libsigar-ppc64-aix-5.so
```

### Issue: "Exec format error"

**Solution**: Verify 64-bit compilation:
```bash
file libsigar-ppc64-aix-5.so
# Should show "64-bit"
```

### Issue: Compilation warnings about vmount structures

**Solution**: These are expected on newer AIX versions. The code uses proper NULL checks.

## Installation

### System-wide Installation
```bash
sudo cp libsigar-ppc64-aix-5.so /usr/lib/
sudo chmod 755 /usr/lib/libsigar-ppc64-aix-5.so
sudo slibclean  # Clear shared library cache
```

### Application-specific Installation
```bash
# For Instana agent
cp libsigar-ppc64-aix-5.so /opt/instana-agent/lib/

# Update library path
export LIBPATH=/opt/instana-agent/lib:${LIBPATH}
```

## Testing

### Basic Functionality Test

Create a test program `test_sigar.c`:
```c
#include <stdio.h>
#include <sigar.h>

int main() {
    sigar_t *sigar;
    sigar_file_system_list_t fslist;
    int status;
    
    status = sigar_open(&sigar);
    if (status != SIGAR_OK) {
        fprintf(stderr, "sigar_open failed: %d\n", status);
        return 1;
    }
    
    status = sigar_file_system_list_get(sigar, &fslist);
    if (status != SIGAR_OK) {
        fprintf(stderr, "sigar_file_system_list_get failed: %d\n", status);
        sigar_close(sigar);
        return 1;
    }
    
    printf("Found %d filesystems\n", (int)fslist.number);
    
    sigar_file_system_list_destroy(sigar, &fslist);
    sigar_close(sigar);
    
    return 0;
}
```

Compile and run:
```bash
${CC} ${CFLAGS} -I../include test_sigar.c -L. -lsigar -o test_sigar
export LIBPATH=.:${LIBPATH}
./test_sigar
```

## Version Information

- **Library Name**: libsigar-ppc64-aix-5.so
- **Architecture**: PowerPC 64-bit (ppc64)
- **AIX Version**: 5.x, 6.x, 7.x
- **Sigar Version**: 1.6.5+

## Additional Resources

- [Sigar GitHub Repository](https://github.com/hyperic/sigar)
- [AIX Developer Documentation](https://www.ibm.com/docs/en/aix)
- [IBM XL C/C++ Compiler Documentation](https://www.ibm.com/docs/en/xl-c-and-cpp-aix)
