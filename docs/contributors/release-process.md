# Release Process

How to do releases.

For more context, see https://trunkbaseddevelopment.com/branch-for-release/

## How to do releases

### Prerequisites

- All issues under the corresponding release [milestone](https://github.com/waku-org/nwaku/milestones) have been closed or, after consultation, deferred to the next release.
- All submodules are up to date.
  > Updating submodules requires a PR (and very often several "fixes" to maintain compatibility with the changes in submodules). That PR process must be done and merged a couple of days before the release.

  > In case the submodules update has a low effort and/or risk for the release, follow the ["Update submodules"](./git-submodules.md) instructions.

  > If the effort or risk is too high, consider postponing the submodules upgrade for the subsequent release or delaying the current release until the submodules updates are included in the release candidate.

### Release process ( step by step )

1. Checkout a release branch from master

    ```
    git checkout -b release/v0.1.0
    ```

2. Update `CHANGELOG.md` and ensure it is up to date. Use the helper Make target to get PR based release-notes/changelog update.

    ```
    make release-notes
    ```

3. Create a release-candidate tag with the same name as release and `-rc.N` suffix a few days before the official release and push it

    ```
    git tag -as v0.1.0-rc.0 -m "Initial release."
    git push origin v0.1.0-rc.0
    ```

    This will trigger a [workflow](../../.github/workflows/pre-release.yml) which will build RC artifacts and create and publish a GitHub release

4. Open a PR from the release branch for others to review the included changes and the release-notes

5. In case additional changes are needed, create a new RC tag

    Make sure the new tag is associated
    with CHANGELOG update.

    ```
    # Make changes, rebase and create new tag
    # Squash to one commit and make a nice commit message
    git rebase -i origin/master
    git tag -as v0.1.0-rc.1 -m "Initial release."
    git push origin v0.1.0-rc.1
    ```

6. **Validation of release candidate**

   - **Automated testing**
     - Ensure js-waku tests are green against the release candidate
     - Ask Vac-QA and Vac-DST to run their available tests against the release candidate, share all release candidate with both team.

     > We need additional report like [this](https://www.notion.so/DST-Reports-1228f96fb65c80729cd1d98a7496fe6f) specificly from DST team.

   - **Waku fleet testing**
     - Lock `waku.test` and `waku.sandbox` fleet to release candidate version
     - Search _Kibana_ logs from the previous month (since last release was deployed), for possible crashes or errors in `waku.test` and `waku.sandbox`.
       - Most relevant logs are `(fleet: "waku.test" AND message: "SIGSEGV")` OR `(fleet: "waku.sandbox" AND message: "SIGSEGV")`
     - Run release candidate with `waku-simulator`, ensure that nodes connected to each other
     - Unlock `waku.test` to resume auto-deployment of latest `master` commit

   - **Status fleet testing**
     - Deploy release candidate to `status.staging`
     - Perform [sanity check](https://www.notion.so/How-to-test-Nwaku-on-Status-12c6e4b9bf06420ca868bd199129b425) and log results as comments in this issue.
       - Connect 2 instances to `status.staging` fleet, one in relay mode, the other one in light client.
       - 1:1 chats with each other
       - Send and receive messages in a community
       - Close one instance, send messages with second instance, reopen first instance and confirm messages sent while offline are retrieved from store
     - Perform checks based on _end-user impact_
     - Inform other (Waku and Status) CCs to point their instance to `status.staging` for a few days. Ping Status colleagues from their Discord server or [Status community](https://status.app) (not blocking point.)
     - Ask Status-QA to perform sanity checks (as described above) + checks based on _end user impact_; do specify the version being tested
     - Ask Status-QA or infra to run the automated Status e2e tests against `status.staging`
     - Get other CCs sign-off: they comment on this PR "used app for a week, no problem", or problem reported, resolved and new RC
     - **Get Status-QA sign-off**. Ensuring that `status.test` update will not disturb ongoing activities.

7. Once the release-candidate has been validated, create a final release tag and push it.
We also need to merge the release branch back into master as a final step.

    ```
    git checkout release/v0.1.0
    git tag -as v0.1.0 -m "Initial release."
    git push origin v0.1.0
    git switch master
    git pull
    git merge release/v0.1.0
    ```
8. Update `waku-rust-bindings`, `waku-simulator` and `nwaku-compose` to use the new release.

9. Create a [GitHub release](https://github.com/waku-org/nwaku/releases) from the release tag.

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
3. Bump the nwaku dependency in [nwaku-compose](https://github.com/waku-org/nwaku-compose/blob/master/docker-compose.yml)
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
5. Submit a PR to merge the release branch back to `master`. Make sure you use the option `Merge pull request (Create a merge commit)` to perform such merge.

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

5. Create a [GitHub release](https://github.com/waku-org/nwaku/releases) from the release tag and follow the same post-release process as usual.
