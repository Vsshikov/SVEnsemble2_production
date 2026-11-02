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
PUB_REPO="$PROJECT_ROOT/svensemble2_pub"            # svensemble_analyse, installed editable in env-analysis/
ANALYSIS_EXTRAS="$PRODUCTION_DIR/specs/analysis.yml" # plotting and notebook packages added for env-analysis/

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
# usage: print the script's header comment (everything after the shebang, up to the first non-comment line)
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 1; }

# parse_opts "$@": sets APPTAINER=1 for --apptainer, ANALYSIS=1 for --analysis, prints
# usage for -h/--help, and leaves the positional args in ARGS. Use as: parse_opts "$@"; set -- "${ARGS[@]}"
parse_opts() {
    local opts
    opts=$(getopt -o h -l apptainer,analysis,help -n "$(basename "$0")" -- "$@") || usage
    eval set -- "$opts"
    APPTAINER=
    ANALYSIS=
    while true; do
        case $1 in
            --apptainer) APPTAINER=1; shift ;;
            --analysis) ANALYSIS=1; shift ;;
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

# analysis_spec <environment.yml>: the record of what env-analysis/ is built from
# (the core spec, then the analysis extras), compared on refresh to spot changes
analysis_spec() {
    cat "$1"
    echo "---"
    cat "$ANALYSIS_EXTRAS"
}

# build_analysis_env <group dir> <environment.yml> <commit>
# Creates <group>/env-analysis/: the core spec plus specs/analysis.yml, svensemble from
# <commit> as in env/, and svensemble_analyse editable from svensemble2_pub.
# It is separate from env/: the pipeline, its config and its image never use it.
build_analysis_env() {
    local dir=$1 yml=$2 commit=$3 prefix="$1/env-analysis"
    [[ -f "$yml" ]] || die "no environment.yml at $yml"
    [[ -f "$ANALYSIS_EXTRAS" ]] || die "no analysis spec at $ANALYSIS_EXTRAS"
    [[ -f "$PUB_REPO/pyproject.toml" ]] || die "no svensemble_analyse package at $PUB_REPO"
    info "building analysis env at $prefix"
    "$MAMBA" create -y -q -p "$prefix" -f "$yml" -f "$ANALYSIS_EXTRAS"
    analysis_spec "$yml" > "$dir/analysis.used.yml"
    install_svensemble "$prefix" "$commit"
    install_analyse "$prefix"
    "$MAMBA" env export -p "$prefix" --explicit > "$dir/env-analysis.lock"
}

# install_analyse <prefix>: svensemble_analyse editable from svensemble2_pub, so its edits apply at once
install_analyse() {
    info "installing svensemble_analyse (editable) from $PUB_REPO"
    "$MAMBA" run -p "$1" pip install -q --no-deps -e "$PUB_REPO"
    "$MAMBA" run -p "$1" pip check
}

# refresh_analysis_env <group dir> <environment.yml> <commit>: rebuild env-analysis/ if its
# spec changed or it is missing, else only reinstall svensemble from <commit>
refresh_analysis_env() {
    local dir=$1 yml=$2 commit=$3
    if [[ -d "$dir/env-analysis" ]] && cmp -s <(analysis_spec "$yml") "$dir/analysis.used.yml"; then
        install_svensemble "$dir/env-analysis" "$commit"
        "$MAMBA" env export -p "$dir/env-analysis" --explicit > "$dir/env-analysis.lock"
    else
        info "analysis env missing or its spec changed: rebuilding it"
        rm -rf "$dir/env-analysis"
        build_analysis_env "$dir" "$yml" "$commit"
    fi
}

# print_kernel_hint <group dir>: how to make env-analysis/ a Jupyter kernel (not done automatically)
print_kernel_hint() {
    echo "analysis env: $1/env-analysis (svensemble_analyse editable from $PUB_REPO)"
    echo "to use it as a Jupyter kernel:"
    echo "  $MAMBA run -p $1/env-analysis python -m ipykernel install --user --name $(basename "$1")-analysis"
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

# same_package <commit> <commit>: true if both commits hold the same svensemble/ tree and pyproject.toml,
# i.e. install the same package
same_package() {
    [[ "$(git -C "$SVENSEMBLE_REPO" rev-parse "$1:svensemble" "$1:pyproject.toml")" == \
       "$(git -C "$SVENSEMBLE_REPO" rev-parse "$2:svensemble" "$2:pyproject.toml")" ]]
}

# image_name <group dir> <svensemble2 commit>: file name of the image for <commit>'s svensemble
# package and the group's env.lock (run write_records first). It holds the hash of the svensemble/
# tree, and a hash of the recipe without its commit label, pyproject.toml and env.lock. A commit
# that changes nothing the image installs (tests, docs, other files) keeps the name. Nextflow's
# task hash includes the container name, so only a real change reruns svensemble tasks.
image_name() {
    local dir=$1 commit=$2 tree sum def
    tree=$(git -C "$SVENSEMBLE_REPO" rev-parse "$commit:svensemble")
    def=$(mktemp)
    write_image_def "$def" "$commit"
    sum=$( { grep -v 'svensemble2_commit' "$def"
             git -C "$SVENSEMBLE_REPO" rev-parse "$commit:pyproject.toml"
             cat "$dir/env.lock"; } | sha256sum | cut -c1-8)
    rm -f "$def"
    echo "svensemble-${tree:0:7}-$sum.sif"
}

# matching_image <group dir> <svensemble2 commit>: print the group's image if it holds <commit>'s
# svensemble package and the group's env.lock; print nothing if there is none or it is stale.
# Also recognises images named before image_name existed: svensemble-<commit>-<hash of recipe + env.lock>.
matching_image() {
    local dir=$1 commit=$2 sif name old def sum
    sif=$(current_image "$dir")
    [[ -n "$sif" ]] || return 0
    name=$(basename "$sif")
    if [[ "$name" == "$(image_name "$dir" "$commit")" ]]; then
        echo "$sif"
        return 0
    fi
    [[ "$name" =~ ^svensemble-([0-9a-f]{7})-([0-9a-f]{8})\.sif$ ]] || return 0
    old=$(git -C "$SVENSEMBLE_REPO" rev-parse --verify --quiet "${BASH_REMATCH[1]}^{commit}") || return 0
    same_package "$old" "$commit" || return 0
    def=$(mktemp)
    write_image_def "$def" "$old"
    sum=$(cat "$def" "$dir/env.lock" | sha256sum | cut -c1-8)
    rm -f "$def"
    [[ "$name" == "svensemble-${old:0:7}-$sum.sif" ]] && echo "$sif"
    return 0
}

# build_image <group dir> <svensemble2 commit>: apptainer image of the group's env. Run write_records first.
# Named by image_name; an image of that name is reused, not rebuilt. Older images of the group are deleted.
build_image() {
    local dir=$1 commit=$2 sif ctx old
    command -v apptainer > /dev/null || die "apptainer not found (run 'module load apptainer')"
    write_image_def "$dir/svensemble.def" "$commit"
    sif=$(matching_image "$dir" "$commit")
    if [[ -n "$sif" ]]; then
        info "image up to date: $(basename "$sif")"
    else
        sif="$dir/$(image_name "$dir" "$commit")"
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
