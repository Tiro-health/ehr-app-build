# ehr-app-build

The shared build and publish workflow for apps hosted on `<name>.tirohealth.app`.

## Use it

Call the workflow from a workflow in the app repository:

```yaml
name: Tiro.health
on:
  push:
    branches: [main]
    tags: ["v*"]
  pull_request:
  workflow_dispatch:
jobs:
  app:
    name: App
    uses: Tiro-health/ehr-app-build/.github/workflows/build.yml@v2
    with:
      app: ${{ vars.TIRO_EHR_APP_NAME }}
    permissions:
      contents: read
      id-token: write
```

A commit then shows two checks, **Tiro.health / App / Build** and **Tiro.health / App / Publish**.
GitHub names a check `<calling workflow> / <calling job> / <job in this workflow>`; the first
two parts come from your file, the last from this one.

`v2` is the tag with this deploy path. `v1` is the old Tiro Deploy path, where the workflow
only uploads the image and the Tiro Deploy GitHub App deploys it; it needs no `id-token: write`
and keeps working until it is retired with Tiro-health/ehr#3761. Move to `@v2`, with `app` and the
permissions shown above, before then.

**The calling job must grant `id-token: write`.** The publish job signs in to Google Cloud with
the run's GitHub OIDC token, and a called workflow never gets more permissions than the job that
calls it. Without the grant, GitHub refuses to start the run, pull requests included.

Inputs:

- `app`: the name of your Tiro app. Pass the repository variable `TIRO_EHR_APP_NAME`: when you
  link the repository on the EHR's setup page (https://ehr.tiro.health/platform/setup), Tiro.health
  sets that variable and, once the app is set up, starts the workflow on the default branch
  (`workflow_dispatch`). Until then the variable is empty and the publish job passes with a
  "Not published: link this repository on Tiro.health" notice; the run's summary links the setup page. If Tiro.health could not set
  the variable, the setup page shows the `gh variable set` command to run. Pull requests and other branches
  only build and do not need it.
- `tooling-ref`: the ref of this repository the build job takes `scripts/package.sh` from.
  Default `v2`. The publish job ignores it: it always runs `scripts/publish.sh` from the `v2`
  tag, the ref the deploy accounts trust, so a caller cannot choose the code that runs with
  its app's deploy identity.

## What it does

**Build** (job `build`) runs on every push and pull request: install, `check`, `build`, then
[`scripts/package.sh`](scripts/package.sh) packages the output into an image. On pushes to the
default branch and `v*` tags, and on manual runs of the default branch, it uploads the image as
the artifact `tiro-image`.

**Publish** (job `publish`) runs after it on pushes to, and manual runs of, the default branch. It does not check out or run the
app's code; it takes the image from the `tiro-image` artifact. Then
[`scripts/publish.sh`](scripts/publish.sh), from the `v2` tag:

1. Without `app`, adds a "Not published" notice and a "Not published yet" section to the run's
   summary with a link to the EHR's setup page, and stops: the job passes and nothing is
   deployed. An `app` that is not a valid name fails the job.
2. Signs in as the app's deploy account `deploy-<app>` through workload identity federation,
   pushes the image to `europe-west1-docker.pkg.dev/ehr-factory-apps/apps-<app>/app:<commit>`,
   and rolls a new revision that replaces the `app` container's image. The `smart-sidecar`
   container is left as it is.
3. Writes `https://<app>.tirohealth.app` to the job summary under "Published".

A newly linked app takes a moment to be set up. While its deploy account refuses this
repository, the job retries for up to 10 minutes, printing "This app is still being set up on
Tiro". After that it fails with "This repository is not linked to a Tiro app, or the app is
suspended": check the app name, and link the repository on the EHR's setup page.

## Develop

```sh
shellcheck scripts/*.sh tests/*.sh
tests/publish.test.sh   # stubs gcloud and docker; needs no Google Cloud access
actionlint
```
