#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${ROOT_DIR}/sync/config/upstream.yaml"
DEFAULT_PROJECTS=(rtmessage rtconnect rtconsole)
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  bash init_references.sh [--dry-run] [all|rtmessage|rtconnect|rtconsole ...]

Examples:
  bash init_references.sh
  bash init_references.sh --dry-run
  bash init_references.sh rtconsole rtconnect
EOF
}

log() {
  printf '[init] %s\n' "$*"
}

fail() {
  printf '[init][error] %s\n' "$*" >&2
  exit 1
}

strip_quotes() {
  local value="$1"
  value="${value#\"}"
  value="${value%\"}"
  printf '%s' "$value"
}

get_project_value() {
  local project="$1"
  local key="$2"

  awk -v project="$project" -v key="$key" '
    $0 ~ "^  " project ":$" {
      in_project = 1
      next
    }
    in_project && $0 ~ "^  [A-Za-z0-9_-]+:$" {
      exit
    }
    in_project && $0 ~ "^    " key ":" {
      sub("^    " key ": *", "", $0)
      print $0
      exit
    }
  ' "$CONFIG_FILE"
}

run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

ensure_config() {
  [[ -f "$CONFIG_FILE" ]] || fail "missing config file: $CONFIG_FILE"
}

ensure_git() {
  command -v git >/dev/null 2>&1 || fail "git is required but was not found in PATH"
}

normalize_projects() {
  if [[ "$#" -eq 0 ]]; then
    printf '%s\n' "${DEFAULT_PROJECTS[@]}"
    return 0
  fi

  if [[ "$1" == "all" ]]; then
    printf '%s\n' "${DEFAULT_PROJECTS[@]}"
    return 0
  fi

  printf '%s\n' "$@"
}

ensure_reference_root() {
  local ref_root="${ROOT_DIR}/Redpanda-data"

  if [[ -d "$ref_root" ]]; then
    log "reference directory already exists: Redpanda-data"
    return 0
  fi

  log "creating reference directory: Redpanda-data"
  run_cmd mkdir -p "$ref_root"
}

clone_project() {
  local project="$1"
  local repo branch rel_path target_path

  repo="$(strip_quotes "$(get_project_value "$project" upstream_repo)")"
  branch="$(strip_quotes "$(get_project_value "$project" upstream_branch)")"
  rel_path="$(strip_quotes "$(get_project_value "$project" local_ref_path)")"

  [[ -n "$repo" ]] || fail "missing upstream_repo for project: $project"
  [[ -n "$branch" ]] || fail "missing upstream_branch for project: $project"
  [[ -n "$rel_path" ]] || fail "missing local_ref_path for project: $project"

  target_path="${ROOT_DIR}/${rel_path}"

  if [[ -d "$target_path/.git" ]]; then
    log "skip existing git repository: ${rel_path}"
    return 0
  fi

  if [[ -e "$target_path" ]]; then
    fail "target path exists but is not a git repository: ${rel_path}"
  fi

  log "cloning ${project} from ${repo} (${branch}) -> ${rel_path}"
  run_cmd git clone --branch "$branch" --single-branch "$repo" "$target_path"
}

main() {
  local args=()
  local project

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        args+=("$1")
        ;;
    esac
    shift
  done

  ensure_config
  ensure_git
  ensure_reference_root

  while IFS= read -r project; do
    case "$project" in
      rtmessage|rtconnect|rtconsole)
        clone_project "$project"
        ;;
      *)
        fail "unsupported project: $project"
        ;;
    esac
  done < <(normalize_projects "${args[@]}")

  log "initialization complete"
}

main "$@"