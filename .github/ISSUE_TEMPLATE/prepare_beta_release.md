---
name: Prepare release
about: Execute tasks for the creation and publishing of a new release
title: 'Prepare release 0.0.0'
labels: beta-release
assignees: ''

---

<!--
Add appropriate release number to title!

For detailed info on the release process refer to https://github.com/waku-org/nwaku/blob/master/docs/contributors/release-process.md
 -->

### Items to complete

All items below are to be completed by the owner of the given release.

- [ ] Create release branch
- [ ] Assign release candidate tag to the release branch HEAD. e.g. v0.30.0-rc.0
- [ ] Generate and edit releases notes in CHANGELOG.md
- [ ] Review possible update of [config-options](https://github.com/waku-org/docs.waku.org/blob/develop/docs/guides/nwaku/config-options.md)
- [ ] _End user impact_: Summarize impact of changes on Status end users (can be a comment in this issue).

- [ ] **Waku fleets validation**
  - [ ] Lock `waku.test` and `waku.sandbox` fleets to release candidate version
  - [ ] Search _Kibana_ logs from the previous month (since last release was deployed), for possible crashes or errors in `waku.test` and `waku.sandbox`.
      - Most relevant logs are `(fleet: "waku.test" AND message: "SIGSEGV")` OR `(fleet: "waku.sandbox" AND message: "SIGSEGV")`
  - [ ] Unlock `waku.test` and `waku.sandbox` to resume auto-deployment of latest `master` commit

- [ ] Bump nwaku dependency in [waku-rust-bindings](https://github.com/waku-org/waku-rust-bindings) and make sure all examples and tests work

- [ ] Update according to the new release [waku-compose](https://github.com/waku-org/nwaku-compose) and [waku-simulator](https://github.com/waku-org/waku-simulator).

- [ ] **Proceed with release**

  - [ ] Assign a release tag to the same commit that contains the validated release-candidate tag
  - [ ] Create GitHub release
  - [ ] Deploy the release to DockerHub
  - [ ] Announce the release

- [ ] **Promote release to fleets**.
  - [ ] Update infra config with any deprecated arguments or changed options
  - [ ] [Deploy final release to `waku.sandbox` fleet](https://ci.infra.status.im/job/nim-waku/job/deploy-waku-sandbox)
  - [ ] [Deploy final release to `status.staging` fleet](https://ci.infra.status.im/job/nim-waku/job/deploy-shards-staging/)
  - [ ] [Deploy final release to `status.prod` fleet](https://ci.infra.status.im/job/nim-waku/job/deploy-shards-test/)

- [ ] **Post release**
  - [ ] Submit a PR from the release branch to master. Important to commit the PR with "create a merge commit" option.
  - [ ] Update waku-org/nwaku-compose with the new release version.
  - [ ] Update version in js-waku repo. [update only this](https://github.com/waku-org/js-waku/blob/7c0ce7b2eca31cab837da0251e1e4255151be2f7/.github/workflows/ci.yml#L135) by submitting a PR.
