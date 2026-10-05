#!/bin/sh
# install.sh - fetch and install the Onidia package built for THIS machine.
#
# Why this exists: the .deb filename carries the architecture
# (onidia_1.0.0_arm64.deb vs _amd64.deb vs _armhf.deb), so a hand-written
# one-liner has to guess it. Guessing wrong either fails to install or, worse,
# hands apt a package it cannot execute. This script asks dpkg instead.
#
# Detection asks `dpkg --print-architecture` first, because that is the exact
# vocabulary used to match a package - whatever we pick here is what apt would
# have picked itself. It matters on Raspberry Pi: a 64-bit kernel running
# 32-bit userland (the usual Pi OS today) reports aarch64 from uname but armhf
# from dpkg, and the .deb has to be the armhf one.
#
# There is exactly one place uname overrides dpkg, and it is the whole reason
# armel exists: Raspberry Pi OS is "armhf" on EVERY 32-bit board, including the
# ARMv6 ones (the original Pi Zero / Pi 1). On those dpkg cannot tell you what
# the CPU is and uname can, so armv6l wins and we take the armel package.
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

# The release LIST, deliberately not .../releases/latest. That endpoint only
# ever answers with the newest release that is NOT a prerelease, and returns
# 404 when they all are - which is how "no Onidia package published for armhf"
# was reported while the armhf .deb sat on the only release we had, flagged
# prerelease. The plain list includes prereleases and still puts the newest
# release first.
API="${ONIDIA_API:-https://api.github.com/repos/portege/onidia-web/releases}"
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
	m=$(uname -m 2>/dev/null || echo unknown)

	if have dpkg; then
		a=$(dpkg --print-architecture 2>/dev/null || echo '')
		case "$a" in
			amd64|arm64|armel|i386) printf '%s\n' "$a"; return 0 ;;
			armhf)
				# dpkg says "armhf" on every 32-bit Raspberry Pi OS, and that
				# includes the ARMv6 boards: the OS is armhf, the CPU is not.
				# The armhf package is a GOARM=7 build and dies with SIGILL on a
				# BCM2835, so on an ARMv6 CPU uname outranks the userland and we
				# take armel. Same rule as `make deb TARGET=` and the Makefile's
				# "uname -m on the TARGET decides: armv6l -> armel".
				# An aarch64 kernel with 32-bit userland does NOT land here, so
				# that still correctly resolves to armhf.
				case "$m" in
					armv6l|armv5*) echo armel; return 0 ;;
				esac
				printf '%s\n' "$a"; return 0 ;;
		esac
	fi

	# No dpkg, or an architecture we have no build for. Fall back to uname,
	# using the same mapping as packaging/mkdeb.sh.
	case "$m" in
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
#
# $API is the release LIST rather than .../releases/latest - see where it is
# set, and the note there on why "latest" 404s for a prerelease-only repo.
resolve_github() {
	json=$(fetch "$API") || return 1
	[ -n "$json" ] || return 1

	# The API quotes every value, so this needs no JSON parser and no jq.
	#
	# Only this architecture's asset. Matching _<arch>.deb is exact, so an
	# armhf search cannot be satisfied by an arm64 file or the reverse. The
	# list is newest release first, so head -n1 is the newest release that
	# actually carries this architecture - a newer one that shipped without
	# armhf no longer hides the older one that has it.
	url=$(printf '%s\n' "$json" \
		| grep -o '"browser_download_url": *"[^"]*"' \
		| grep "onidia_.*_${ARCH}\.deb" \
		| head -n1 | sed 's/^.*: *"//; s/"$//')
	[ -n "$url" ] || return 1

	# The version comes out of the filename (onidia_1.0.0_armhf.deb) rather
	# than out of tag_name, so the tag and the asset cannot disagree, and a
	# tag that does not read as a version cannot break the match. Tags read
	# v1.0.0 while filenames read 1.0.0; this sidesteps the difference.
	name=${url##*/}
	version=${name#onidia_}
	version=${version%_${ARCH}.deb}
	[ -n "$version" ] || return 1

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

# The filename is where the version came from, and it is what we print and what
# apt compares against next time, so the package has to agree with it. Asking
# the artifact replaces the old tag-versus-filename cross-check, which cannot
# survive the move off releases/latest, and is a better check anyway: it is the
# thing being installed answering, not a string beside it. 1.0.0-2 is still the
# upstream 1.0.0, hence the strip.
gotv=$(dpkg-deb -f "$DEB" Version 2>/dev/null || echo '')
upstream=${gotv%%-*}
[ "$upstream" = "$VERSION" ] || die "the package claims version $gotv but its filename says $VERSION.
       $URL
       The upload went wrong - please report it."

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

# The architecture apt/dpkg think they are, which can differ from $ARCH: on an
# ARMv6 Pi Zero, Raspberry Pi OS calls itself armhf while detect_arch knows the
# CPU is ARMv6 and asks for armel (see detect_arch).
sysarch=$(dpkg --print-architecture 2>/dev/null || echo '')

say "onidia: installing"
if [ "$ARCH" = "$sysarch" ]; then
	# shellcheck disable=SC2086  # SUDO is deliberately empty or one word
	# shellcheck disable=SC2086  # "$DEB" must stay quoted, APT is a single word
	$SUDO "$APT" install -y "$DEB" || die "apt install failed"
else
	# A package for a Debian architecture this system has not enabled. dpkg
	# refuses it outright ("package architecture (armel) does not match
	# system (armhf)"), and apt inherits the same objection - which would
	# leave the Pi Zero with no way to install anything, armel being the only
	# build its CPU can execute.
	#
	# Forcing it is safe here and nowhere else, because of exactly what this
	# package is: a statically linked Go binary with an EMPTY Depends (check
	# with `dpkg-deb -f onidia_<ver>_<arch>.deb Depends`) - no ABI, no shared
	# library, nothing for dpkg to match against the system architecture.
	say "onidia: this system reports $sysarch, the package is $ARCH - forcing it"
	# shellcheck disable=SC2086  # SUDO is deliberately empty or one word
	$SUDO dpkg -i --force-architecture "$DEB" \
		|| die "could not install the $ARCH package on this $sysarch system"

	# dpkg does not act on Recommends, and apt would only look for them under
	# the package's own architecture, where they do not exist. They are plain
	# package names though (alsa-utils, python3, ...), so install them for the
	# system we actually have. Optional either way: a miss only turns a
	# feature off. 'a | b, c' -> first alternative of each group -> 'a c'.
	extras=$(dpkg-deb -f "$DEB" Recommends 2>/dev/null || true)
	extras=$(printf '%s\n' "$extras" | tr ',' '\n' \
		| sed 's/^[[:space:]]*//; s/[[:space:]]*|.*//' | grep -v '^$' \
		| tr '\n' ' ')
	if [ -n "$extras" ]; then
		# shellcheck disable=SC2086  # extras is deliberately an unquoted list
		$SUDO "$APT" install -y $extras \
			|| say "onidia: NOTE - optional packages skipped; features above are off"
	fi
fi

say ""
say "onidia: installed. Two more things and she is awake:"
say ""
say "  1. put the shipped config where she looks for it, then add your key:"
say ""
say "       mkdir -p ~/.config/chat-app"
say "       cp -n /opt/onidia/share/chat-app.ini ~/.config/chat-app/"
say "       nano ~/.config/chat-app/chat-app.ini"
say ""
say "     The package deliberately does not write this into your home: it would"
say "     be owned by root, and you could not then edit your own key. cp -n so a"
say "     config you already have is never overwritten."
say ""
say "  2. start onidia first, then onidia-chat - they share a speech pipe"
say ""
say "  start menu:  Internet -> Onidia Chat   (Games -> Onidia for the pet)"
say "  not sure she is ready?  onidia-chat -preflight warn"
say ""