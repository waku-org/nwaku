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
- [ ] create release branch
- [ ] assign release candidate tag
- [ ] validate release candidate
- [ ] generate and edit releases notes
- [ ] open PR and merge release notes to master
- [ ] cherry-pick release notes to the release branch
- [ ] assign release tag to the cherry-picked release notes commit
- [ ] create GitHub release
- [ ] deploy the release to DockerHub
- [ ] deploy release to `wakuv2.prod` fleet
- [ ] announce the release
