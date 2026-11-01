# Shared paths and helpers for the scripts in bin/. Sourced, not run.
set -euo pipefail

PRODUCTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# SVE_PROJECT_ROOT overrides the project root, e.g. to test the scripts on clones.
PROJECT_ROOT="${SVE_PROJECT_ROOT:-$(dirname "$PRODUCTION_DIR")}"

SVENSEMBLE_REPO="$PROJECT_ROOT/svensemble2"
PIPELINE_REPO="$PROJECT_ROOT/nf-core-svensemble"
REPOS=("$SVENSEMBLE_REPO" "$PIPELINE_REPO")
WORKTREES_DIR="$PROJECT_ROOT/worktrees"
RELEASES_DIR="$PROJECT_ROOT/releases"
MANIFESTS_DIR="$PRODUCTION_DIR/manifests"
MAIN_BRANCH=main
IMAGE_BASE=mambaorg/micromamba:2.10.0   # docker base of the apptainer images

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
# usage: print the script's header comment (everything after the shebang, up to the first non-comment line)
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 1; }

# parse_opts "$@": sets APPTAINER=1 for --apptainer, prints usage for -h/--help,
# and leaves the positional args in ARGS. Use as: parse_opts "$@"; set -- "${ARGS[@]}"
parse_opts() {
    local opts
    opts=$(getopt -o h -l apptainer,help -n "$(basename "$0")" -- "$@") || usage
    eval set -- "$opts"
    APPTAINER=
    while true; do
        case $1 in
            --apptainer) APPTAINER=1; shift ;;
            -h | --help) usage ;;
            --) shift; break ;;
        esac
    done
    ARGS=("$@")
}

MAMBA="${MAMBA_EXE:-$(command -v micromamba || true)}"
[[ -x "$MAMBA" ]] || die "micromamba not found (run 'module load micromamba')"

# resolve_commit <repo> <ref>: print the full commit hash of ref
resolve_commit() {
    git -C "$1" rev-parse --verify --quiet "$2^{commit}" || die "$(basename "$1"): unknown ref '$2'"
}

warn_if_dirty() {
    if [[ -n "$(git -C "$1" status --porcelain)" ]]; then
        echo "warning: $(basename "$1") has uncommitted changes; they are not included" >&2
    fi
}

# build_env <prefix> <environment.yml> <commit>
# Creates the env and installs svensemble from <commit> of the svensemble2 repo.
# Installing from a git archive means the env always matches a commit exactly:
# uncommitted edits never get in, and no build files land in the source tree.
build_env() {
    local prefix=$1 yml=$2 commit=$3
    [[ -f "$yml" ]] || die "no environment.yml at $yml (is it committed at ${commit:0:7}?)"
    info "building env at $prefix"
    "$MAMBA" create -y -q -p "$prefix" -f "$yml"
    cp "$yml" "$(dirname "$prefix")/environment.used.yml"
    install_svensemble "$prefix" "$commit"
}

# install_svensemble <prefix> <commit>: (re)install svensemble from a commit, non-editable
install_svensemble() {
    local prefix=$1 commit=$2 tarball
    tarball="$(mktemp -d)/svensemble2.tar.gz"
    git -C "$SVENSEMBLE_REPO" archive --format=tar.gz --prefix=svensemble2/ -o "$tarball" "$commit"
    info "installing svensemble from ${commit:0:7}"
    "$MAMBA" run -p "$prefix" pip install -q --no-deps --force-reinstall "$tarball"
    "$MAMBA" run -p "$prefix" pip check
    rm -rf "$(dirname "$tarball")"
}

# write_records <dir> <env prefix> <svensemble2 commit> <pipeline commit>
# Writes MANIFEST, env.lock and pip.lock: everything needed to rebuild <dir>.
write_records() {
    local dir=$1 prefix=$2 python
    python=$("$MAMBA" run -p "$prefix" python -c 'import platform; print(platform.python_version())')
    cat > "$dir/MANIFEST" <<EOF
name=$(basename "$dir")
written=$(date -Iseconds)
svensemble2_commit=$3
nf-core-svensemble_commit=$4
python=$python
EOF
    "$MAMBA" env export -p "$prefix" --explicit > "$dir/env.lock"
    # Only packages pip installed: conda ones are already pinned in env.lock
    "$MAMBA" run -p "$prefix" python -c '
from importlib.metadata import distributions
for d in sorted(distributions(), key=lambda d: d.metadata["Name"].lower()):
    if (d.read_text("INSTALLER") or "").strip() == "pip":
        print(d.metadata["Name"] + "==" + d.version)' > "$dir/pip.lock"
}

# write_image_def <file> <svensemble2 commit>: apptainer recipe that rebuilds the env in /opt/env.
# Build context: the def, env.lock, and svensemble2.tar.gz (git archive of the commit).
write_image_def() {
    cat > "$1" <<EOF
Bootstrap: docker
From: $IMAGE_BASE

%labels
    svensemble2_commit $2

%files
    env.lock /opt/env.lock
    svensemble2.tar.gz /opt/svensemble2.tar.gz

%post
    export MAMBA_ROOT_PREFIX=/opt/conda
    # procps: Nextflow needs ps inside the container to record task metrics
    apt-get update -qq && apt-get install -y -qq --no-install-recommends procps > /dev/null
    rm -rf /var/lib/apt/lists/*
    micromamba create -y -q -p /opt/env -f /opt/env.lock
    /opt/env/bin/pip install -q --no-deps /opt/svensemble2.tar.gz
    /opt/env/bin/pip check
    micromamba clean -a -y -q
    rm /opt/svensemble2.tar.gz

%environment
    export PATH=/opt/env/bin:\$PATH
EOF
}

# build_image <group dir> <svensemble2 commit>: apptainer image of the group's env. Run write_records first.
# The name hashes the recipe and env.lock, and carries the commit. Nextflow's task
# hash includes the container name, so a changed image reruns svensemble tasks under
# -resume, and an unchanged one is not rebuilt. Older images of the group are deleted.
build_image() {
    local dir=$1 commit=$2 sum sif ctx old
    command -v apptainer > /dev/null || die "apptainer not found (run 'module load apptainer')"
    write_image_def "$dir/svensemble.def" "$commit"
    sum=$(cat "$dir/svensemble.def" "$dir/env.lock" | sha256sum | cut -c1-8)
    sif="$dir/svensemble-${commit:0:7}-$sum.sif"
    if [[ -f "$sif" ]]; then
        info "image up to date: $(basename "$sif")"
    else
        ctx=$(mktemp -d)
        cp "$dir/svensemble.def" "$dir/env.lock" "$ctx/"
        git -C "$SVENSEMBLE_REPO" archive --format=tar.gz --prefix=svensemble2/ -o "$ctx/svensemble2.tar.gz" "$commit"
        info "building image $(basename "$sif")"
        (cd "$ctx" && apptainer build svensemble.sif svensemble.def)
        mv "$ctx/svensemble.sif" "$sif"
        rm -rf "$ctx"
    fi
    for old in "$dir"/svensemble-*.sif; do
        [[ "$old" == "$sif" ]] || rm -f "$old"
    done
    echo "image=$(basename "$sif")" >> "$dir/MANIFEST"
}

# current_image <group dir>: print the group's image, if it has one
current_image() {
    local sif
    for sif in "$1"/svensemble-*.sif; do
        [[ -f "$sif" ]] && echo "$sif"
    done
    return 0
}

# write_nf_config <file> <env prefix> [image]: config that points the pipeline's svensemble tasks at the env
# Setting the param alone is not enough: conf/modules.config builds the svensemble
# beforeScript string from params.svensemble_conda while the pipeline's own config
# is parsed, before -c files are read, so the activation line keeps the old env.
# The beforeScript is therefore overridden here as well.
# With an image, the tasks run in it instead, and the beforeScript is emptied: it
# runs on the host, and an activated host env would leak into the container.
write_nf_config() {
    local task
    if [[ -n "${3:-}" ]]; then
        task="container = '$3'
        beforeScript = ''"
    else
        task="beforeScript = 'module load micromamba && eval \"\$(micromamba shell hook -s bash)\" && micromamba activate $2'"
    fi
    cat > "$1" <<EOF
// Generated by production/bin. Pass with -c so svensemble tasks use this env.
params.svensemble_conda = '$2'

process {
    withName: 'SVENSEMBLE_.*' {
        $task
    }
}
EOF
}

# print_run_hint <group dir> <config name>: how to launch, and the one flag that must not be forgotten
print_run_hint() {
    local sif
    sif=$(current_image "$1")
    echo
    echo "IMPORTANT: the pipeline only uses this env if you pass $1/$2 with -c."
    echo "Without it, svensemble tasks run in the env set in the pipeline's nextflow.config"
    echo "(params.svensemble_conda), which is not this one."
    if [[ -n "$sif" ]]; then
        echo "svensemble tasks run in $(basename "$sif"), which needs -profile apptainer."
    fi
    echo "Launch from a separate directory:"
    echo "  nextflow run $1/nf-core-svensemble -c $1/$2 ..."
}
