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
* Microsoft Visual Studio 2015 Community from [here](https://go.microsoft.com/fwlink/?LinkId=615448&clcid=0x409) (required for ATL headers)
* Perl for Windows (we use [Strawberry Perl](https://strawberryperl.com/))

### Build 32bit

* Open "Developer Command Prompt for VS2015" (defaults to 32bit compiler & linker settings)
* export JAVA_HOME: `set JAVA_HOME=<your-java-install>`
* change to `bindings\java`
* run ant (no target required)
* final `sigar-x86-winnt.dll` & `sigar-x86-winnt.lib` are in `bindings\java\sigar-bin\lib`

### Build 64bit

* Open "Visual C++ x64 Native Build Tools Command Prompt" (defaults to 64bit compiler & linker settings)
* export JAVA_HOME: `set JAVA_HOME=<your-java-install>`
* change to `bindings\java`
* run ant (no target required)
* final `sigar-amd64-winnt.dll` & `sigar-amd64-winnt.lib` are in `bindings\java\sigar-bin\lib`

