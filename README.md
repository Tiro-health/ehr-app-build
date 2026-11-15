# ehr-app-build

The shared build and publish workflow for apps hosted on `<name>.tirohealth.app`.

## Use it

Call the workflow from a workflow in the app repository:

```yaml
name: Build
on:
  push:
    branches: [main]
    tags: ["v*"]
  pull_request:
jobs:
  build:
    uses: Tiro-health/ehr-app-build/.github/workflows/build.yml@v2
    permissions:
      contents: read
      id-token: write
```

`v2` is the tag with this deploy path. `v1` is the old Tiro Deploy path, where the workflow
only uploads the image and the Tiro Deploy GitHub App deploys it; it needs no `id-token: write`
and keeps working until it is retired with Tiro-health/ehr#3761. Move to `@v2` and add the
permissions below before then.

**The calling job must grant `id-token: write`.** The publish job signs in to Google Cloud with
the run's GitHub OIDC token, and a called workflow never gets more permissions than the job that
calls it. Without the grant, GitHub refuses to start the run, pull requests included.

Inputs, both optional:

- `app`: the Tiro app to deploy. By default the workflow deploys the one app linked to the
  repository, and fails when it finds several.
- `tooling-ref`: the ref of this repository to take `scripts/` from. Default `v2`.

## What it does

`build` runs on every push and pull request: install, `check`, `build`, then
[`scripts/package.sh`](scripts/package.sh) packages the output into an image. On pushes to the
default branch and `v*` tags it uploads the image as the artifact `tiro-image`.

`publish` runs after it on pushes to the default branch only. It does not check out or run the
app's code; it takes the image from the `tiro-image` artifact. Then
[`scripts/publish.sh`](scripts/publish.sh):

1. Signed in as the repository itself (direct workload identity), finds the Cloud Run service in
   `ehr-factory-apps` labelled with the repository id, unless `app` is given.
2. Signs in as the app's deploy account `deploy-<app>`, pushes the image to
   `europe-west1-docker.pkg.dev/ehr-factory-apps/apps-<app>/app:<commit>`, and rolls a new revision
   that replaces the `app` container's image. The `smart-sidecar` container is left as it is.
3. Writes `https://<app>.tirohealth.app` to the job summary.

A newly linked app takes a moment to be set up. While its service or deploy account does not
exist yet, the job retries for up to 10 minutes, printing "This app is still being set up on
Tiro". After that it fails with "This repository is not linked to a Tiro app, or the app is
suspended": link the repository on the EHR's setup page.

## Develop

```sh
shellcheck scripts/*.sh tests/*.sh
tests/publish.test.sh   # stubs gcloud and docker; needs no Google Cloud access
actionlint
```
