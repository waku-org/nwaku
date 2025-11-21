---
name: Prepare Beta Release
about: Execute tasks for the creation and publishing of a new release
title: 'Prepare beta release 0.0.0'
labels: beta-release
assignees: ''

---

<!--
Add appropriate release number to title!

For detailed info on the release process refer to https://github.com/waku-org/nwaku/blob/master/docs/contributors/release-process.md
 -->

### Items to complete

All items below are to be completed by the owner of the given release.

- [ ] Create release branch ( e.g. release/v0.X.0 )
- [ ] Assign release candidate tag to the release branch HEAD. e.g. v0.X.0-rc.0..N etc.
- [ ] Generate and edit release notes in CHANGELOG.md
- [ ] Review possible updates to [config-options](https://github.com/waku-org/docs.waku.org/blob/develop/docs/guides/nwaku/config-options.md)
- [ ] _End user impact_: Summarize impact of changes on Status end users (can be a comment in this issue).

- [ ] **Waku test and fleets validation**
  - [ ] Ensure all the unit tests (specifically js-waku tests) are green against the release candidate.
  - [ ] Lock `waku.test` and `waku.sandbox` fleets to the release candidate version. [Need Jenkins access to start the fleet release; if you don't have access, ask the infra team.]
    - Start job on `waku.sandbox` and `waku.test` [ Deployment job ](https://ci.infra.status.im/job/nim-waku/), Wait for completion of the job. If it fails, then debug it.
    - Then lock both fleets to the release candidate version. (If you don't have access to lock fleets, ask the infra team to do it.)
    - Verify at https://fleets.waku.org/ that the fleet is locked to the release candidate version.
    - Check if the image is created at [harbor](https://harbor.status.im/harbor/projects/9/repositories/nwaku/artifacts-tab)

  - [ ] Analyze Kibana logs from the previous month (since the last release was deployed) for possible crashes or errors in `waku.test` and `waku.sandbox`.
      - Most relevant logs are `(fleet: "waku.test" AND message: "SIGSEGV")` OR `(fleet: "waku.sandbox" AND message: "SIGSEGV")`
  - [ ] Unlock `waku.test` and `waku.sandbox` to resume auto-deployment of the latest `master` commit

- [ ] **Proceed with release**

  - [ ] Assign a release tag ( v0.X.0-beta ) to the same commit that contains the validated release-candidate tag (e.g. v0.X.0-beta) and submit a PR from the release branch to master.
  - [ ] Bump nwaku dependency in [waku-rust-bindings](https://github.com/waku-org/waku-rust-bindings) and make sure all examples and tests work
  - [ ] Update [waku-compose](https://github.com/waku-org/nwaku-compose) and [waku-simulator](https://github.com/waku-org/waku-simulator) according to the new release.
  - [ ] Create GitHub release (https://github.com/waku-org/nwaku/releases)

- [ ] **Promote release to fleets**.
  - [ ] Ask the PM lead to announce the release.
  - [ ] Update infra config with any deprecated arguments or changed options.

### Links

- [Release process](https://github.com/waku-org/nwaku/blob/master/docs/contributors/release-process.md)
- [Release notes](https://github.com/waku-org/nwaku/blob/master/CHANGELOG.md)
- [Fleet ownership](https://www.notion.so/Fleet-Ownership-7532aad8896d46599abac3c274189741?pvs=4#d2d2f0fe4b3c429fbd860a1d64f89a64)
- [Infra-nim-waku](https://github.com/status-im/infra-nim-waku)
- [Jenkins](https://ci.infra.status.im/job/nim-waku/)
- [Fleets](https://fleets.waku.org/)
- [Harbor](https://harbor.status.im/harbor/projects/9/repositories/nwaku/artifacts-tab)
