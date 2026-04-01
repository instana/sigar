# Custom Instana patched sigar library

The Instana agent uses sigar to acces system level information. Since the official project is abandoned we maintain our own version in this repository.
We build upon the last available distribution, which is `org.hyperic:sigar-dist:1.6.5.132-8`. 
Unfortunately this version is not available on any public Maven repository anymore, so its provided [on this branch](sigar-dist/sigar-dist-1.6.5.132-8.zip), too.
Since we do not build architecture specific libraries for all supported architectures we need to support the Java wrapper which is included 
with the afore mentioned version. Re-building the latest code from `master` would result in incompatibilities with the Java wrapper shipped 
with the Instana agent.

## Default branch

Our default branch `sigar-1.6-instana` was forked from the official sigar-1.6 branch on commit 92062ec. All subsequent commits addressing 
IPv6 support on the official sigar-1.6 branch are incompatible with the Java wrapper we use.

## Building Windows 32bit & 64bit DLLs

### Prerequisites

We build patched Windows DLLs on a Windows Server 2016 10.0 node. The following tooling needs to be installed in order to build successfully:
* Java 1.8 (we build using Azul Zulu 1.8)
* Apache ant (we use Apache Ant(TM) version 1.10.11 compiled on July 10 2021)
* git
* Microsoft Visual Studio 2015 Community from [here](https://go.microsoft.com/fwlink/?LinkId=615448&clcid=0x409) (required for ATL headers), ensure to install C++ language support
* Microsoft Windows Software Development Kit (SDK) from [here](https://go.microsoft.com/fwlink/p/?LinkId=323507) (required for Resource Compiler, rc.exe, use Windows 8.1 SDK) See also: https://stackoverflow.com/questions/14372706/visual-studio-cant-build-due-to-rc-exe
* Perl for Windows (we use [Strawberry Perl](https://strawberryperl.com/))

### Build 32bit

* Open "Developer Command Prompt for VS2015" (defaults to 32bit compiler & linker settings)
* export JAVA_HOME: `set JAVA_HOME=<your-java-install>`
* change to `bindings\java`
* run ant (no target required)
* final `sigar-x86-winnt.dll` & `sigar-x86-winnt.lib` are in `bindings\java\sigar-bin\lib`

### Build 64bit

* Open "VS2015 x64 Native Tools Command Prompt" (defaults to 64bit compiler & linker settings)
* export JAVA_HOME: `set JAVA_HOME=<your-java-install>`
* change to `bindings\java`
* run ant (no target required)
* final `sigar-amd64-winnt.dll` & `sigar-amd64-winnt.lib` are in `bindings\java\sigar-bin\lib`

## Building Linux amd64 library

The Linux library is built inside a Docker container based on CentOS 7 to maximise compatibility. CentOS 7 uses **glibc 2.17** and **GCC 4.8.5**, so the resulting binary runs on any Linux with glibc ≥ 2.17 — covering RHEL/CentOS 7+, SLES 12+, Ubuntu 18.04+, and Debian 9+.

### Prerequisites

* Docker

### Build Steps

From the repository root:

```bash
docker build -f Dockerfile.linux-build -t sigar-linux-build .
```

### Copy the output

```bash
docker run --rm \
  -v "$(pwd)":/output \
  sigar-linux-build \
  cp /build/sigar/bindings/java/sigar-bin/lib/libsigar-amd64-linux.so /output/
```

The file will appear at `libsigar-amd64-linux.so` in the project root.

### Notes

* CentOS 7 is EOL (June 2024). The Dockerfile redirects `yum` to `vault.centos.org` so package installation still works.
* The build uses **OpenJDK 1.8** and **GCC 4.8.5** from the CentOS 7 vault.
* The Ant target `build-jni` compiles only the native JNI shared library. To also build the Java `.jar`, use `ant build` instead.
* `src/os/linux/linux_sigar.c` explicitly includes `<sys/sysmacros.h>` to ensure `major()`/`minor()` are available as macros on glibc 2.28+ (Debian 10, RHEL 8, etc.), where they were removed from `<sys/types.h>`.

## Building AIX ppc64 library

We build the AIX library on AIX 7 using GCC. The resulting library is compatible with AIX 7.x systems.

### Prerequisites

* Java JDK 1.8 (we use the JVM from `/opt/instana-agent/jvm`)
* Apache Ant
* GCC compiler for AIX
* Perl (for code generation)

### Build Steps

```bash
cd bindings/java

# Set environment
export JAVA_HOME=/opt/instana-agent/jvm
export CC=gcc
export OBJECT_MODE=64

# Clean and build
ant clean
ant build
```

### Build Output

The library will be generated as `bindings/java/sigar-bin/lib/libsigar-ppc64-aix-7.so` (~364KB).

**Note:** The library is named with `-7` (AIX version 7), but the Java wrapper expects `-5`. You must update the `ArchName.java` file in your application repository to map AIX 7 to version 5, or rename the library after building.

### AIX Portability Configuration

The build uses special GCC linker flags to ensure maximum portability across different AIX systems:

* **`-static-libgcc`**: Statically links the GCC runtime library into the `.so` file, eliminating the dependency on `libgcc_s.a`. This allows the library to work on AIX systems that don't have GCC installed or have different GCC versions.

* **`-Wl,-blibpath:/usr/lib:/lib`**: Explicitly sets the library search path to only standard AIX system directories. Without this flag, GCC embeds its installation paths (e.g., `/opt/freeware/lib/gcc/powerpc-ibm-aix7.3.0.0/13/`) into the library, causing it to fail on systems with different GCC installations.

These flags ensure the library depends only on standard AIX system libraries (`libc_r.a`, `libodm.a`, `libcfg.a`, `libperfstat.a`, `libpthreads.a`) and works across different AIX environments.

### Verification

```bash
# Check file type (should be 64-bit XCOFF)
file sigar-bin/lib/libsigar-ppc64-aix-7.so

# Check for JNI symbols (should be 100+)
dump -Tv sigar-bin/lib/libsigar-ppc64-aix-7.so | grep -c "Java_org_hyperic"

# Check thread-safe library (should show libc_r.a)
dump -H sigar-bin/lib/libsigar-ppc64-aix-7.so | grep "libc"

# Verify portability (should show only /usr/lib:/lib path, no GCC paths)
dump -X64 -H sigar-bin/lib/libsigar-ppc64-aix-7.so | grep -A 10 "Import File Strings"
```

