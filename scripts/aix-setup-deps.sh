#!/bin/sh
# aix-setup-deps.sh
# Checks and installs all dependencies required to build the SIGAR JNI library on AIX.
# Must be run as root on AIX 7.2+.
# Usage: sh aix-setup-deps.sh

set -e

ANT_VERSION="1.10.14"
ANT_INSTALL_DIR="/opt/apache-ant"
ANT_ARCHIVE="apache-ant-${ANT_VERSION}-bin.tar.gz"
ANT_URL="https://archive.apache.org/dist/ant/binaries/${ANT_ARCHIVE}"
JAVA_HOME_CANDIDATE="/usr/java8_64"

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

info() {
    echo "==> $1"
}

ok() {
    echo "    [OK] $1"
}

# ---------------------------------------------------------------------------
# 1. Check we are on AIX as root
# ---------------------------------------------------------------------------
info "Checking system prerequisites..."

[ "$(uname -s)" = "AIX" ] || fail "This script must run on AIX."

[ "$(id -u)" = "0" ] || fail "This script must be run as root."

AIX_LEVEL=$(oslevel -s)
info "AIX level: ${AIX_LEVEL}"

# Require at least 7.2 (oslevel output is VVVV-MM-TT-PPPP)
AIX_MAJOR=$(echo "${AIX_LEVEL}" | cut -c1-4)
[ "${AIX_MAJOR}" -ge 7200 ] 2>/dev/null || fail "AIX 7.2 or later is required (detected ${AIX_LEVEL})."
ok "AIX version OK"

# Check available space (rough minimum: 1024 MB in /tmp and /opt)
for dir in /tmp /opt; do
    FREE_MB=$(df -m "${dir}" | awk 'NR==2 {print $3}')
    [ "${FREE_MB:-0}" -ge 512 ] || fail "Less than 512 MB free in ${dir} (found ${FREE_MB} MB). Please free up space."
    ok "Disk space in ${dir}: ${FREE_MB} MB free"
done

# ---------------------------------------------------------------------------
# 2. Bootstrap DNF if not present
# ---------------------------------------------------------------------------
info "Checking DNF..."

export PATH=/opt/freeware/bin:/opt/freeware/sbin:$PATH

if ! command -v dnf >/dev/null 2>&1; then
    info "DNF not found — bootstrapping AIX Toolbox DNF..."

    PERL_DOWNLOAD=/usr/opt/perl5/bin/lwp-download
    [ -x "${PERL_DOWNLOAD}" ] || fail \
        "DNF is missing and the Perl downloader (${PERL_DOWNLOAD}) was not found. " \
        "Install Perl for AIX first, or install DNF manually from the AIX Toolbox."

    cd /tmp
    LDR_CNTRL=MAXDATA=0x80000000@DSA "${PERL_DOWNLOAD}" \
        https://public.dhe.ibm.com/aix/freeSoftware/aixtoolbox/ezinstall/ppc/dnf_aixtoolbox.sh
    chmod +x ./dnf_aixtoolbox.sh
    ./dnf_aixtoolbox.sh -d
    cd -

    export PATH=/opt/freeware/bin:/opt/freeware/sbin:$PATH
    command -v dnf >/dev/null 2>&1 || fail "DNF installation failed."
    ok "DNF installed"
else
    ok "DNF already present: $(dnf --version 2>&1 | head -1)"
fi

# ---------------------------------------------------------------------------
# 3. Install git and gcc via DNF if missing
# ---------------------------------------------------------------------------
info "Checking git..."
if ! command -v git >/dev/null 2>&1; then
    info "git not found — installing via DNF..."
    dnf install -y git
else
    ok "git already present: $(git --version)"
fi

info "Checking gcc..."
if ! command -v gcc >/dev/null 2>&1; then
    info "gcc not found — installing via DNF..."
    dnf install -y gcc
else
    ok "gcc already present: $(gcc --version | head -1)"
fi

# ---------------------------------------------------------------------------
# 4. Verify Java 8 JDK
# ---------------------------------------------------------------------------
info "Checking Java 8 JDK..."

# Accept JAVA_HOME if already set and valid; otherwise fall back to known path.
if [ -n "${JAVA_HOME}" ] && [ -x "${JAVA_HOME}/bin/javac" ]; then
    ok "JAVA_HOME already set: ${JAVA_HOME}"
elif [ -x "${JAVA_HOME_CANDIDATE}/bin/javac" ]; then
    export JAVA_HOME="${JAVA_HOME_CANDIDATE}"
    ok "Found Java JDK at ${JAVA_HOME}"
else
    fail "Java 8 JDK not found at ${JAVA_HOME_CANDIDATE} and JAVA_HOME is not set to a valid JDK. " \
         "Install IBM Java 8 (e.g. /usr/java8_64) and re-run this script."
fi

JAVA_VER=$("${JAVA_HOME}/bin/java" -version 2>&1 | head -1)
ok "Java: ${JAVA_VER}"

# ---------------------------------------------------------------------------
# 5. Install Apache Ant if missing
# ---------------------------------------------------------------------------
info "Checking Apache Ant..."

if [ -x "${ANT_INSTALL_DIR}/bin/ant" ]; then
    ok "Ant already installed: $(${ANT_INSTALL_DIR}/bin/ant -version 2>&1)"
elif command -v ant >/dev/null 2>&1; then
    ok "Ant already on PATH: $(ant -version 2>&1)"
else
    info "Ant not found — downloading ${ANT_ARCHIVE}..."

    command -v curl >/dev/null 2>&1 || fail "curl is required to download Ant but was not found. Install curl via: dnf install -y curl"

    cd /tmp
    curl -L -o "${ANT_ARCHIVE}" "${ANT_URL}"
    info "Extracting Ant..."
    gzip -dc "${ANT_ARCHIVE}" | /usr/bin/tar -xf - -C /tmp
    mv "/tmp/apache-ant-${ANT_VERSION}" "${ANT_INSTALL_DIR}"
    rm -f "${ANT_ARCHIVE}"
    cd -

    ok "Ant installed: $(${ANT_INSTALL_DIR}/bin/ant -version 2>&1)"
fi

export PATH="${ANT_INSTALL_DIR}/bin:/opt/freeware/bin:/opt/freeware/sbin:$PATH"

# ---------------------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------------------
echo ""
echo "All dependencies are satisfied. To build SIGAR, run:"
echo ""
echo "  export PATH=${ANT_INSTALL_DIR}/bin:/opt/freeware/bin:/opt/freeware/sbin:\$PATH"
echo "  export JAVA_HOME=${JAVA_HOME}"
echo "  export CC=/opt/freeware/bin/gcc"
echo "  export OBJECT_MODE=64"
echo ""
echo "  cd bindings/java"
echo "  ant clean && ant build"
