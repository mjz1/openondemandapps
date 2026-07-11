# CLAUDE.md

Open OnDemand app definitions, deployed by living in `~/ondemand/dev/` — the
OnDemand **sandbox app** directory. Editing a file here changes the running app.
There is no build or deploy step, and no staging environment.

The substantial app is `rstudio_dev/`; see its [README](rstudio_dev/README.md)
for architecture, and `sync-images.sh --help` for image management.

## Ground truth about this environment

- **The portal is not this machine.** Open OnDemand renders the ERB templates
  inside the PUN, on the web node. `ruby` is not installed anywhere on the
  cluster, so `form.yml.erb` and `template/script.sh.erb` **cannot be tested
  locally**. They are only exercised by launching a session. Treat any change to
  them as unverified until someone clicks Launch.
- The PUN does not reliably source your shell rc, so **environment variables do
  not reach the ERB templates**. Configuration lives in
  `~/.config/rstudio_dev/config`, written by `install.sh` and read by all four
  consumers (`form.yml.erb`, `script.sh.erb`, `sync-images.sh`, `r-wrappers.sh`).
  Environment still wins when set, for one-off overrides.
- **No cron.** `scrontab` is disabled cluster-wide and login-node `crontab` is
  blocked by PAM. Anything recurring must be run by hand or by a
  self-resubmitting Slurm job. The image sync uses the latter:
  `rstudio_dev/sync-images.sbatch` is a dual-mode script — run as a plain script
  it submits itself (login-node safe, submit only); as a Slurm job it runs
  `sync-images.sh --sync --local`, emails a summary (`RSTUDIO_SYNC_EMAIL`), and
  resubmits itself for the 2nd of next month. Bootstrap once with
  `RSTUDIO_SYNC_EMAIL=… bash rstudio_dev/sync-images.sbatch`; the monthly email
  is the heartbeat.
- Login nodes must not run compute. `sync-images.sh` splits this deliberately:
  the digest check is three HTTP HEAD requests and runs anywhere; the ~4 GB pull
  plus squashfs conversion is submitted with `sbatch`. If `$SLURM_JOB_ID` is
  already set it runs inline instead.

## Singularity gotchas that have bitten us

- **The host environment leaks into the container.** This host exports
  `SSL_CERT_FILE=/etc/pki/…` and `SSL_CERT_DIR=/etc/pki/…` (RHEL paths) which do
  not exist inside the Ubuntu image, breaking OpenSSL TLS. Quarto reports
  `Failed to load platform certificates`, which points nowhere near the cause.
  Both `script.sh.erb` and `r-wrappers.sh` remap these to the container's own CA
  bundle. Do **not** reach for `--cleanenv` — it also strips `SLURM_*` and
  `R_LIBS_USER`.
- The SIF is **read-only at runtime**, whatever the file permissions say.
  Anything the container needs to write must be bind-mounted from `$HOME` or
  `$TMPDIR`.
- `rserver` inside the image logs to syslog by default (rocker's setting), and
  there is no syslog socket in a container — so startup failures produce **no
  output at all**, and the only symptom is `wait_until_port_used` timing out.
  `script.sh.erb` binds a `logging.conf` with `logger-type=stderr` so errors
  reach the job's `output.log`. Keep it.
- **GPU passthrough is `--nv`, gated on Slurm's GPU-allocation signal — not a
  device probe.** `script.sh.erb` and `r-wrappers.sh` add `--nv` to `singularity
  exec` only when `CUDA_VISIBLE_DEVICES` / `SLURM_JOB_GPUS` is set (Slurm's gres
  plugin sets these only when a GPU was granted).
  - **Partition name is not a GPU signal.** GPU nodes here also belong to CPU
    partitions (`componc_cpu` etc.), so "am I on a gpu partition" is unreliable.
  - **`/dev/nvidia*` is not a GPU signal either — this was measured, not
    assumed.** A CPU job that lands on a GPU-capable node *sees* `/dev/nvidia0..N`
    despite being granted no GPU (`CUDA_VISIBLE_DEVICES` unset). Probing the
    device files would enable `--nv` for a CPU session and let it grab a GPU
    allocated to another user — a real multi-tenancy bug. The Slurm variables
    are what actually track the grant.
  `--nv` binds only the host driver (`libcuda.so`); the CUDA toolkit is not in
  the image. Frameworks (`torch`/`tensorflow`) bring their own and load it at
  runtime, which is why one image serves both CPU and GPU. GPU partitions are
  account-specific (the shared `gpu` partition denies `shahs3`; `componc_gpu_*`
  allow it), so they come from `RSTUDIO_QUEUES` config, never hard-coded.
- **R torch needs a CUDA hint; the driver alone is not enough.** Unlike Python
  torch (whose pip wheel bundles CUDA), R torch's auto-installer picks CPU vs GPU
  by looking for a *system* CUDA toolkit — which the image deliberately lacks —
  so it installs the CPU build even on a GPU node (`cuda_is_available()` FALSE
  despite `nvidia-smi` working). A GPU session therefore exports `CUDA=<version>`
  into R so the installer fetches the GPU build. The version is **derived, not
  hardcoded**: the highest torch-supported build (`RSTUDIO_TORCH_CUDA`, default
  `12.9 12.8 12.6`) that does not exceed the node's driver ceiling
  (`nvidia-smi`'s "CUDA Version"), read live per node. It is exported via the
  `rsession` wrapper (rserver strips the session env, so env vars set on the
  `singularity exec` line do not reach rsession — same reason `R_LIBS_USER` is
  passed there). `libtorch` lands in the per-version R library, so it is
  per-R-minor and ~6 GB each.

## Concurrent sessions

Each OnDemand session is its own `rserver` on its own node, so server state is
already per-job. Concurrent sessions collided only on **shared `$HOME` RStudio
state**: `~/.local/share/rstudio` (`XDG_DATA_HOME/rstudio` — session/workspace
state), the cache, and an abend-reset loop that rewrote *every* active session's
`session-persistent-state`. Fixed with **named slots**: `session_name` /
`new_session_name` form fields → a sanitised slot → **per-slot `XDG_DATA_HOME`
only** under `~/work/.rstudio-sessions/<slot>/data`. Slots live under `~/work`
(→ `/data1`), NOT `$HOME` (which is small).

**`XDG_CACHE_HOME` must stay shared** — this was a bug fix. renv keeps its
library and cache under `R_user_dir("renv","cache")` == `$XDG_CACHE_HOME/R/renv`,
so a per-slot cache pointed `.libPaths()` at an empty per-slot renv root and
every installed package vanished. `XDG_CONFIG_HOME` is likewise shared
(`~/.config`) so preferences persist. Only RStudio's session state (under
`XDG_DATA_HOME/rstudio`) needed isolating. Side effect: packages that store data
under `XDG_DATA_HOME` (e.g. `SeuratData`) become per-slot.

Works with open-source RStudio Server (no Workbench) because the sessions are
separate `rserver` processes — only the filesystem state had to be split. The
slot is one sanitised path segment (`[^A-Za-z0-9._-]`→`_`, leading dots stripped)
so it cannot escape `~/work/.rstudio-sessions`.

## Images vs libraries

**Images are a shared artifact. R package libraries are per-user.**

Packages are compiled against a specific R *minor* version and installed into a
directory you own, so `4.5_singularity` and `4.6_singularity` are not
interchangeable. Consequently:

- `script.sh.erb` **derives** `R_LIBS_USER` from the selected image rather than
  offering it as a separate form field. There used to be two independent selects,
  and the R 4.4 option pointed at a library directory that did not exist.
- **R ignores a missing `R_LIBS_USER` silently.** A wrong path is not an error,
  it is an invisible loss of every package you installed. Never fall back to
  another version's library; fail loudly instead.
- `form.yml.erb` offers only versions whose library directory exists, and
  `r-wrappers.sh` defaults to the newest R with a *populated* library — not to
  `latest`, which tracks the newest image and could silently move you onto an R
  version whose library you have not built yet.

## Images are rolling

`sync-images.sh` records the registry manifest digest of each `.sif` in a
`.digest` sidecar, so staleness is detected with HTTP HEAD requests rather than a
4 GB download. The upstream repo (`mjz1/rstudio-img`) rebuilds its rolling
`4.3`–`4.6` tags monthly, so **an image can change under a stable filename**.

- The previous build is retained as `rstudio-<ver>.sif.prev` (a hardlink, so it
  costs nothing until the new image lands). Rollback is a rename.
- `images.json` records digest, R/RStudio/Quarto versions and pull time for every
  image, so you can reconstruct what an analysis ran under.
- What actually moves between rebuilds is *not* mostly R. One rebuild took
  RStudio Server from 2025.09 to 2026.06 in a single step. R's patch version is
  the least significant thing in the image.

## Known sharp edges

- `template/before.sh.erb` generates a random RStudio password with
  `create_passwd 16` and then overwrites it with the literal string `password`.
  Annotated as a HACK for losing sessions when idle — which is more plausibly the
  `--auth-timeout-minutes` value, since raised to 6000. Left alone because
  changing it alters the login flow.
- `script.sh.erb` passes `--database-config-file` to work around an image bug
  fixed upstream in `rstudio-img` v1.1.1. It is now redundant for current images
  but still protects older ones. If you want to confirm the upstream fix stands
  on its own, drop the flag for one launch — otherwise a regression could hide
  behind the workaround indefinitely.
- `~/.alias` is tracked in a separate bare dotfiles repo (`$HOME/.cfg`), not this
  one. It sources `rstudio_dev/r-wrappers.sh`.
