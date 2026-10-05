#!/bin/sh
# install.sh - fetch and install the Onidia package built for THIS machine.
#
# Why this exists: the .deb filename carries the architecture
# (onidia_1.0.0_arm64.deb vs _amd64.deb vs _armhf.deb), so a hand-written
# one-liner has to guess it. Guessing wrong either fails to install or, worse,
# hands apt a package it cannot execute. This script asks dpkg instead.
#
# Detection is `dpkg --print-architecture`, NOT `uname -m`, and the difference
# matters on Raspberry Pi: a 64-bit kernel running 32-bit userland (the usual
# Pi OS today) reports aarch64 from uname but armhf from dpkg, and the .deb has
# to be the armhf one. dpkg is also the exact vocabulary used to match a
# package, so whatever we pick here is what apt would have picked itself.
#
# The armel/armhf split is equally not cosmetic - see packaging/mkdeb.sh:
# Debian's armhf requires ARMv7 + VFPv3, so a GOARM=6 build (Pi Zero, Pi 1)
# has to claim armel or apt will offer it to a CPU that cannot run it.
#
# Usage:
#   curl -fsSL https://onidia.babeh.com/install.sh | sh
#   curl -fsSL https://onidia.babeh.com/install.sh | sh -s -- --dry-run
#   curl -fsSL https://onidia.babeh.com/install.sh | sh -s -- --arch
#
# Environment overrides:
#   ONIDIA_REPO     apt repository root (default https://onidia.babeh.com/download/apt)
#   ONIDIA_VERSION  pin a version instead of resolving the newest one
set -eu

REPO="${ONIDIA_REPO:-https://onidia.babeh.com/download/apt}"
DRYRUN=0
ARCHONLY=0

say() { printf '%s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Inline rather than sed'd out of $0: when this runs as `curl ... | sh`, $0 is
# "sh", not this file, so there is nothing on disk to read the header from.
usage() {
	cat <<'USAGE'
install.sh - fetch and install the Onidia package built for THIS machine.

  Usage:
    curl -fsSL https://onidia.babeh.com/install.sh | sh
    curl -fsSL https://onidia.babeh.com/install.sh | sh -s -- --dry-run
    curl -fsSL https://onidia.babeh.com/install.sh | sh -s -- --arch

  Options:
    --dry-run   print what would be fetched and install nothing
    --arch      print this machine's package architecture and exit
    -h, --help  this text

  Environment:
    ONIDIA_REPO     apt repository root
                    (default https://onidia.babeh.com/download/apt)
    ONIDIA_VERSION  pin a version instead of resolving the newest one

  Architectures: amd64, arm64, armhf, armel, i386.
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRYRUN=1 ;;
		--arch)    ARCHONLY=1 ;;
		-h|--help) usage; exit 0 ;;
		*)         die "unknown option: $1 (try --help)" ;;
	esac
	shift
done

# download $1 to stdout. silent on failure, so callers can test with $( ).
fetch() {
	if have curl; then
		curl -fsSL --retry 3 --retry-delay 2 "$1" 2>/dev/null
	elif have wget; then
		wget -qO- "$1" 2>/dev/null
	fi
}

# download $1 to file $2
fetch_to() {
	if have curl; then
		curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1"
	elif have wget; then
		wget -qO "$2" "$1"
	else
		die "need curl or wget to download the package"
	fi
}

# ---------------------------------------------------------------------------
# 1. which architecture is this, in the words the .deb filenames use?
# ---------------------------------------------------------------------------
detect_arch() {
	if have dpkg; then
		a=$(dpkg --print-architecture 2>/dev/null || echo '')
		case "$a" in
			amd64|arm64|armhf|armel|i386) printf '%s\n' "$a"; return 0 ;;
		esac
	fi

	# No dpkg, or an architecture we have no build for. Fall back to uname,
	# using the same mapping as packaging/mkdeb.sh.
	case "$(uname -m 2>/dev/null || echo unknown)" in
		x86_64|amd64)        echo amd64 ;;
		aarch64|arm64)       echo arm64 ;;
		armv7l|armhf)        echo armhf ;;
		armv6l|armel)        echo armel ;;
		i386|i486|i586|i686) echo i386 ;;
		*)                   echo unknown ;;
	esac
}

ARCH=$(detect_arch)

if [ "$ARCHONLY" -eq 1 ]; then
	say "$ARCH"
	exit 0
fi

MACHINE=$(uname -m 2>/dev/null || echo '?')
case "$ARCH" in
	amd64|arm64|armhf|armel|i386) ;;
	*)
		die "cannot identify this machine (uname says '$MACHINE'), so we cannot pick a
       package. Onidia is published for amd64, arm64, armhf, armel and i386.
       On anything else, build it yourself: make deb" ;;
esac

have apt && APT=apt || APT=apt-get
have "$APT" || die "no apt on this system; this installer is for Debian, Ubuntu and friends"

say "onidia: machine reports $MACHINE, package architecture is $ARCH"

# What is installed right now? Same database apt reads.
installed=$(dpkg-query -W -f='${Version}' onidia 2>/dev/null || echo '')

# ---------------------------------------------------------------------------
# 2. which build is the newest one for that architecture?
#
# The repo is laid out by `make apt-repo` (packaging/mkrepo.sh), so the same
# Packages index apt itself reads is right here to answer that. Reading it
# beats hardcoding a version, which goes stale the day a new one ships.
# ---------------------------------------------------------------------------
INDEX="$REPO/dists/stable/main/binary-$ARCH/Packages"

# -> "<version> <pool/path.deb>", or non-zero if nothing is published.
resolve() {
	if [ -n "${1:-}" ]; then
		printf '%s pool/main/o/onidia/onidia_%s_%s.deb\n' "$1" "$1" "$ARCH"
		return 0
	fi

	have curl || have wget || die "need curl or wget to download the package"

	index=$(fetch "$INDEX") || return 1
	[ -n "$index" ] || return 1

	# One stanza per package, so Version: and Filename: are only ours while
	# pkg is onidia. `sort -V` is GNU coreutils, which every Debian has.
	version=$(printf '%s\n' "$index" | awk '
		$1 == "Package:" { pkg = $2 }
		pkg == "onidia" && $1 == "Version:" { print $2 }
	' | sort -V | tail -n 1)
	[ -n "$version" ] || return 1

	filename=$(printf '%s\n' "$index" | awk -v v="$version" '
		$1 == "Package:"  { pkg = $2; ver = "" }
		$1 == "Version:"  { ver = $2 }
		$1 == "Filename:" { if (pkg == "onidia" && ver == v) { print $2; exit } }
	')
	[ -n "$filename" ] || return 1

	printf '%s %s\n' "$version" "$filename"
}

if resolved=$(resolve "${ONIDIA_VERSION:-}"); then
	VERSION=${resolved%% *}
	FILE=${resolved##* }
	URL="$REPO/$FILE"
else
	die "no Onidia package published for $ARCH at $INDEX
       Building it yourself? make deb, then make apt-repo."
fi

say "onidia: $VERSION for $ARCH"

if [ -n "$installed" ] && [ "$installed" = "$VERSION" ]; then
	say "onidia: already at $VERSION, nothing to do"
	exit 0
fi

if [ "$DRYRUN" -eq 1 ]; then
	say ""
	say "  architecture : $ARCH (uname $MACHINE)"
	say "  version      : $VERSION${installed:+ (you have $installed)}"
	say "  url          : $URL"
	say ""
	exit 0
fi

# ---------------------------------------------------------------------------
# 3. download it, and prove it is a package before handing it to apt
# ---------------------------------------------------------------------------
have dpkg-deb || die "dpkg-deb not found; cannot verify the download"

TMP=$(mktemp -d) || die "could not make a temporary directory"
trap 'rm -rf "$TMP"' EXIT INT TERM

DEB="$TMP/onidia_${VERSION}_${ARCH}.deb"

say "onidia: downloading"
fetch_to "$URL" "$DEB" || die "download failed: $URL"

# A truncated download, or a captive-portal/login HTML page served with a 200,
# both leave a file that is not a package. Catch that here, where the message
# can say why, instead of letting apt fail with something cryptic.
if ! dpkg-deb --info "$DEB" >/dev/null 2>&1; then
	die "that download is not a Debian package.
       $URL
       Check the connection and retry. Behind a proxy, set https_proxy."
fi

# Belt and braces: the repository should never serve the wrong architecture,
# but if it does, installing it would produce a binary this CPU cannot run.
got=$(dpkg-deb -f "$DEB" Architecture)
[ "$got" = "$ARCH" ] || die "downloaded a $got package but this machine is $ARCH.
       The repository is serving the wrong file - please report it."

# ---------------------------------------------------------------------------
# 4. install
#
# apt, not dpkg -i, on purpose: the .deb Recommends the audio and PipeWire
# packages she needs, and apt resolves those in the same step. dpkg -i would
# leave a half-configured app behind.
# ---------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
	SUDO=''
elif have sudo; then
	SUDO='sudo'
else
	die "need root to install; re-run it with sudo"
fi

say "onidia: installing"
# shellcheck disable=SC2086  # SUDO is deliberately empty or one word
# shellcheck disable=SC2086  # "$DEB" must stay quoted, APT is a single word
$SUDO "$APT" install -y "$DEB" || die "apt install failed"

say ""
say "onidia: installed. Two more things and she is awake:"
say ""
say "  1. put your key in ~/.config/chat-app/chat-app.ini"
say "     (or export GEMINI_API_KEY=...)"
say "  2. start onidia first, then onidia-chat - they share a speech pipe"
say ""
say "  start menu:  Internet -> Onidia Chat   (Games -> Onidia for the pet)"
say ""