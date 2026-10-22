#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline test of the release tree mode (tools/install/release-tree.sh, docs/INSTALL.md, "From a release
# tree"), without root, a registry or a VM: tools/install/nyra-install.sh and verified-pull.sh run from
# copies of the files they read, and stand-ins for `id` (root), `uname` (the architecture) and `git`
# (which records that it ran and fails). The script stops at the first check of the machine (a TPM2),
# or earlier, and the disk is a path that is no block device, so nothing is ever written.
#   - a tree with a RELEASE and no .git runs and never runs git; a git checkout still runs as before;
#   - a RELEASE of another version, digest or architecture, not exactly its four lines, a symbolic link,
#     or beside a .git, is refused, by the installer and by the pull; the architecture is that of the
#     machine (uname) for the installer and that of the repository for the pull;
#   - the refusal of a RELEASE with another commit is the pull's, against the image's revision label:
#     tools/install/test-verified-pull.sh.
#   tools/install/test-release-tree.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
mkdir "$t/bin" "$t/gitbin"
cat > "$t/bin/id" << 'EOF2'
#!/bin/sh
echo 0
EOF2
cat > "$t/bin/uname" << 'EOF2'
#!/bin/sh
echo "$FAKE_ARCH"
EOF2
cat > "$t/bin/git" << EOF2
#!/bin/sh
echo "\$*" >> "$t/git.log"
exit 1
EOF2
chmod +x "$t/bin/"*
ln -s ../bin/id "$t/gitbin/id"
ln -s ../bin/uname "$t/gitbin/uname"

digest=sha256:$(printf 'a%.0s' $(seq 64))
other=sha256:$(printf 'b%.0s' $(seq 64))
commit=$(printf 'c%.0s' $(seq 40))
version=2026.10.7
fail() {
  echo "::error::$*" >&2
  exit 1
}

# tree NAME: a copy of what the installer reads, with no .git and no RELEASE.
tree() {
  mkdir -p "$t/$1"
  git ls-files -z tools/install files/usr/lib/nyra/containers files/usr/lib/nyra/secureboot docs/SIGNING.md \
    | tar --null -T - -cf - | tar -xf - -C "$t/$1"
}
# release NAME ARCH [DIGEST]: a release tree: RELEASE for the architecture ARCH.
release() {
  tree "$1"
  printf 'version=%s\ndigest=%s\ncommit=%s\narchitecture=%s\n' "$version" "${3:-$digest}" "$commit" "$2" > "$t/$1/RELEASE"
}

# On a machine of the architecture UNAME_ARCH: install DIR's installer; sets out and rc.
install_from() { # install_from DIR UNAME_ARCH BIN [DIGEST]
  FAKE_ARCH="$2" PATH="$t/$3:$PATH" python3 -I tools/install/pty-run.py "$t/transcript" \
    "$t/$1/tools/install/nyra-install.sh" /dev/nyra-test-no-such-disk "$version" "${4:-$digest}" && rc=0 || rc=$?
  out="$(tr -d '\r' < "$t/transcript")"
}
pull_from() { # pull_from DIR REPOSITORY [DIGEST]: the verified pull, which fails at the first check or the pull
  "$t/$1/tools/install/verified-pull.sh" "$2" "$version" "${3:-$digest}" "$t/storage" > "$t/pull.out" 2>&1 && rc=0 || rc=$?
  out="$(cat "$t/pull.out")"
}
# The last run failed, with MESSAGE in its output and, if given, that exit status (the pull: 2 = refused as
# not the release asked for, 1 = anything else; the installer: always 1).
refused() { # refused MESSAGE [STATUS]
  [ "$rc" != 0 ] || fail "accepted, but must be refused ($1)"
  grep -qF -- "$1" <<< "$out" || { printf '%s\n' "$out"; fail "refused for another reason than: $1"; }
  [ -z "${2:-}" ] || [ "$rc" = "$2" ] || fail "status $rc, not $2 ($1)"
  echo "refused as expected: $1"
}
no_git() { [ ! -e "$t/git.log" ] || fail "git ran: $(cat "$t/git.log")"; }

# --- a release tree runs without git ---------------------------------------------------------------
release amd64 amd64
install_from amd64 x86_64 bin
grep -qF "nyra-install: the release tree is $version, $digest, the commit $commit" <<< "$out" \
  || { printf '%s\n' "$out"; fail "the installer did not accept a release tree"; }
# Past the tree it stops at the machine (no TPM2, or no Secure Boot) or at the disk: never at the tree.
[ "$rc" != 0 ] && ! grep -qF RELEASE <<< "$out" || fail "the installer ended with status $rc: $out"
no_git
echo "a release tree without .git is accepted and git does not run"
release arm64 arm64
install_from arm64 aarch64 bin
grep -qF "the release tree is" <<< "$out" || fail "an arm64 release tree is not accepted on aarch64"
no_git
echo "an arm64 release tree is accepted on aarch64"

# The check of the pull itself, without the installer: the function in a shell that has die and refuse.
check_function() { # check_function DIR REPOSITORY: prints mode and commit, or the refusal
  ( die() { echo "die: $*"; exit 1; }; refuse() { echo "refuse: $*"; exit 2; }
    # shellcheck source=release-tree.sh
    . "$t/$1/tools/install/release-tree.sh"
    tree_identify "$t/$1" "$2" "$version" "$digest"
    # shellcheck disable=SC2154 # set by tree_identify
    echo "$tree_mode $tree_commit" )
}
[ "$(check_function amd64 nyra-base)" = "release $commit" ] || fail "tree_identify of a release tree"
[ "$(check_function arm64 nyra-base-arm64)" = "release $commit" ] || fail "tree_identify of an arm64 release tree"
no_git

# --- refusals, by the installer and by the pull ----------------------------------------------------
# another digest than the arguments'
release other-digest amd64 "$other"
install_from other-digest x86_64 bin
refused "RELEASE does not name the digest $digest" 1
pull_from other-digest nyra-base
refused "RELEASE does not name the digest $digest" 2
# a digest given that is not RELEASE's
install_from amd64 x86_64 bin "$other"
refused "RELEASE does not name the digest $other" 1
# the wrong architecture: the tree for the other one, by the machine (installer) and by the repository (pull)
install_from amd64 aarch64 bin
refused "RELEASE is not for arm64, the architecture of nyra-base-arm64" 1
install_from arm64 x86_64 bin
refused "RELEASE is not for amd64, the architecture of nyra-base" 1
pull_from amd64 nyra-base-arm64
refused "RELEASE is not for arm64, the architecture of nyra-base-arm64" 2
pull_from arm64 nyra-base
refused "RELEASE is not for amd64, the architecture of nyra-base" 2
# a machine no image is made for, and a repository outside the two-value allow-list
install_from amd64 riscv64 bin
refused "no Nyra image for the architecture riscv64" 1
for name in nyra-base-x86 nyra-base-arm64/x elsewhere ../nyra-base; do
  pull_from amd64 "$name"
  refused "not a Nyra image repository" 1
done
# another version
printf 'version=2026.10.8\ndigest=%s\ncommit=%s\narchitecture=amd64\n' "$digest" "$commit" > "$t/amd64/RELEASE.v"
mv "$t/amd64/RELEASE.v" "$t/amd64/RELEASE"
install_from amd64 x86_64 bin
refused "RELEASE is not for the version $version" 1
release amd64 amd64
# not exactly the four lines
bad() { # bad NAME CONTENT [MESSAGE [PULL_STATUS]]: a RELEASE that is not the four lines (2: it is not the release asked for)
  release "$1" amd64
  printf '%b' "$2" > "$t/$1/RELEASE"
  install_from "$1" x86_64 bin
  refused "${3:-RELEASE is not exactly the lines version, digest, commit and architecture}" 1
  pull_from "$1" nyra-base
  refused "${3:-RELEASE is not exactly the lines version, digest, commit and architecture}" "${4:-1}"
}
head4="version=$version\ndigest=$digest\ncommit=$commit\narchitecture=amd64"
bad extra-line "$head4\nnote=1\n"
bad no-newline "$head4"
bad reordered "digest=$digest\nversion=$version\ncommit=$commit\narchitecture=amd64\n"
bad twice "$head4\ncommit=$(printf 'd%.0s' $(seq 40))\n" "RELEASE does not hold exactly one commit"
bad short-commit "version=$version\ndigest=$digest\ncommit=abc123\narchitecture=amd64\n" "RELEASE does not hold exactly one commit"
bad upper-commit "version=$version\ndigest=$digest\ncommit=$(printf 'C%.0s' $(seq 40))\narchitecture=amd64\n" "RELEASE does not hold exactly one commit"
bad no-commit "version=$version\ndigest=$digest\narchitecture=amd64\n" "RELEASE does not hold exactly one commit"
bad empty "" "RELEASE is not for the version" 2
# a link, a directory, and a .git beside the RELEASE
release link amd64
mv "$t/link/RELEASE" "$t/link/real" && ln -s real "$t/link/RELEASE"
install_from link x86_64 bin
refused "RELEASE is not a regular file" 1
release dir amd64
rm "$t/dir/RELEASE" && mkdir "$t/dir/RELEASE"
install_from dir x86_64 bin
refused "RELEASE is not a regular file" 1
release both amd64
git init -q "$t/both"
install_from both x86_64 bin
refused "has a .git and a RELEASE" 1
pull_from both nyra-base
refused "has a .git and a RELEASE" 1
no_git

# --- the git checkout is as before -----------------------------------------------------------------
tree git
git -C "$t/git" init -q
git -C "$t/git" add -A
git -C "$t/git" -c user.name=t -c user.email=t@example.com commit -q -m tree
install_from git x86_64 gitbin
refused "nyra-install: the checkout is on a branch" 1
git -C "$t/git" checkout -q --detach
install_from git x86_64 gitbin
grep -qF "nyra-install: the checkout is at the commit $(git -C "$t/git" rev-parse HEAD)" <<< "$out" \
  || { printf '%s\n' "$out"; fail "a clean checkout at a detached commit is not accepted"; }
echo "a git checkout is accepted as before"
echo x >> "$t/git/docs/SIGNING.md"
install_from git x86_64 gitbin
refused "nyra-install: the checkout has changes" 1
git -C "$t/git" checkout -q -- docs/SIGNING.md
[ "$(check_function git nyra-base | cut -d' ' -f1)" = git ] || fail "tree_identify of a checkout"
# neither .git nor RELEASE
tree neither
install_from neither x86_64 bin
refused "cannot read the checkout's commit" 1
echo "ok"
