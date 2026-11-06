# production

Scripts that turn the two code repos into things you can run: **experiments**
(temporary, editable) and **releases** (permanent, frozen). This repo also keeps
the record of every release.

- [1. The map](#1-the-map)
- [2. The three places code lives](#2-the-three-places-code-lives)
- [3. The parts of a group](#3-the-parts-of-a-group)
- [4. Experiment lifecycle](#4-experiment-lifecycle)
- [5. Release lifecycle](#5-release-lifecycle)
- [6. Running the pipeline](#6-running-the-pipeline)
- [7. Rules the scripts enforce](#7-rules-the-scripts-enforce)
- [8. Commands](#8-commands)
- [9. When things go wrong](#9-when-things-go-wrong)

---

## 1. The map

Everything starts in the two repos and flows one way: into experiments, then onto
`main`, then into releases, then into the paper.

```
                svensemble2/  +  nf-core-svensemble/        development (§2)
                     │                    │
       new-experiment│                    │make-release
       (branch + worktree)                │(tag + plain copy)
                     ▼                    │
          worktrees/<name>/               │                 experiments (§4)
                     │                    │
          merge exp/<name> into main ─────┘
                                          ▼
                              releases/<tag>/               releases (§5)
                                    │        │
                                    │        └──► production/manifests/<tag>/
                                    ▼                      (record, in git)
                              results for the paper
```

Project root layout:

```
Papenfuss_SVEnsemble2/
├── svensemble2/              Python package repo        (development)
├── nf-core-svensemble/       Nextflow pipeline repo     (development)
├── svensemble2_pub/          paper analysis; consumes releases
├── production/               this repo: scripts + release records
│   ├── bin/                  the commands (§8)
│   ├── lib/common.sh         shared paths and helpers
│   └── manifests/<tag>/      one record per release
├── worktrees/<name>/         one directory per experiment
├── releases/<tag>/           one directory per release
└── envs/nfcore/              Nextflow + nf-core tools; rebuild from envs/nfcore.lock.txt
```

## 2. The three places code lives

| | Development | Experiment | Release |
|---|---|---|---|
| Where | `svensemble2/`, `nf-core-svensemble/` | `worktrees/<name>/` | `releases/<tag>/` |
| Made by | you | [`new-experiment`](#new-experiment) | [`make-release`](#make-release) |
| Code is | your normal checkout | git worktree on branch `exp/<name>` | plain copy of a tagged commit, no git |
| Can change? | yes | yes: commit fixes on `exp/<name>` | no, read-only |
| Lives | always | until you [remove](#remove-experiment) it | forever |
| Results go in the paper? | no | no ([§5](#5-release-lifecycle) explains how to promote one) | yes |

All three share one git history. A commit made in an experiment's worktree shows up
in the development checkout straight away, because it is the same repo.

## 3. The parts of a group

An experiment and a release have the same structure, so once you know one you know
both:

```
<group>/
├── svensemble2/            code: worktree (experiment) or copy (release)
├── nf-core-svensemble/     code: worktree (experiment) or copy (release)
├── env/                    Python env, svensemble installed non-editable
├── experiment.config       or release.config: points the pipeline at env/
├── environment.used.yml    the environment.yml the env was built from
├── env.lock                exact conda packages  ─┐
├── pip.lock                exact pip packages     ├─ enough to rebuild env/
├── MANIFEST                commits, Python version ┘
├── svensemble.def          with --apptainer: recipe of the image
├── svensemble-<tree>-<hash>.sif     with --apptainer: env/ rebuilt in an image
├── env-analysis/           with --analysis: env/ plus plotting packages; for analysis only
├── analysis.used.yml       with --analysis: the specs env-analysis/ was built from
└── env-analysis.lock       with --analysis: exact conda packages of env-analysis/
```

How the parts depend on each other:

- `env/` is built from `svensemble2/environment.yml`.
- svensemble inside `env/` is installed from a **commit**, never from the files on
  disk. So `env/` always matches the commit recorded in `MANIFEST`, and uncommitted
  edits can't sneak in.
- The `.config` file points the pipeline's svensemble tasks at `env/`. It sets two
  things, because setting only one isn't enough:
  - `params.svensemble_conda`, used by the modules' `conda` directive.
  - the `beforeScript` that activates the env, for every `SVENSEMBLE_*` process. The
    pipeline's `conf/modules.config` builds that line from the param while the
    pipeline's own config is read, which happens before any `-c` file. A `-c` file
    that changed only the param would leave the tasks activating the old env.
- None of this happens unless you pass the file with `-c`. Without it, the tasks
  use the env named in the pipeline's `nextflow.config`.
- With `--apptainer`, the scripts also build an apptainer image: `env.lock` and
  svensemble from the same commit, installed in `/opt/env` on a `micromamba` base. The
  `.config` file then sets the image as the `container` of every `SVENSEMBLE_*`
  process, and empties their `beforeScript`. The `beforeScript` runs on the host,
  so an env activated there would leak into the container.
  - The file name holds the hash of the `svensemble/` tree at the commit, and a hash
    of the recipe (without its commit label), `pyproject.toml` and `env.lock`. So the
    name changes when the svensemble package, its packaging or the env does. A commit
    that touches only tests, docs or other files keeps the name (the `tests/` the image
    also installs are not part of it), and an unchanged image is never rebuilt.
  - Only `--apptainer` builds an image. Without it, an existing image stays in use
    only while it still matches the env and the svensemble package. Once it is stale,
    `refresh-experiment` keeps the file but points the `.config` at `env/`, and says so.
  - `env/` is still built. The image is made from its records.
- With `--analysis`, the scripts also build `env-analysis/`, a second env for analysis
  notebooks and scripts:
  - It is `svensemble2/environment.yml` plus `production/specs/analysis.yml` (plotting
    and notebook packages), solved together, with svensemble from the same commit as
    `env/`. Package versions can differ from `env/`, which is solved without the extras.
  - `svensemble_analyse` is installed editable from `svensemble2_pub/` in experiments, for
    testing. A release installs it non-editable from `svensemble2_pub`'s `main`, and
    records that commit as `svensemble2_pub_commit` in `MANIFEST`.
  - The pipeline, the `.config` file and the image never use it, so building or
    rebuilding it never reruns svensemble tasks.
  - The analysis package list lives in this repo, not in svensemble2, so editing it
    never changes a svensemble2 commit.
  - The scripts register it as a Jupyter kernel for you (`ipykernel install --user`):
    `sve-exp-<name>` (shown as "svensemble experiment <name> analysis") or `sve-rel-<tag>`
    ("svensemble release <tag> analysis"). `refresh-experiment` re-registers it, and
    `remove-experiment` deletes it. Releases are never removed, so neither are their kernels.

## 4. Experiment lifecycle

```
new-experiment ──► run ──► (fix ──► commit ──► refresh-experiment ──► run)* ──► merge ──► remove-experiment
```

1. **Create.** `new-experiment foo` creates branch `exp/foo` from `main` in both
   repos, checks it out in `worktrees/foo/`, and builds the env. To start from a
   feature branch instead, pass it:
   `new-experiment foo feature/x main`. The arguments are the svensemble2 ref, then
   the pipeline ref.
2. **Run.** See [§6](#6-running-the-pipeline).
3. **Fix.** Edit in `worktrees/foo/svensemble2/` or `worktrees/foo/nf-core-svensemble/`,
   then commit. Your commit lands on `exp/foo`.
   - A pipeline fix takes effect on the next run.
   - A svensemble fix needs `refresh-experiment foo` first, which reinstalls svensemble
     from the new commit. It also rebuilds the whole env if `environment.yml` changed.
     An existing `env-analysis/` gets the same svensemble and a fresh editable
     `svensemble_analyse`, and is rebuilt if its specs changed or its last build failed.
4. **Merge.** If the work is worth keeping, merge `exp/foo` into `main` from your
   development checkout: `git merge exp/foo`.
5. **Remove.** `remove-experiment foo` deletes the directory and env, and tells you
   whether `exp/foo` is merged. Branches are never deleted for you.

## 5. Release lifecycle

```
merge into main ──► make-release ──► run ──► cite the tag
```

1. Get the code you want onto `main` in both repos.
2. `make-release v0.5.0` copies `main` of both repos, builds the env, writes the
   records, tags both repos `v0.5.0`, commits the records to `manifests/v0.5.0/`,
   and makes the release read-only. To release specific commits on `main` rather
   than its tip, pass them: `make-release v0.5.0 <svensemble2-commit> <pipeline-commit>`.
3. Run the pipeline from the release ([§6](#6-running-the-pipeline)).
4. Next to each set of results, note the tag. The tag leads to `manifests/<tag>/`,
   and that leads to the exact code and packages.

**Promoting an experiment.** If an experiment gave results you want in the paper,
merge it into `main`, make a release, and rerun from the release. If rerunning is
too expensive, keep that experiment's `MANIFEST` and lock files with the results.

**Pushing.** Tags are created locally. The script prints the push command; pushing is
up to you.

## 6. Running the pipeline

```bash
mkdir -p /path/to/run/foo && cd /path/to/run/foo
micromamba run -p <project root>/envs/nfcore nextflow run <group>/nf-core-svensemble -c <group>/experiment.config -profile ... [params]
```

- **Always pass `-c <group>/experiment.config`** (or `release.config` for a release).
  It's the only thing that makes svensemble tasks use the group's env
  ([§3](#3-the-parts-of-a-group)). `new-experiment` and `make-release` print this
  reminder when they finish.

- **Launch from a separate directory.** Nextflow writes `.nextflow/` and `work/`
  into the directory you launch from. Launching inside a worktree would leave
  untracked files in it, and `remove-experiment` would refuse. A release is
  read-only, so launching there fails outright.
- **`-resume` doesn't notice env changes.** Nextflow's task hash ignores the env, so
  after `refresh-experiment`, cached svensemble tasks don't rerun. Use a fresh launch
  directory, or no `-resume`, after a refresh.
  - A group with an image is the exception. The task hash includes the container
    name, and the name changes with what the image installs, so a rebuilt image reruns
    the svensemble tasks under `-resume`. A stale image that `refresh-experiment`
    replaces with `env/` changes the hash too.
- **An image needs `-profile apptainer`.** Without a container engine, Nextflow
  ignores `container`. The emptied `beforeScript` then activates nothing, and the tasks
  run with whatever Python is on the `PATH`.
- **An image also needs apptainer on the `PATH`.** Run `module load apptainer/1.4.5`
  (the version that builds the images) in the shell you launch Nextflow from.

## 7. Rules the scripts enforce

1. **One main line.** Releases come only from commits on `main` (`make-release`
   checks).
2. **An env matches a commit.** svensemble is always installed from a commit, never
   from your working files.
3. **Releases never change.** They're read-only, and if a tag already points at a
   different commit, `make-release` refuses.
4. **Nothing is lost on removal.** `remove-experiment` refuses if a worktree has
   uncommitted changes or the directory holds anything it didn't create, and it never
   deletes branches.
5. **A failed release leaves nothing behind.** If `make-release` fails partway, it
   deletes the half-built release, and no tags are created.

## 8. Commands

All of these are in `bin/`. Run any of them without arguments, or with `-h`, to see
its usage. Options can go anywhere on the line.

`--apptainer` (on `new-experiment`, `refresh-experiment` and `make-release`) also
builds the group's image ([§3](#3-the-parts-of-a-group)) and points the `.config`
at it. The scripts load the `apptainer/1.4.5` module themselves (`APPTAINER_MODULE`
in `lib/common.sh`) before building anything, swapping out any other apptainer
version you have loaded. A build needs network access to Docker Hub and conda-forge. A build takes about 5–10 minutes and makes an image of about 300 MB.
Only this flag ever builds an image.

`--analysis` (on the same three) also builds `env-analysis/`
([§3](#3-the-parts-of-a-group)). It never touches `env/`, the image or the `.config`.

#### new-experiment
`new-experiment [--apptainer] [--analysis] <name> [svensemble2-ref] [pipeline-ref]`
Creates `worktrees/<name>/` on branch `exp/<name>` in both repos. Refs default to
`main`. If `exp/<name>` already exists, it's reused, so you can bring back a removed
experiment.

#### refresh-experiment
`refresh-experiment [--apptainer] [--analysis] <name>`
Reinstalls svensemble in the experiment's env from the latest commit on
`exp/<name>`, and rebuilds the whole env if `environment.yml` changed or the env is missing. It then
rewrites `MANIFEST` and the lock files.
- With `--apptainer`, it builds the image if its name changed (or reuses the existing
  one) and deletes older ones.
- Without it, no image is built. An existing image stays in the `.config` only if it
  still matches; otherwise svensemble tasks run in `env/`, with a warning.
- With `--analysis`, or if `env-analysis/` exists, it refreshes `env-analysis/` too:
  svensemble from the same commit, and a full rebuild if its specs changed or it is missing.

#### remove-experiment
`remove-experiment <name>`
Removes the worktrees, both envs, the image and the generated files, and keeps the branches.

#### make-release
`make-release [--apptainer] [--analysis] <tag> [svensemble2-ref] [pipeline-ref]`
Builds `releases/<tag>/`, tags both repos, and records `manifests/<tag>/` in this
repo. With `--apptainer`, the image's recipe goes into `manifests/<tag>/` too; with
`--analysis`, `analysis.used.yml` and `env-analysis.lock` do, and `MANIFEST` records the
`svensemble2_pub` commit whose `svensemble_analyse` the release installed.

## 9. When things go wrong

| Situation | What to do |
|---|---|
| `new-experiment` failed partway | `remove-experiment <name>`, then run it again |
| An experiment env broke or got deleted | `rm -rf worktrees/<name>/env`, then `refresh-experiment <name>` rebuilds it |
| An analysis env broke or got deleted | `rm -rf worktrees/<name>/env-analysis`, then `refresh-experiment --analysis <name>` rebuilds it |
| A release env broke or got deleted | rebuild from its records: `micromamba create -p <rel>/env --file <rel>/env.lock`, then `pip install --no-deps` svensemble from the tag. Run `chmod -R u+w <rel>` first, `chmod -R a-w <rel>` after |
| You need to delete a release | `chmod -R u+w releases/<tag> && rm -rf releases/<tag>`. The tag and `manifests/<tag>/` stay, so you can rebuild it later |
| `remove-experiment` refuses | it names the reason: commit or discard changes in the worktree, or move results out of the directory |
| `make-release` says a commit is not on `main` | merge it into `main` first ([§7](#7-rules-the-scripts-enforce), rule 1) |
| An image build failed | fix the cause (often network, or `/tmp` full: set `APPTAINER_TMPDIR`). For an experiment, the env is already built: run `refresh-experiment --apptainer <name>`. `make-release` removes the half-built release, so just run it again |
