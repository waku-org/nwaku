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

- [ ] Create release branch
- [ ] Assign release candidate tag to the release branch HEAD. e.g. v0.30.0-rc.0
- [ ] Generate and edit releases notes
- [ ] _End user impact_: Summarize impact of changes on Status end users (can be a comment in this issue).
- [ ] **Validate release candidate**

  - [ ] **On Waku fleets**
    - [ ] Lock `waku.test` fleet to release candidate version
    - [ ] Continuously stress `waku.test` fleet for a week (e.g. from `waku-dev`)
    - [ ] Search _Kibana_ logs from the previous month (since last release was deployed), for possible crashes or errors in `waku.test` and `waku.sandbox`.
      - Most relevant logs are `(fleet: "waku.test" OR fleet: "waku.sandbox") AND message: "SIGSEGV"`
    - [ ] Run release candidate with `waku-simulator`, ensure that nodes connected to each other
    - [ ] Unlock `waku.test`

  - [ ] **On Status fleet**
    - [ ] Deploy release candidate to `status.staging`
    - [ ] Perform [sanity check](https://www.notion.so/How-to-test-Nwaku-on-Status-12c6e4b9bf06420ca868bd199129b425)
      - [ ] Connect 2 instances to `status.staging` fleet
      - [ ] Send contact request across and accept
      - [ ] 1:1 Chats with each other
      - [ ] Send and receive messages in a community
      - [ ] Close one instance, send messages with second instance, reopen first instance and confirm messages sent while offline are retrieved from store
    - [ ] Perform checks based _end user impact_
    - [ ] Ask other CCs to point their instance to `status.staging` for a week and use the app as usual.
    - [ ] Ask Status/QA to perform sanity checks (as described above) + checks based on _end user impact_
    - [ ] Get other CCs sign-off: they comment on this PR "used app for a week, no problem", or problem reported, resolved and new RC
    - [ ] Get Status/QA sign-off

- [ ] **Proceed with release**

  - [ ] Assign a release tag to the same commit that contains the validated release-candidate tag
  - [ ] Create GitHub release
  - [ ] Deploy the release to DockerHub
  - [ ] Announce the release
  - [ ] Submit a PR from the release branch to master. Important to commit the PR with "create a merge commit" option.

- [ ] **Promote release to fleets**.
  - [ ] [Deploy final release to `waku.sandbox` fleet](https://ci.infra.status.im/job/nim-waku/job/deploy-waku-sandbox)
  - [ ] Deploy final release to `waku.prod`
  - [ ] Deploy final release to `status.staging`
  - [ ] Deploy final release to `status.test` (soon to be `status.prod`)

post release

    Submit a PR from the release branch to master. Important to commit the PR with "create a merge commit" option.
