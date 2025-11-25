---
name: Prepare Full Release
about: Execute tasks for the creation and publishing of a new release
title: 'Prepare full release 0.0.0'
labels: full-release
assignees: ''

---

<!--
Add appropriate release number to title!

For detailed info on the release process refer to https://github.com/waku-org/nwaku/blob/master/docs/contributors/release-process.md
 -->

### Items to complete

All items below are to be completed by the owner of the given release.

- [ ] Create release branch ( e.g. release/v0.X.0-beta )
- [ ] Assign release candidate tag to the release branch HEAD. e.g. v0.X.0-beta-rc.0..N etc.
- [ ] Generate and edit release notes in CHANGELOG.md
- [ ] Review possible updates to [config-options](https://github.com/waku-org/docs.waku.org/blob/develop/docs/guides/nwaku/config-options.md)
- [ ] _End user impact_: Summarize impact of changes on Status end users (can be a comment in this issue).

- [ ] **Validation of release candidate**

  - [ ] **Automated testing**
    - [ ] Ensure all the unit tests (specifically js-waku tests) are green against the release candidate.
    - [ ] Ask Vac-QA and Vac-DST to perform the available tests against the release candidate
    - [ ] Vac-DST (an additional report is needed; see [this](https://www.notion.so/DST-Reports-1228f96fb65c80729cd1d98a7496fe6f))

  - [ ] **Waku fleet testing**
    - [ ] Deploy the release candidate to `waku.test` and `waku.sandbox` fleets.
      - Start the [deployment job](https://ci.infra.status.im/job/nim-waku/) for both fleets and wait for it to finish (Jenkins access required; ask the infra team if you don't have it).
      - After completion, lock both fleets to the release candidate version.
      - Verify the lock status at https://fleets.waku.org/.
      - Confirm the container image exists on [Harbor](https://harbor.status.im/harbor/projects/9/repositories/nwaku/artifacts-tab).
    - [ ] Search _Kibana_ logs from the previous month (since the last release was deployed) for possible crashes or errors in `waku.test` and `waku.sandbox`.
      - Most relevant logs are `(fleet: "waku.test" AND message: "SIGSEGV")` OR `(fleet: "waku.sandbox" AND message: "SIGSEGV")`
    - [ ] Unlock `waku.test` and `waku.sandbox` to resume auto-deployment of the latest `master` commit

- [ ] **Status fleet testing**
  - [ ] Deploy release candidate to `status.staging`
  - [ ] Perform [sanity check](https://www.notion.so/How-to-test-Nwaku-on-Status-12c6e4b9bf06420ca868bd199129b425) and log results as comments in this issue.
    - [ ] Connect 2 instances to `status.staging` fleet, one in relay mode, the other one in light client.
      - 1:1 Chats with each other
      - Send and receive messages in a community
      - Close one instance, send messages with second instance, reopen first instance and confirm messages sent while offline are retrieved from store
    - [ ] Perform checks based on _end user impact_
    - [ ] Inform other (Waku and Status) CCs to point their instances to `status.staging` for a few days. Ping Status colleagues on their Discord server or in the [Status community](https://status.app/c/G3kAAMSQtb05kog3aGbr3kiaxN4tF5xy4BAGEkkLwILk2z3GcoYlm5hSJXGn7J3laft-tnTwDWmYJ18dP_3bgX96dqr_8E3qKAvxDf3NrrCMUBp4R9EYkQez9XSM4486mXoC3mIln2zc-TNdvjdfL9eHVZ-mGgs=#zQ3shZeEJqTC1xhGUjxuS4rtHSrhJ8vUYp64v6qWkLpvdy9L9) (this is not a blocking point.)
    - [ ] Ask Status-QA to perform sanity checks (as described above) and checks based on _end user impact_; specify the version being tested
    - [ ] Ask Status-QA or infra to run the automated Status e2e tests against `status.staging`
    - [ ] Get other CCs' sign-off: they should comment on this PR, e.g., "Used the app for a week, no problem." If problems are reported, resolve them and create a new RC.
    - [ ] **Get Status-QA sign-off**, ensuring that the `status.test` update will not disturb ongoing activities.

- [ ] **Proceed with release**

  - [ ] Assign a final release tag ( v0.X.0 ) to the same commit that contains the validated release-candidate tag (e.g. v0.X.0-beta) 
  - [ ] Submit a PR from the release branch to master. It is important to commit the PR using the "Create a merge commit" option.
  - [ ] Bump nwaku dependency in [waku-rust-bindings](https://github.com/waku-org/waku-rust-bindings) and make sure all examples and tests work
  - [ ] Update [waku-compose](https://github.com/waku-org/nwaku-compose) and [waku-simulator](https://github.com/waku-org/waku-simulator) according to the new release.
  - [ ] Create GitHub release (https://github.com/waku-org/nwaku/releases)

- [ ] **Promote release to fleets**.
  - [ ] Ask for release announcement to PM lead.
  - [ ] Update infra config with any deprecated arguments or changed options.

### Links

- [Release process](https://github.com/waku-org/nwaku/blob/master/docs/contributors/release-process.md)
- [Release notes](https://github.com/waku-org/nwaku/blob/master/CHANGELOG.md)
- [Fleet ownership](https://www.notion.so/Fleet-Ownership-7532aad8896d46599abac3c274189741?pvs=4#d2d2f0fe4b3c429fbd860a1d64f89a64)
- [Infra-nim-waku](https://github.com/status-im/infra-nim-waku)
- [Jenkins](https://ci.infra.status.im/job/nim-waku/)
- [Fleet](https://fleets.waku.org/)
- [Harbor](https://harbor.status.im/harbor/projects/9/repositories/nwaku/artifacts-tab)
