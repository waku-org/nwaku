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
- [ ] _End user impact_: Summarize impact of changes on Status end users (can be a comment in this issue).
- [ ] **Validate release candidate**

  - [ ] **On Waku fleets**
    - [ ] Lock `waku.test` fleet to release candidate version
    - [ ] Continuously stress `waku.test` fleet for a week (e.g. from `wakudev`)
    - [ ] Search _Kibana_ logs from the previous month (since last release was deployed), for possible crashes or errors in `waku.test` and `waku.sandbox`.
      - Most relevant logs are `(fleet: "waku.test" OR fleet: "waku.sandbox") AND message: "SIGSEGV"`
    - [ ] Run release candidate with `waku-simulator`, ensure that nodes connected to each other
    - [ ] Unlock `waku.test`

  - [ ] **On Status fleet**
    - [ ] Deploy release candidate to `status.staging`
    - [ ] Perform [sanity check](https://www.notion.so/How-to-test-Nwaku-on-Status-12c6e4b9bf06420ca868bd199129b425) and log results as comments in this issue.
      - [ ] Connect 2 instances to `status.staging` fleet, one in relay mode, the other one in light client.
      - [ ] 1:1 Chats with each other
      - [ ] Send and receive messages in a community
      - [ ] Close one instance, send messages with second instance, reopen first instance and confirm messages sent while offline are retrieved from store
    - [ ] Perform checks based _end user impact_
    - [ ] Ask other (Waku and Status) CCs to point their instance to `status.staging` for a week and use the app as usual.
    - [ ] Ask Status/QA to perform sanity checks (as described above) + checks based on _end user impact_
    - [ ] Ask Status/QA or infra to run the automated Status e2e tests against `status.staging`
    - [ ] Get other CCs sign-off: they comment on this PR "used app for a week, no problem", or problem reported, resolved and new RC
    - [ ] **Get Status/QA sign-off**. Ensuring that `status.test` update will not disturb ongoing activities.

- [ ] **Proceed with release**

  - [ ] Assign a release tag to the same commit that contains the validated release-candidate tag
  - [ ] Create GitHub release
  - [ ] Deploy the release to DockerHub
  - [ ] Announce the release
  - [ ] Submit a PR from the release branch to master. Important to commit the PR with "create a merge commit" option.

- [ ] **Promote release to fleets**.
  - [ ] Update infra config with any deprecated arguments or changed options
  - [ ] [Deploy final release to `waku.sandbox` fleet](https://ci.infra.status.im/job/nim-waku/job/deploy-waku-sandbox)
  - [ ] [Deploy final release to `status.staging` fleet](https://ci.infra.status.im/job/nim-waku/job/deploy-shards-staging/)
  - [ ] [Deploy final release to `status.test` fleet](https://ci.infra.status.im/job/nim-waku/job/deploy-shards-test/) ([soon to be `status.prod`](https://github.com/status-im/infra-shards/issues/33))

- [ ] **Post release**
  - [ ] Submit a PR from the release branch to master. Important to commit the PR with "create a merge commit" option.
  - [ ] Update waku-org/nwaku-compose with the new release version.
