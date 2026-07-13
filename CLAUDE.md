# CLAUDE.md

Open OnDemand app definitions, deployed by living in `~/ondemand/dev/` — the
OnDemand **sandbox app** directory. Editing a file here changes the running app.

**The RStudio app has moved to its own repo: https://github.com/mjz1/rstudio-ood**
(checkout: `~/work/repos/rstudio-ood`). It was split out because it had outgrown
a subdirectory — its own installer, CI and README — and because keeping the
checkout inside `~/ondemand/dev` meant every edit was instantly live in
production. That repo now deploys *into* `~/ondemand/dev/rstudio_dev` rather than
being it. What remains here (`jupyter/`, `my_jupyter_app/`) still follows the old
edit-in-place model.

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
  self-resubmitting Slurm job. Image syncing is done **by hand**
  (`sync-images.sh [--sync]`) — a scheduled variant was tried and dropped.
- Login nodes must not run compute. `sync-images.sh` splits this deliberately:
  the digest check is three HTTP HEAD requests and runs anywhere; the ~4 GB pull
  plus squashfs conversion is submitted with `sbatch`. If `$SLURM_JOB_ID` is
  already set it runs inline instead.

## What is left here

`jupyter/` and `my_jupyter_app/` are plain Batch Connect apps: no container, no
image management, no session slots. The Singularity/image/session-slot lore that
used to fill this file was all about the RStudio app and moved with it to
[mjz1/rstudio-ood](https://github.com/mjz1/rstudio-ood).

## Known sharp edges

- `sruni`/`scon` in `~/.alias` hardcode `-p interactive` and `scon`'s
  `-p|--partition` branch assigns to `time` rather than `partition`. Unrelated
  to these apps, but adjacent.
