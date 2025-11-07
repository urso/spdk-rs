#!/usr/bin/env bash

# sync-upstream.sh - Automated upstream sync script for xataio forks
#
# This script syncs changes from upstream OpenEBS repositories into xataio forks.
# It automatically detects remotes, maps branches, and handles merge operations.
#
# Exit Codes:
#   0 - Clean merge, changes applied successfully
#   1 - Merge conflicts detected
#   2 - No changes to merge (already up-to-date)
#   3 - Upstream branch doesn't exist
#   4 - Not in a git repo / xataio remote not found
#   5 - Upstream remote configuration failed
#   6 - Non-fast-forward (upstream force-pushed)

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
UPSTREAM_ORG="openebs"
XATA_ORG="xataio"
DEFAULT_UPSTREAM_REMOTE_NAME="upstream"

# Script options
DRY_RUN=false
UPSTREAM_BRANCH=""
TARGET_BRANCH=""
VERBOSE=false
XATA_REMOTE=""
UPSTREAM_REMOTE=""

# Detected values
DETECTED_XATA_REMOTE=""
DETECTED_UPSTREAM_REMOTE=""
REPO_NAME=""

# Utility functions
log() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

success() {
  echo -e "${GREEN}[SUCCESS]${NC} $*"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

die() {
  local exit_code="${2:-1}"
  error "$1"
  exit "$exit_code"
}

# Extract org name from git URL
get_org_from_url() {
  local git_url="$1"
  if echo "$git_url" | grep -q "^git@github.com:"; then
    # git@github.com:xataio/repo.git => xataio
    echo "$git_url" | sed -E 's|^git@github\.com:([^/]+)/.*|\1|'
  elif echo "$git_url" | grep -q "^https://github.com/"; then
    # https://github.com/xataio/repo.git => xataio
    echo "$git_url" | sed -E 's|^https://github\.com/([^/]+)/.*|\1|'
  else
    echo ""
  fi
}

# Extract repo name from git URL
get_repo_from_url() {
  local git_url="$1"
  local repo=""

  if echo "$git_url" | grep -q "^git@github.com:"; then
    # git@github.com:xataio/mayastor-dependencies.git => mayastor-dependencies
    repo=$(echo "$git_url" | sed -E 's|^git@github\.com:[^/]+/(.+)$|\1|')
  elif echo "$git_url" | grep -q "^https://github.com/"; then
    # https://github.com/xataio/mayastor-dependencies.git => mayastor-dependencies
    repo=$(echo "$git_url" | sed -E 's|^https://github\.com/[^/]+/(.+)$|\1|')
  else
    echo ""
    return
  fi

  # Remove .git suffix if present
  echo "$repo" | sed 's/\.git$//'
}

# Find remote by organization
# Args: org_name, preferred_names...
# Returns: remote name via stdout (empty if not found)
find_remote_by_org() {
  local target_org="$1"
  shift
  local preferred_names=("$@")

  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    return 1
  fi

  # Get all remotes and their URLs
  local remotes
  remotes=$(git remote -v | grep '(fetch)' | awk '{print $1}')

  local found_remotes=()

  # Find all remotes pointing to the target org
  for remote in $remotes; do
    local url
    url=$(git config --get remote."$remote".url || true)
    if [ -n "$url" ]; then
      local org
      org=$(get_org_from_url "$url")
      if [ "$org" = "$target_org" ]; then
        found_remotes+=("$remote")
      fi
    fi
  done

  # If none found, return empty
  if [ ${#found_remotes[@]} -eq 0 ]; then
    return 1
  fi

  # If only one found, return it
  if [ ${#found_remotes[@]} -eq 1 ]; then
    echo "${found_remotes[0]}"
    return 0
  fi

  # Multiple found - use preference order
  for preferred in "${preferred_names[@]}"; do
    for found in "${found_remotes[@]}"; do
      if [ "$found" = "$preferred" ]; then
        echo "$found"
        return 0
      fi
    done
  done

  # No preferred name matched, return first found
  echo "${found_remotes[0]}"
  return 0
}

# Generic remote detection and verification
# Args: org_name, user_specified_remote, preferred_names...
# Returns: remote name via stdout, exits on error if user-specified is invalid
find_or_verify_remote() {
  local org="$1"
  local user_specified="$2"
  shift 2
  local preferred_names=("$@")

  if [ -n "$user_specified" ]; then
    # User specified - verify it exists and points to correct org
    local url
    url=$(git config --get remote."$user_specified".url 2>/dev/null || true)
    if [ -z "$url" ]; then
      die "Specified remote '$user_specified' does not exist" 4
    fi

    local remote_org
    remote_org=$(get_org_from_url "$url")
    if [ "$remote_org" != "$org" ]; then
      die "Specified remote '$user_specified' does not point to $org (found: $remote_org)" 4
    fi

    echo "$user_specified"
    return 0
  else
    # Auto-detect with preferred names
    local detected
    detected=$(find_remote_by_org "$org" "${preferred_names[@]}" || true)
    echo "$detected"
    return 0
  fi
}

# Detect xataio remote
detect_xata_remote() {
  DETECTED_XATA_REMOTE=$(find_or_verify_remote "$XATA_ORG" "$XATA_REMOTE" "origin" "xata" "xataio")

  if [ -z "$DETECTED_XATA_REMOTE" ]; then
    die "No remote found pointing to github.com/$XATA_ORG/. Please specify with --xata-remote" 4
  fi

  if [ -n "$XATA_REMOTE" ]; then
    log "Using specified xata remote: $DETECTED_XATA_REMOTE"
  else
    log "Auto-detected xata remote: $DETECTED_XATA_REMOTE"
  fi

  # Extract repo name from xata remote
  local url
  url=$(git config --get remote."$DETECTED_XATA_REMOTE".url)
  REPO_NAME=$(get_repo_from_url "$url")

  if [ -z "$REPO_NAME" ]; then
    die "Could not extract repository name from remote URL: $url" 4
  fi

  success "Working with repository: $XATA_ORG/$REPO_NAME"
}

# Detect or configure upstream remote
detect_upstream_remote() {
  local detected
  detected=$(find_or_verify_remote "$UPSTREAM_ORG" "$UPSTREAM_REMOTE" "upstream" "openebs")

  if [ -n "$detected" ]; then
    # Found a remote - verify it points to the same repo
    local url
    url=$(git config --get remote."$detected".url)
    local remote_repo
    remote_repo=$(get_repo_from_url "$url")

    if [ "$remote_repo" = "$REPO_NAME" ]; then
      DETECTED_UPSTREAM_REMOTE="$detected"

      if [ -n "$UPSTREAM_REMOTE" ]; then
        log "Using specified upstream remote: $DETECTED_UPSTREAM_REMOTE"
      else
        log "Auto-detected upstream remote: $DETECTED_UPSTREAM_REMOTE"
      fi

      local upstream_url
      upstream_url=$(git config --get remote."$DETECTED_UPSTREAM_REMOTE".url)
      success "Upstream remote configured: $DETECTED_UPSTREAM_REMOTE -> $upstream_url"
      return
    else
      warn "Found upstream remote '$detected' points to different repo: $remote_repo (expected: $REPO_NAME)"
      warn "Will add new remote for $UPSTREAM_ORG/$REPO_NAME"
    fi
  fi

  # Not found or points to wrong repo - add it
  add_upstream_remote
}

# Add upstream remote
add_upstream_remote() {
  local upstream_url="https://github.com/${UPSTREAM_ORG}/${REPO_NAME}.git"
  local remote_name="$DEFAULT_UPSTREAM_REMOTE_NAME"

  # Find an available name if default is taken
  local counter=2
  while git config --get remote."$remote_name".url &>/dev/null; do
    remote_name="${DEFAULT_UPSTREAM_REMOTE_NAME}${counter}"
    ((counter++))
  done

  log "Adding upstream remote '$remote_name': $upstream_url"

  # Always add the remote (even in dry-run) - it's needed for fetching and is harmless
  git remote add "$remote_name" "$upstream_url" || die "Failed to add upstream remote" 5

  # Security: Disable push to upstream to prevent accidental pushes
  log "Disabling push to upstream remote (security measure)"
  git remote set-url --push "$remote_name" no_push || warn "Could not disable push for upstream remote"

  DETECTED_UPSTREAM_REMOTE="$remote_name"
  success "Added upstream remote: $remote_name -> $upstream_url (push disabled)"
}

# Map local branch to upstream branch
# Examples:
#   develop -> develop
#   develop-prepare -> develop
#   develop-fix -> develop
#   release/2.9 -> release/2.9
#   release/2.9-fix -> release/2.9
map_branch() {
  local local_branch="$1"

  # If explicitly provided, use that
  if [ -n "$UPSTREAM_BRANCH" ]; then
    echo "$UPSTREAM_BRANCH"
    return
  fi

  # develop variants -> develop
  if [[ "$local_branch" =~ ^develop(-.*)?$ ]]; then
    echo "develop"
    return
  fi

  # release/X.Y-suffix -> release/X.Y
  if [[ "$local_branch" =~ ^release/([0-9]+\.[0-9]+)(-.+)?$ ]]; then
    echo "release/${BASH_REMATCH[1]}"
    return
  fi

  # Default: use as-is
  echo "$local_branch"
}

# Fetch from upstream
fetch_upstream() {
  local upstream_branch="$1"

  log "Fetching from $DETECTED_UPSTREAM_REMOTE/$upstream_branch..."

  # Always fetch (even in dry-run) - it's read-only and needed for preview
  if ! git fetch "$DETECTED_UPSTREAM_REMOTE" "$upstream_branch" 2>&1; then
    die "Failed to fetch from upstream" 5
  fi

  success "Fetched from $DETECTED_UPSTREAM_REMOTE/$upstream_branch"
}

# Check if upstream branch exists
check_upstream_branch() {
  local upstream_branch="$1"

  if ! git rev-parse --verify "$DETECTED_UPSTREAM_REMOTE/$upstream_branch" &>/dev/null; then
    die "Upstream branch does not exist: $DETECTED_UPSTREAM_REMOTE/$upstream_branch" 3
  fi
}

# Check for divergence
check_divergence() {
  local upstream_branch="$1"
  local merge_target="$DETECTED_UPSTREAM_REMOTE/$upstream_branch"

  local ahead behind
  ahead=$(git rev-list --count HEAD.."$merge_target" 2>/dev/null || echo "0")
  behind=$(git rev-list --count "$merge_target"..HEAD 2>/dev/null || echo "0")

  # If no new commits from upstream, we're up-to-date
  if [ "$ahead" -eq 0 ]; then
    log "Already up-to-date with upstream (no new commits to pull)"
    if [ "$behind" -gt 0 ]; then
      log "Note: You have $behind local commit(s) that are not in upstream"
    fi
    exit 2
  fi

  # Report divergence status
  if [ "$behind" -gt 0 ]; then
    warn "Local branch has $behind commit(s) not in upstream (diverged)"
  fi

  log "Upstream has $ahead new commit(s) to sync"
}

# Attempt merge
merge_upstream() {
  local upstream_branch="$1"
  local merge_target="$DETECTED_UPSTREAM_REMOTE/$upstream_branch"

  log "Attempting to merge $merge_target..."

  if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Would execute: git merge --no-ff $merge_target"
    log ""
    log "[DRY RUN] Preview of incoming changes from upstream:"
    echo "----------------------------------------"
    log "New commits from upstream:"
    git log --oneline --no-decorate HEAD.."$merge_target" 2>/dev/null || true
    echo ""
    log "Changes from upstream (since divergence):"
    # Use three-dot syntax to show changes on upstream side only
    git diff --stat HEAD..."$merge_target" 2>/dev/null || true
    echo ""
    log "Note: Your local-only files will be preserved during merge"
    echo "----------------------------------------"
    return 0
  fi

  # Check if merge would be non-fast-forward (force-push scenario)
  if ! git merge-base --is-ancestor "$merge_target" HEAD 2>/dev/null; then
    if ! git merge-base --is-ancestor HEAD "$merge_target" 2>/dev/null; then
      # Neither is ancestor of the other - check for common history
      local base
      base=$(git merge-base HEAD "$merge_target" 2>/dev/null || echo "")

      if [ -z "$base" ]; then
        # No common ancestor - likely force push
        die "Upstream appears to have been force-pushed (no common history). Manual intervention required." 6
      fi

      # We have a common ancestor, so this is normal divergence
      log "Branches have diverged, will create merge commit"
    fi
  fi

  # Attempt the merge with conventional commit message
  if git merge --no-ff -m "chore: sync upstream changes" "$merge_target" 2>&1; then
    success "Successfully merged $merge_target"

    # Show summary
    log "Changes summary:"
    git diff --stat HEAD~1 2>/dev/null || true

    return 0
  else
    # Merge failed - check if it's due to conflicts
    if git status | grep -q "Unmerged paths\|Merge conflict"; then
      error "Merge conflicts detected"

      # Show conflicted files
      log "Conflicted files:"
      git diff --name-only --diff-filter=U 2>/dev/null || true

      # Check for submodule conflicts
      if git diff --name-only --diff-filter=U 2>/dev/null | grep -q "^[^/]*$"; then
        warn "Detected potential submodule conflicts"
      fi

      # Abort the merge to leave repo in clean state
      git merge --abort 2>/dev/null || true

      return 1
    else
      # Some other error
      git merge --abort 2>/dev/null || true
      die "Merge failed with unknown error" 5
    fi
  fi
}

# Display help
show_help() {
  cat <<EOF
Usage: $0 [OPTIONS]

Sync changes from upstream OpenEBS repository into xataio fork.

This script automatically detects your git remotes and syncs changes from the
upstream OpenEBS repository. It handles multiple remote configurations and can
be used in environments where developers have custom remote names.

OPTIONS:
  --dry-run                      Preview changes without applying
  --upstream-branch <branch>     Override auto-detected upstream branch
  --target-branch <branch>       Branch name to use for mapping (default: current branch)
                                 Note: Merge always happens into current branch
  --xata-remote <name>           Specify xataio remote name (auto-detected if not provided)
  --upstream-remote <name>       Specify upstream remote name (auto-detected/added if not provided)
  --verbose                      Show detailed output
  -h, --help                     Display this help message

EXIT CODES:
  0 - Clean merge, changes applied successfully
  1 - Merge conflicts detected
  2 - No changes to merge (already up-to-date)
  3 - Upstream branch doesn't exist
  4 - Not in a git repo / xataio remote not found
  5 - Upstream remote configuration failed
  6 - Non-fast-forward (upstream force-pushed)

REMOTE DETECTION:
  The script searches all git remotes to find:
  - Xataio remote: Any remote pointing to github.com/xataio/<repo>
    Priority: origin > xata > xataio > first found
  - Upstream remote: Any remote pointing to github.com/openebs/<repo>
    Priority: upstream > openebs > first found

  If upstream remote is not found, it will be added automatically.

BRANCH MAPPING:
  Local Branch        → Upstream Branch
  develop             → upstream/develop
  develop-*           → upstream/develop
  release/2.9         → upstream/release/2.9
  release/2.9-*       → upstream/release/2.9

EXAMPLES:
  # Sync current branch with auto-detected upstream branch
  git checkout develop-prepare
  $0

  # Preview sync without applying changes
  $0 --dry-run

  # Sync from workflow (merge into current branch, use develop-prepare for mapping)
  git checkout -b sync-upstream/develop-prepare-123456
  $0 --target-branch develop-prepare

  # Override upstream branch mapping
  git checkout develop-fix
  $0 --upstream-branch develop

  # Specify custom remote names
  $0 --xata-remote origin --upstream-remote openebs-upstream

EOF
}

# Parse command-line arguments
parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --upstream-branch)
        test $# -lt 2 && die "Missing value for: $1"
        UPSTREAM_BRANCH="$2"
        shift 2
        ;;
      --target-branch)
        test $# -lt 2 && die "Missing value for: $1"
        TARGET_BRANCH="$2"
        shift 2
        ;;
      --xata-remote)
        test $# -lt 2 && die "Missing value for: $1"
        XATA_REMOTE="$2"
        shift 2
        ;;
      --upstream-remote)
        test $# -lt 2 && die "Missing value for: $1"
        UPSTREAM_REMOTE="$2"
        shift 2
        ;;
      --verbose)
        VERBOSE=true
        set -x
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        die "Unknown option: $1 (use --help for usage)"
        ;;
    esac
  done
}

# Main execution
main() {
  parse_args "$@"

  if [ "$DRY_RUN" = true ]; then
    warn "DRY RUN MODE - No changes will be applied"
    echo ""
  fi

  # Verify we're in a git repository
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    die "Not inside a git repository" 4
  fi

  # Detect xataio remote and extract repo name
  detect_xata_remote

  # Detect or configure upstream remote
  detect_upstream_remote

  echo ""

  # Determine target branch (for mapping only - never checkout)
  if [ -z "$TARGET_BRANCH" ]; then
    TARGET_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    log "Syncing current branch: $TARGET_BRANCH"
  else
    log "Using branch name for mapping: $TARGET_BRANCH"
    log "Merging into current branch: $(git rev-parse --abbrev-ref HEAD)"
  fi

  # Map to upstream branch
  local upstream_branch
  upstream_branch=$(map_branch "$TARGET_BRANCH")
  log "Branch mapping: $TARGET_BRANCH → $DETECTED_UPSTREAM_REMOTE/$upstream_branch"

  echo ""

  # Fetch from upstream
  fetch_upstream "$upstream_branch"

  # Check if upstream branch exists
  check_upstream_branch "$upstream_branch"

  # Check for divergence
  check_divergence "$upstream_branch"

  echo ""

  # Attempt merge
  if merge_upstream "$upstream_branch"; then
    echo ""
    success "Sync completed successfully!"
    exit 0
  else
    echo ""
    error "Sync failed due to merge conflicts"
    exit 1
  fi
}

# Run main function
main "$@"
