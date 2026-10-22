#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck disable=SC2034,SC2154 # tree_*: read by the script that sources this; die, refuse: defined there
# Sourced by verified-pull.sh and nyra-install.sh: what tree they run from, and its commit.
#
# Two kinds of tree, never both:
#   git      a clone of the repository, with a .git, at the release commit. The commit is `git rev-parse HEAD`.
#   release  the files of one release without any git (the installer ISO), with a file RELEASE at its root
#            in place of the .git. The commit is the one RELEASE names. The script reads the policy, the
#            trust roots and the certificate from this tree only, so for the ISO they are the ISO's.
#
# RELEASE is exactly these four lines (nothing else, no other order) and it must agree with what the
# caller was given, which is what the person installing took from the release run on github.com:
#   version=2026.10.7
#   digest=sha256:<64 hexadecimal characters>
#   commit=<40 hexadecimal characters>
#   architecture=amd64             (amd64 for nyra-base, arm64 for nyra-base-arm64)
# A RELEASE with another version, digest or architecture is refused here. Its commit is compared by the
# caller with the revision label of the pulled image, exactly as the commit of a clone is.
#
# tree_identify ROOT REPOSITORY VERSION DIGEST: sets tree_mode (git or release) and tree_commit.
# The caller defines die (exit 1) and refuse (the tree is not the release it was asked to install).
tree_identify() {
  local root="$1" name="$2" version="$3" digest="$4" arch commit
  # The same two-value allow-list as everywhere else (docs/ARM64.md, "Releases").
  case "$name" in
    nyra-base) arch=amd64 ;;
    nyra-base-arm64) arch=arm64 ;;
    *) die "not a Nyra image repository (nyra-base, nyra-base-arm64): $name" ;;
  esac
  if [ -e "$root/RELEASE" ] || [ -L "$root/RELEASE" ]; then
    if [ -e "$root/.git" ] || [ -L "$root/.git" ]; then
      die "$root has a .git and a RELEASE: it is a git checkout or a release tree, not both"
    fi
    [ -f "$root/RELEASE" ] && [ ! -L "$root/RELEASE" ] || die "RELEASE is not a regular file"
    grep -qxF -- "version=$version" "$root/RELEASE" || refuse "RELEASE is not for the version $version"
    grep -qxF -- "digest=$digest" "$root/RELEASE" || refuse "RELEASE does not name the digest $digest"
    grep -qxF -- "architecture=$arch" "$root/RELEASE" || refuse "RELEASE is not for $arch, the architecture of $name"
    commit="$(sed -n 's/^commit=\([0-9a-f]\{40\}\)$/\1/p' "$root/RELEASE")" || die "cannot read RELEASE"
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "RELEASE does not hold exactly one commit (40 hexadecimal characters)"
    printf 'version=%s\ndigest=%s\ncommit=%s\narchitecture=%s\n' "$version" "$digest" "$commit" "$arch" \
      | cmp -s - "$root/RELEASE" || die "RELEASE is not exactly the lines version, digest, commit and architecture"
    tree_mode=release
    tree_commit="$commit"
  else
    # --git-dir: git refuses to read a checkout owned by another user (sudo), unless told which one.
    tree_mode=git
    tree_commit="$(git --git-dir="$root/.git" rev-parse HEAD)" || die "cannot read the checkout's commit"
  fi
}
