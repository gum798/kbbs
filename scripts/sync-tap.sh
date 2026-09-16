#!/usr/bin/env bash
set -euo pipefail

dry_run=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)
      dry_run=1
      ;;
    -h|--help)
      echo "Usage: $0 [--dry-run]"
      exit 0
      ;;
    *)
      echo "Error: Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version_file="${repo_root}/VERSION"
if [[ ! -f "${version_file}" ]]; then
  echo "Error: VERSION file not found at ${version_file}" >&2
  exit 1
fi

version="$(tr -d '[:space:]' < "${version_file}")"
if [[ -z "${version}" ]]; then
  echo "Error: VERSION is empty" >&2
  exit 1
fi

tag="v${version}"
tarball_url="https://github.com/gum798/kbbs/archive/refs/tags/${tag}.tar.gz"
tap_repo="https://github.com/gum798/homebrew-kbbs.git"

if [[ -z "$(git ls-remote --tags origin "refs/tags/${tag}" 2>/dev/null)" ]]; then
  echo "Error: Remote tag '${tag}' does not exist on origin. Push the tag first." >&2
  exit 1
fi

sha256="$(curl -sSfL "${tarball_url}" | shasum -a 256 | awk '{print $1}')"
if [[ -z "${sha256}" ]]; then
  echo "Error: Failed to compute sha256 for ${tarball_url}" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

git clone --quiet --depth 1 "${tap_repo}" "${tmp_dir}"

formula_file="${tmp_dir}/Formula/kbbs.rb"
if [[ ! -f "${formula_file}" ]]; then
  echo "Error: Formula file not found: ${formula_file}" >&2
  exit 1
fi

# BSD/GNU sed portability: rewrite to a temp file then overwrite
sed -e "s|^  url \".*\"|  url \"${tarball_url}\"|" \
    -e "s|^  sha256 \".*\"|  sha256 \"${sha256}\"|" \
    "${formula_file}" > "${formula_file}.tmp"
mv "${formula_file}.tmp" "${formula_file}"

if [[ "${dry_run}" -eq 1 ]]; then
  echo "[dry-run] URL:    ${tarball_url}"
  echo "[dry-run] SHA256: ${sha256}"
  diff_output="$(git -C "${tmp_dir}" diff Formula/kbbs.rb)"
  if [[ -n "${diff_output}" ]]; then
    echo "[dry-run] Diff:"
    printf '%s\n' "${diff_output}"
  else
    echo "[dry-run] Formula/kbbs.rb is already up to date."
  fi
  exit 0
fi

if git -C "${tmp_dir}" diff --quiet Formula/kbbs.rb; then
  echo "Formula/kbbs.rb is already up to date (${tag})."
  exit 0
fi

author_name="$(git log -1 --pretty=format:'%an' 2>/dev/null || true)"
author_email="$(git log -1 --pretty=format:'%ae' 2>/dev/null || true)"
if [[ -n "${author_name}" ]]; then
  git -C "${tmp_dir}" config user.name "${author_name}"
fi
if [[ -n "${author_email}" ]]; then
  git -C "${tmp_dir}" config user.email "${author_email}"
fi

git -C "${tmp_dir}" add Formula/kbbs.rb
git -C "${tmp_dir}" commit -m "kbbs ${version}"
git -C "${tmp_dir}" push
