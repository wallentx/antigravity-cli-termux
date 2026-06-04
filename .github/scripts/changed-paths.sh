#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -z "${GITHUB_OUTPUT:-}" ]]; then
  echo "GITHUB_OUTPUT is required." >&2
  exit 1
fi

base_ref="${1:-${PR_BASE_SHA:-}}"
head_ref="${2:-${PR_HEAD_SHA:-HEAD}}"

if [[ -n "${CHANGED_PATHS_FILE:-}" ]]; then
  mapfile -t changed_paths <"$CHANGED_PATHS_FILE"
else
  if [[ -z "$base_ref" ]]; then
    echo "A base ref or PR_BASE_SHA is required." >&2
    exit 1
  fi

  mapfile -t changed_paths < <(git diff --name-only "$base_ref" "$head_ref" --)
fi

pr_validation=false
shellcheck=false
actionlint=false
shellcheck_files=()

is_ci_exempt_path() {
  case "$1" in
    CHANGELOG.md | docs/* | examples/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_shellcheck_path() {
  case "$1" in
    *.sh | .github/scripts/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

for path in "${changed_paths[@]}"; do
  [[ -n "$path" ]] || continue

  if ! is_ci_exempt_path "$path"; then
    pr_validation=true
  fi

  if is_shellcheck_path "$path" && [[ "$path" != examples/* && -f "$path" ]]; then
    shellcheck=true
    shellcheck_files+=("$path")
  fi

  if [[ "$path" == .github/workflows/* ]]; then
    actionlint=true
  fi
done

{
  printf 'pr_validation=%s\n' "$pr_validation"
  printf 'shellcheck=%s\n' "$shellcheck"
  printf 'actionlint=%s\n' "$actionlint"
  printf 'shellcheck_files<<__SHELLCHECK_FILES__\n'
  if ((${#shellcheck_files[@]} > 0)); then
    printf '%s\n' "${shellcheck_files[@]}"
  fi
  printf '__SHELLCHECK_FILES__\n'
} >>"$GITHUB_OUTPUT"

printf 'Changed paths:\n'
printf '  %s\n' "${changed_paths[@]:-}"
printf 'Path policy:\n'
printf '  pr_validation=%s\n' "$pr_validation"
printf '  shellcheck=%s\n' "$shellcheck"
printf '  actionlint=%s\n' "$actionlint"
