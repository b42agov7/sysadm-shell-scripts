#!/bin/bash

set -euo pipefail

usage() {
  cat << EOF >&2
  ${0##*/} -b <GIT branch name> [-h]

  Mandatory option and arguments:
    -b  GIT branch name to search.

  Other options:
    -h  Show this help message.
EOF
}

search_git_branch() {
  local git_branch="${1}"
  local found=0
  
  echo "Searching for branch '${git_branch}' in ~ ..." >&2

  while read -r gitdir; do
    if git --git-dir="${gitdir}" show-ref --verify --quiet "refs/heads/${git_branch}"; then
      echo "GIT branch found : $(dirname "${gitdir}")"
      found=$((found + 1))
    fi
  done < <(find ~ -type d -name ".git" 2>/dev/null)

  if [[ $found -eq 0 ]]; then
    echo "No project found with branch '${git_branch}'." >&2
  else
    echo "Search complete. Found $found match(es)." >&2
  fi
}

# Main

git_branch=""

while getopts b:h opts; do
  case ${opts} in
    b)
      git_branch="${OPTARG}"
      ;;
    h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

# Check options.

if [[ -z "${git_branch}" ]]; then
  echo "Error: Missing or invalid arguments." >&2
  usage
  exit 1
fi

search_git_branch "${git_branch}"

exit 0


