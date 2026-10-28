#!/usr/bin/env bash
#
# project_init.sh - Bootstrap a Snakemake pipeline project.
#
# Usage:
#   ./project_init.sh --name my-pipeline [--path ~/projects]
#
# After the first run, an alias `repo_init` is added to ~/.bashrc so you can
# invoke it from anywhere:
#   repo_init -n my-new-pipeline
#
set -euo pipefail

PROG="$(basename "$0")"
DEFAULT_REPO_NAME="my-pipeline"

# ---------- helpers ---------------------------------------------------------

usage() {
    cat <<EOF
Usage: ${PROG} [OPTIONS]

Create a new Snakemake pipeline repository scaffold with git initialized.

Options:
  -n, --name NAME       Repository name (default: ${DEFAULT_REPO_NAME})
  -p, --path DIR        Parent directory (default: current directory)
  -f, --force           Allow using an existing/empty directory
  -A, --no-alias        Do not add the 'repo_init' alias to ~/.bashrc
  -h, --help            Show this help message

Examples:
  ${PROG} --name my-pipeline
  ${PROG} -n rnaseq -p ~/projects
EOF
}

err()  { printf '[ERROR] %s\n' "$*" >&2; }
info() { printf '[INFO]  %s\n' "$*"; }

require_git() {
    command -v git >/dev/null 2>&1 || { err "git is not installed"; return 1; }
}

ensure_git_identity() {
    if ! git config --get user.email >/dev/null 2>&1; then
        err "git user.email not configured. Run: git config --global user.email 'you@example.com'"
        return 1
    fi
    if ! git config --get user.name >/dev/null 2>&1; then
        err "git user.name not configured. Run: git config --global user.name 'Your Name'"
        return 1
    fi
}

# ---------- scaffold --------------------------------------------------------

create_scaffold() {
    local root="$1"
    local name="$2"

    mkdir -p "${root}/workflow/rules" \
             "${root}/workflow/envs" \
             "${root}/workflow/scripts" \
             "${root}/workflow/report" \
             "${root}/config" \
             "${root}/results" \
             "${root}/resources" \
             "${root}/logs"

    # ---- .gitignore --------------------------------------------------------
    if [[ ! -f "${root}/.gitignore" ]]; then
        cat > "${root}/.gitignore" <<'EOF'
# generated outputs (keep the directory, ignore contents)
results/*
!results/.gitkeep
logs/*
!logs/.gitkeep

# snakemake internals
.snakemake/

# python
__pycache__/
*.pyc

# os
.DS_Store
EOF
    fi

    # ---- README.md ---------------------------------------------------------
    if [[ ! -f "${root}/README.md" ]]; then
        cat > "${root}/README.md" <<EOF
# ${name}

Snakemake pipeline project.

## Structure

\`\`\`
${name}/
├── workflow/          # Snakemake workflow
│   ├── Snakefile      # entry point (auto-discovered)
│   ├── rules/
│   ├── envs/
│   ├── scripts/
│   └── report/
├── config/
│   └── config.yaml    # main configuration
├── results/           # generated output (git-ignored)
├── resources/         # retrieved references / static assets
└── logs/              # workflow logs (git-ignored)
\`\`\`

## Usage

\`\`\`bash
snakemake --use-conda --cores all
\`\`\`
EOF
    fi

    # ---- LICENSE.md --------------------------------------------------------
    if [[ ! -f "${root}/LICENSE.md" ]]; then
        cat > "${root}/LICENSE.md" <<'EOF'
# License

TODO: add the license text for this project (e.g. MIT).
EOF
    fi

    # ---- workflow/Snakefile ------------------------------------------------
    if [[ ! -f "${root}/workflow/Snakefile" ]]; then
        cat > "${root}/workflow/Snakefile" <<'EOF'
# Snakemake entry point.
# Rules are auto-discovered from workflow/rules/*.smk

configfile: "config/config.yaml"

include: "rules/*.smk"
EOF
    fi

    # ---- config/config.yaml ------------------------------------------------
    if [[ ! -f "${root}/config/config.yaml" ]]; then
        cat > "${root}/config/config.yaml" <<'EOF'
# Main pipeline configuration
samples: "config/samples.tsv"
EOF
    fi

    # ---- keep empty dirs under git ----------------------------------------
    local d
    for d in workflow/rules workflow/envs workflow/scripts workflow/report \
             results resources logs; do
        if [[ -z "$(ls -A "${root}/${d}" 2>/dev/null || true)" ]]; then
            touch "${root}/${d}/.gitkeep"
        fi
    done
}

git_init_and_commit() {
    local root="$1"
    local name="$2"

    (
        cd "${root}"
        git init -q
        git add -A
        git commit -q -m "initialize the ${name} reporsitory"
    )
}

# ---------- alias registration ---------------------------------------------

register_alias() {
    local script_path
    # Resolve an absolute path to this script (portable fallback for macOS).
    if command -v readlink >/dev/null 2>&1 && readlink -f / >/dev/null 2>&1; then
        script_path="$(readlink -f "${BASH_SOURCE[0]}")"
    else
        script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    fi

    local rc="${HOME}/.bashrc"
    local alias_line="alias repo_init='bash \"${script_path}\"'"

    if [[ -f "${rc}" ]] && grep -q "alias repo_init=" "${rc}"; then
        info "alias 'repo_init' already present in ${rc}"
        return 0
    fi

    {
        echo ""
        echo "# Added by project_init.sh on $(date +%F)"
        echo "${alias_line}"
    } >> "${rc}"

    info "alias 'repo_init' added to ${rc} (run: source ${rc})"
}

# ---------- main ------------------------------------------------------------

main() {
    local repo_name="${DEFAULT_REPO_NAME}"
    local parent_dir="."
    local force=0
    local no_alias=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--name)    repo_name="${2:?--name requires a value}";   shift 2 ;;
            -p|--path)    parent_dir="${2:?--path requires a value}";  shift 2 ;;
            -f|--force)   force=1;                                     shift ;;
            -A|--no-alias) no_alias=1;                                 shift ;;
            -h|--help)    usage; return 0 ;;
            *)            err "unknown option: $1"; usage; return 1 ;;
        esac
    done

    [[ -n "${repo_name}" ]] || { err "repository name cannot be empty"; return 1; }

    local root="${parent_dir%/}/${repo_name}"

    if [[ -e "${root}" && "${force}" -eq 0 ]]; then
        err "path already exists: ${root} (use --force to reuse)"
        return 1
    fi

    require_git
    ensure_git_identity || return 1

    info "creating scaffold at ${root}"
    mkdir -p "${root}"
    create_scaffold "${root}" "${repo_name}"

    info "initializing git repository"
    git_init_and_commit "${root}" "${repo_name}"

    if [[ "${no_alias}" -eq 0 ]]; then
        register_alias
    fi

    info "done."
    printf '  cd %s\n' "${root}"
    printf '  snakemake --use-conda --cores all\n'
}

main "$@"
