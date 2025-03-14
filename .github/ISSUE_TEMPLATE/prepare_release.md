---
name: Prepare release
about: Execute tasks for the creation and publishing of a new release
title: 'Prepare release 0.0.0'
labels: release
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
- [ ] **Validate release candidate**
  - [ ] Bump nwaku dependency in [waku-rust-bindings](https://github.com/waku-org/waku-rust-bindings) and make sure all examples and tests work

- [ ] Automated testing
  - [ ] Ensures js-waku tests are green against release candidate
  - [ ] Ask Vac-QA and Vac-DST to perform available tests against release candidate
    - [ ] Vac-QA
    - [ ] Vac-DST (we need additional report. see [this](https://www.notion.so/DST-Reports-1228f96fb65c80729cd1d98a7496fe6f))

  - [ ] **On Waku fleets**
    - [ ] Lock `waku.test` fleet to release candidate version
    - [ ] Continuously stress `waku.test` fleet for a week (e.g. from `wakudev`)
    - [ ] Search _Kibana_ logs from the previous month (since last release was deployed), for possible crashes or errors in `waku.test` and `waku.sandbox`.
      - Most relevant logs are `(fleet: "waku.test" OR fleet: "waku.sandbox") AND message: "SIGSEGV"`
    - [ ] Run release candidate with `waku-simulator`, ensure that nodes connected to each other
    - [ ] Unlock `waku.test` to resume auto-deployment of latest `master` commit

  - [ ] **On Status fleet**
    - [ ] Deploy release candidate to `status.staging`
    - [ ] Perform [sanity check](https://www.notion.so/How-to-test-Nwaku-on-Status-12c6e4b9bf06420ca868bd199129b425) and log results as comments in this issue.
      - [ ] Connect 2 instances to `status.staging` fleet, one in relay mode, the other one in light client.
      - [ ] 1:1 Chats with each other
      - [ ] Send and receive messages in a community
      - [ ] Close one instance, send messages with second instance, reopen first instance and confirm messages sent while offline are retrieved from store
    - [ ] Perform checks based _end user impact_
    - [ ] Inform other (Waku and Status) CCs to point their instance to `status.staging` for a few days. Ping Status colleagues from their Discord server or [Status community](https://status.app/c/G3kAAMSQtb05kog3aGbr3kiaxN4tF5xy4BAGEkkLwILk2z3GcoYlm5hSJXGn7J3laft-tnTwDWmYJ18dP_3bgX96dqr_8E3qKAvxDf3NrrCMUBp4R9EYkQez9XSM4486mXoC3mIln2zc-TNdvjdfL9eHVZ-mGgs=#zQ3shZeEJqTC1xhGUjxuS4rtHSrhJ8vUYp64v6qWkLpvdy9L9) (not blocking point.)
    - [ ] Ask Status-QA to perform sanity checks (as described above) + checks based on _end user impact_; do specify the version being tested
    - [ ] Ask Status-QA or infra to run the automated Status e2e tests against `status.staging`
    - [ ] Get other CCs sign-off: they comment on this PR "used app for a week, no problem", or problem reported, resolved and new RC
    - [ ] **Get Status-QA sign-off**. Ensuring that `status.test` update will not disturb ongoing activities.

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
