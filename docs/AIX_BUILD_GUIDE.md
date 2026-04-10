# SIGAR build guide for a fresh AIX host

This document describes the full step-by-step process to build the SIGAR Java JNI library on a fresh AIX 7.2 host, based on a successful build performed on `your-aix-hostname`.

## Result

The build produces:

-  bindings/java/sigar-bin/lib/libsigar-ppc64-aix-7.so

The validated output library was:

- 64-bit XCOFF
- built successfully on AIX 7.2
- linked against standard AIX system libraries only
- configured with import path `/usr/lib:/lib`

## Target platform

Validated on:

- AIX `7200-05-11-2546`
- 64-bit mode
- GCC from AIX Toolbox
- Java 8 JDK from [`/usr/java8_64`]( /usr/java8_64 )

## Prerequisites

You need the following on the AIX host:

- root SSH access
- AIX 7.2 or later
- RPM runtime
- DNF configured for AIX Toolbox
- git
- gcc
- Perl
- Java 8 JDK
- Apache Ant

## 1. Connect to the AIX host

From your local machine:

```shell
ssh root@your-aix-hostname
```

## 2. Verify the base system

Check AIX version, user, and available space:

```shell
id
oslevel -s
df -m /tmp /opt
```

Expected:

- root user
- AIX 7.2+
- around 1 GB free in both [`/tmp`]( /tmp ) and [`/opt`]( /opt ) is a good minimum

## 3. Install DNF on a fresh AIX system

If `/opt/freeware/bin/dnf` is not present, install it using IBM's AIX Toolbox bootstrap script.

Use the preinstalled Perl downloader:

```shell
cd /tmp
LDR_CNTRL=MAXDATA=0x80000000@DSA /usr/opt/perl5/bin/lwp-download \
  https://public.dhe.ibm.com/aix/freeSoftware/aixtoolbox/ezinstall/ppc/dnf_aixtoolbox.sh
chmod +x ./dnf_aixtoolbox.sh
./dnf_aixtoolbox.sh -d
```

Notes:

- The script installs DNF and required dependencies.

## 4. Make sure AIX Toolbox binaries are in `PATH`

Add these directories before using DNF-installed tools:

```shell
export PATH=/opt/freeware/bin:/opt/freeware/sbin:$PATH
```

Verify:

```shell
dnf --version
```

## 5. Install Git and GCC

Install the required compiler and source-control tools:

```shell
dnf install -y git gcc
```

Verify:

```shell
git --version
gcc --version
```

Validated versions:

- Git `2.51.2`
- GCC `13.3.0`

## 6. Verify Java 8 JDK

The README mentions [`/opt/instana-agent/jvm`]( /opt/instana-agent/jvm ), but on the validated host that path did not exist.

A working Java 8 JDK was available here instead:

- `/usr/java8_64`

Verify:

```shell
/usr/java8_64/bin/java -version
/usr/java8_64/bin/javac -version
```

Validated version:

- Java `1.8.0_461`

Set:

```shell
export JAVA_HOME=/usr/java8_64
```

## 7. Install Apache Ant manually

AIX Toolbox did not provide an [`ant`](ant) package on the validated host, so Ant was installed from the Apache archive.

Download Ant:

```shell
cd /tmp
curl -L -o apache-ant-1.10.14-bin.tar.gz \
  https://archive.apache.org/dist/ant/binaries/apache-ant-1.10.14-bin.tar.gz
```

Extract it using AIX-compatible commands:

```shell
gzip -dc apache-ant-1.10.14-bin.tar.gz | /usr/bin/tar -xf - -C /tmp
mv /tmp/apache-ant-1.10.14 /opt/apache-ant
```

Verify:

```shell
export JAVA_HOME=/usr/java8_64
/opt/apache-ant/bin/ant -version
```

Expected:

```text
Apache Ant(TM) version 1.10.14
```

Optionally add Ant to [`PATH`](PATH):

```shell
export PATH=/opt/apache-ant/bin:/opt/freeware/bin:/opt/freeware/sbin:$PATH
```

## 8. Clone the SIGAR repository

Clone the repository:

```shell
cd /
git clone https://github.com/instana/sigar.git /sigar
cd /sigar
```

## 9. Build SIGAR on AIX

Go to the Java binding directory:

```shell
cd /sigar/bindings/java
```

Set the environment:

```shell
export PATH=/opt/apache-ant/bin:/opt/freeware/bin:/opt/freeware/sbin:$PATH
export JAVA_HOME=/usr/java8_64
export CC=/opt/freeware/bin/gcc
export OBJECT_MODE=64
```

Run the build:

```shell
ant clean
ant build
```

## 10. Build artifacts

After a successful build, the important output is:

- `/sigar/bindings/java/sigar-bin/lib/libsigar-ppc64-aix-7.so`

## 11. Verify the resulting library

### Check file type

```shell
file /sigar/bindings/java/sigar-bin/lib/libsigar-ppc64-aix-7.so
```

Expected result:

- `64-bit XCOFF executable or object module`

### Check exported JNI symbols

Use AIX 64-bit dump mode:

```shell
dump -X64 -Tv /sigar/bindings/java/sigar-bin/lib/libsigar-ppc64-aix-7.so | grep -c "Java_org_hyperic"
```

Validated result:

- `88`

You can inspect the first few symbols:

```shell
dump -X64 -Tv /sigar/bindings/java/sigar-bin/lib/libsigar-ppc64-aix-7.so | grep "Java_org_hyperic" | head
```

### Check thread-safe libc linkage

```shell
dump -X64 -H /sigar/bindings/java/sigar-bin/lib/libsigar-ppc64-aix-7.so | grep "libc"
```

Validated result included:

- `libc_r.a`
- `libcfg.a`

### Check import file strings

```shell
dump -X64 -H /sigar/bindings/java/sigar-bin/lib/libsigar-ppc64-aix-7.so | sed -n "/Import File Strings/,\$p" | sed -n "1,20p"
```

Validated result:

```text
***Import File Strings***
INDEX  PATH                          BASE                MEMBER
0      /usr/lib:/lib
1                                    libodm.a            shr_64.o
2                                    libcfg.a            shr_64.o
3                                    libperfstat.a       shr_64.o
4                                    libpthreads.a       shr_xpg5_64.o
5                                    libc_r.a            shr_64.o
```

This confirms the shared object uses only standard AIX library paths and does not embed GCC-specific library paths.
