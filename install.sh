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
# Where the packages come from, in order:
#   1. GitHub Releases on this repository - the .deb files exactly as
#      `make deb` builds them, named onidia_<version>_<arch>.deb. No git
#      history is spent on 20MB binaries, which every future clone would
#      otherwise download forever.
#   2. If that fails, a plain apt repository (make apt-repo), for anyone
#      mirroring.
# Either way the answer is a version and a URL, and nothing below cares
# which produced it.
#
# Usage:
#   curl -fsSL https://onidia.babeh.com/install.sh | sh
#   curl -fsSL https://onidia.babeh.com/install.sh | sh -s -- --dry-run
#   curl -fsSL https://onidia.babeh.com/install.sh | sh -s -- --arch
#
# Environment overrides:
#   ONIDIA_REPO     apt repository root (fallback source)
#   ONIDIA_API      GitHub "latest release" API URL (preferred source)
#   ONIDIA_VERSION  pin a version instead of resolving the newest one
set -eu

API="${ONIDIA_API:-https://api.github.com/repos/portege/onidia-web/releases/latest}"
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
    ONIDIA_REPO     apt repository root, used when Releases is unreachable
    ONIDIA_API      GitHub latest-release API (default: this repo)
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

# Checked up front: without it a missing curl would surface much later as
# "no package published", which sends you looking in the wrong place.
have curl || have wget || die "need curl or wget, and neither is installed"

say "onidia: machine reports $MACHINE, package architecture is $ARCH"

# What is installed right now? Same database apt reads.
installed=$(dpkg-query -W -f='${Version}' onidia 2>/dev/null || echo '')

# ---------------------------------------------------------------------------
# 2. which build is the newest one for that architecture?
#
# Two sources, tried in order. Neither has a version baked in, so neither goes
# stale the day a release ships.
# ---------------------------------------------------------------------------
INDEX="$REPO/dists/stable/main/binary-$ARCH/Packages"

# 2a. GitHub Releases. The .deb files are release ASSETS, so no 20MB binary
# ever enters git history - which is the whole reason for hosting them on the
# site repo rather than committing them.
#
# There is no stable "latest .deb" URL, because the filename carries the
# version and we do not know it until we ask; the API is how you ask. No token
# needed - unauthenticated is 60 requests an hour per IP, which is plenty for
# one install per person.
resolve_github() {
	json=$(fetch "$API") || return 1
	[ -n "$json" ] || return 1

	# The API quotes every value, so this needs no JSON parser and no jq.
	tag=$(printf '%s\n' "$json" \
		| grep -o '"tag_name": *"[^"]*"' \
		| head -n1 | sed 's/^.*"\(.*\)"$/\1/')
	[ -n "$tag" ] || return 1
	version=${tag#v}        # tags read v1.0.0, filenames read 1.0.0

	# Only this architecture's asset. Matching _<arch>.deb is exact, so an
	# armhf search cannot be satisfied by an arm64 file or the reverse.
	url=$(printf '%s\n' "$json" \
		| grep -o '"browser_download_url": *"[^"]*"' \
		| grep "onidia_${version}_${ARCH}\.deb" \
		| head -n1 | sed 's/^.*: *"//; s/"$//')
	[ -n "$url" ] || return 1

	printf '%s %s\n' "$version" "$url"
}

# 2b. A plain apt repository, for anyone mirroring. `make apt-repo` writes this
# exact layout, so the Packages index is the same one apt itself reads.
resolve_apt() {
	# A pinned version needs no index: the pool path is predictable.
	if [ -n "${1:-}" ]; then
		printf '%s %s\n' "$1" "$REPO/pool/main/o/onidia/onidia_$1_${ARCH}.deb"
		return 0
	fi

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

	printf '%s %s\n' "$version" "$REPO/$filename"
}

# Releases first, mirror second. A pinned version skips to the mirror, because
# Releases only ever describes the newest one.
if resolved=$(resolve_github) || resolved=$(resolve_apt "${ONIDIA_VERSION:-}"); then
	VERSION=${resolved%% *}
	URL=${resolved##* }        # both sources hand back an absolute URL
else
	die "no Onidia package published for $ARCH.
       Looked for a release at $API
       and in the apt mirror at $REPO
       Building it yourself? make deb, then upload the .deb as a release asset
       named onidia_<version>_${ARCH}.deb."
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