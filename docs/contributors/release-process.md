# Release Process

How to do releases.

For more context, see https://trunkbaseddevelopment.com/branch-for-release/

## How to do releases

### Before release

Ensure all items in this list are ticked:
- [ ] All issues under the corresponding release [milestone](https://github.com/waku-org/nwaku/milestones) has been closed or, after consultation, deferred to a next release.
- [ ] All submodules are up to date.
  > **IMPORTANT:** Updating submodules requires a PR (and very often several "fixes" to maintain compatibility with the changes in submodules). That PR process must be done and merged a couple of days before the release.
  > In case the submodules update has a low effort and/or risk for the release, follow the ["Update submodules"](./git-submodules.md) instructions.
  > If the effort or risk is too high, consider postponing the submodules upgrade for the subsequent release or delaying the current release until the submodules updates are included in the release candidate.
- [ ] The [js-waku CI tests](https://github.com/waku-org/js-waku/actions/workflows/ci.yml) pass against the release candidate (i.e. nwaku latest `master`).
  > **NOTE:** This serves as a basic regression test against typical clients of nwaku.
  > The specific job that needs to pass is named `node_with_nwaku_master`.

### Performing the release

1. Checkout a release branch from master

    ```
    git checkout -b release/v0.1.0
    ```

1. Update `CHANGELOG.md` and ensure it is up to date. Use the helper Make target to get PR based release-notes/changelog update.

    ```
    make release-notes
    ```

1. Create a release-candidate tag with the same name as release and `-rc.N` suffix a few days before the official release and push it

    ```
    git tag -as v0.1.0-rc.0 -m "Initial release."
    git push origin v0.1.0-rc.0
    ```

    This will trigger a [workflow](../../.github/workflows/pre-release.yml) which will build RC artifacts and create and publish a Github release

1. Open a PR from the release branch for others to review the included changes and the release-notes

1. In case additional changes are needed, create a new RC tag

    Make sure the new tag is associated
    with CHANGELOG update.

    ```
    # Make changes, rebase and create new tag
    # Squash to one commit and make a nice commit message
    git rebase -i origin/master
    git tag -as v0.1.0-rc.1 -m "Initial release."
    git push origin v0.1.0-rc.1
    ```

1. For the release validation process, please refer to the following [guide](https://www.notion.so/Release-Process-61234f335b904cd0943a5033ed8f42b4#47af557e7f9744c68fdbe5240bf93ca9)

1. Once the release-candidate has been validated, create a final release tag and push it.
We also need to merge release branch back to master as a final step.

    ```
    git checkout release/v0.1.0
    git tag -as v0.1.0 -m "Initial release."
    git push origin v0.1.0
    git switch master
    git pull
    git merge release/v0.1.0
    ```

1. Create a [Github release](https://github.com/waku-org/nwaku/releases) from the release tag.

    * Add binaries produced by the ["Upload Release Asset"](https://github.com/waku-org/nwaku/actions/workflows/release-assets.yml) workflow. Where possible, test the binaries before uploading to the release.

### After the release

1. Announce the release on Twitter, Discord and other channels.
2. Deploy the release image to [Dockerhub](https://hub.docker.com/r/wakuorg/nwaku) by triggering [the manual Jenkins deployment job](https://ci.infra.status.im/job/nim-waku/job/docker-manual/).
  > Ensure the following build parameters are set:
  > - `MAKE_TARGET`: `wakunode2`
  > - `IMAGE_TAG`: the release tag (e.g. `v0.16.0`)
  > - `IMAGE_NAME`: `wakuorg/nwaku`
  > - `NIMFLAGS`: `--colors:off -d:disableMarchNative -d:chronicles_colors:none -d:postgres`
  > - `GIT_REF` the release tag (e.g. `v0.16.0`)
3. Update the default nwaku image in [nwaku-compose](https://github.com/waku-org/nwaku-compose/blob/master/docker-compose.yml)
4. Deploy the release to appropriate fleets:
   - Inform clients
   > **NOTE:** known clients are currently using some version of js-waku, go-waku, nwaku or waku-rs.
   > Clients are reachable via the corresponding channels on the Vac Discord server.
   > It should be enough to inform clients on the `#nwaku` and `#announce` channels on Discord.
   > Informal conversations with specific repo maintainers are often part of this process.
   - Check if nwaku configuration parameters changed. If so [update fleet configuration](https://www.notion.so/Fleet-Ownership-7532aad8896d46599abac3c274189741?pvs=4#d2d2f0fe4b3c429fbd860a1d64f89a64) in [infra-nim-waku](https://github.com/status-im/infra-nim-waku)
   - Deploy release to the `waku.sandbox` fleet from [Jenkins](https://ci.infra.status.im/job/nim-waku/job/deploy-waku-sandbox/).
   - Ensure that nodes successfully start up and monitor health using [Grafana](https://grafana.infra.status.im/d/qrp_ZCTGz/nim-waku-v2?orgId=1) and [Kibana](https://kibana.infra.status.im/goto/a7728e70-eb26-11ec-81d1-210eb3022c76).
   - If necessary, revert by deploying the previous release. Download logs and open a bug report issue.

### Performing a patch release

1. Cherry-pick the relevant commits from master to the release branch

    ```
    git cherry-pick <commit-hash>
    ```

2. Create a release-candidate tag with the same name as release and `-rc.N` suffix

3. Update `CHANGELOG.md`. From the release branch, use the helper Make target after having cherry-picked the commits.

    ```
    make release-notes
    ```
    Create a new branch and raise a PR with the changelog updates to master.

4. Once the release-candidate has been validated and changelog PR got merged, cherry-pick the changelog update from master to the release branch. Create a final release tag and push it.

5. Create a [Github release](https://github.com/waku-org/nwaku/releases) from the release tag and follow the same post-release process as usual.
