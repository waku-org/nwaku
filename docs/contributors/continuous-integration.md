# Description

This document describes the continuous integration setup for `nim-waku`.

# Details

The CI setup exists on the Status.im Jenkins instance:

https://ci.status.im/job/nim-waku/

It currently consists four jobs:

* [manual](https://ci.status.im/job/nim-waku/job/manual/) - For manually executing builds using parameters.
* [deploy-wakuv1-test](https://ci.status.im/job/nim-waku/job/deploy-wakuv1-test/) - Builds every new commit in `master` and deploys to `wakuv1.test` fleet.
* [deploy-wakuv2-test](https://ci.status.im/job/nim-waku/job/deploy-wakuv2-test/) - Builds every new commit in `master` and deploys to `wakuv2.test` fleet.
* [deploy-wakuv2-prod](https://ci.status.im/job/nim-waku/job/deploy-wakuv2-prod/) - Currently has no automatic trigger, and deploys to `wakuv2.prod` fleet.

# Configuration

The main configuration file is [`Jenkinsfile`](../../Jenkinsfile) at the root of this repo.

Key part is the definition of four `parameters`:

* `MAKE_TARGET` - Which `Makefile` target is built.
* `IMAGE_TAG` - Tag of the Docker image to push.
* `IMAGE_NAME` - Name of the Docker image to push.
* `NIMFLAGS` - Nim compilation parameters.

The use of `?:` [Elvis operator](http://groovy-lang.org/operators.html#_elvis_operator) plays a key role in allowing parameters to be changed for each defined job in Jenkins without it being overridden by the `Jenkinsfile` defaults after every job run.
```groovy
defaultValue: params.IMAGE_TAG ?: 'deploy-wakuv2-test',
```
