# Release Process

How to do releases.

For more context, see https://trunkbaseddevelopment.com/branch-for-release/

## How to to do releases

### Before release

Ensure all items in this list are ticked:
- [ ] All issues under the corresponding release [milestone](https://github.com/status-im/nwaku/milestones) has been closed or, after consultation, deferred to a next release.
- [ ] All submodules are up to date.
  > **IMPORTANT:** Updating submodules requires a PR (and very often several "fixes" to maintain compatibility with the changes in submodules). That PR process must be done and merged a couple of days before the release.
  > In case the submodules update has a low effort and/or risk for the release, follow the ["Update submodules"](./git-submodules.md) instructions.
  > If the effort or risk is too high, consider postponing the submodules upgrade for the subsequent release or delaying the current release until the submodules updates are included in the release candidate.

### Performing the release

1. Checkout a release branch from master

`git checkout -b release/v0.1`

2. Update `CHANGELOG.md` and ensure it is up to date

3. Create a tag with the same name as release and push it

```
git tag -as v0.1 -m "Initial release."
git push origin v0.1
```

4. Open a PR

5. Harden release in release branch
    - Create a [Github release](https://github.com/status-im/nwaku/releases) on the release tag.
    - Add binaries for `macos` and `ubuntu` as release assets. Binaries can be compiled by triggering the ["Upload Release Asset"](https://github.com/status-im/nwaku/actions/workflows/release-assets.yml) workflow. Where possible, test the binaries before uploading to the release.

6. Modify tag

If you need to update stuff, remove tag and make sure the new tag is associated
with CHANGELOG update.

```
# Delete tag
git tag -d v0.1
git push --delete origin v0.1

# Make changes, rebase and tag again
# Squash to one commit and make a nice commit message
git rebase -i origin/master
git tag -as v0.1 -m "Initial release."
git push origin v0.1
```

### After the release

1. Announce the release on Twitter, Discord and other channels.
2. Deploy the release:
   - Inform clients
   > **NOTE:** known clients are currently using some version of js-waku, go-waku, nwaku or waku-rs.
   > Clients are reachable via the corresponding channels on the Vac Discord server.
   > It should be enough to inform clients on the `#nwaku` and `#announce` channels on Discord.
   > Informal conversations with specific repo maintainers are often part of this process.
   - Deploy release to the `wakuv2.prod` fleet from [Jenkins](https://ci.status.im/job/nim-waku/job/deploy-wakuv2-prod/).
   - Ensure that nodes successfully start up and monitor health using [Grafana](https://grafana.infra.status.im/d/qrp_ZCTGz/nim-waku-v2?orgId=1) and [Kibana](https://kibana.infra.status.im/goto/a7728e70-eb26-11ec-81d1-210eb3022c76).
   - If necessary, revert by deploying the previous release. Download logs and open a bug report issue.
3. Deploy release image to [Dockerhub](https://hub.docker.com/layers/statusteam/nim-waku/a5f8b9/images/sha256-88691a8f82bd6a4242fa99053a65b7fc4762b23a2b4e879d0f8b578c798a0e09?context=explore) by triggering [the same Jenkins job](https://ci.status.im/job/nim-waku/job/deploy-wakuv2-prod/) as before, but with the `IMAGE_TAG` set to the release tag (e.g. `v0.10`).
