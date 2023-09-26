def discordNotify(Map args=[:]) {
  def opts = [
    header: args.header ?: 'Deployment successful!',
    cred: args.cred ?: null,
  ]
  def repo = [
    url: GIT_URL.minus('.git'),
    branch: GIT_BRANCH.minus('origin/'),
    commit: GIT_COMMIT.take(8),
    prev: (
      env.GIT_PREVIOUS_SUCCESSFUL_COMMIT ?: env.GIT_PREVIOUS_COMMIT ?: 'master'
    ).take(8),
  ]
  wrap([$class: 'BuildUser']) {
    BUILD_USER_ID = env.BUILD_USER_ID
  }
  withCredentials([
    string(
      credentialsId: opts.cred,
      variable: 'DISCORD_WEBHOOK',
    ),
  ]) {
    discordSend(
      link: env.BUILD_URL,
      result: currentBuild.currentResult,
      webhookURL: env.DISCORD_WEBHOOK,
      title: "${env.JOB_NAME}#${env.BUILD_NUMBER}",
      description: """
        ${opts.header}
        Image: [`${IMAGE_NAME}:${IMAGE_TAG}`](https://hub.docker.com/r/${IMAGE_NAME}/tags?name=${IMAGE_TAG})
        Branch: [`${repo.branch}`](${repo.url}/commits/${repo.branch})
        Commit: [`${repo.commit}`](${repo.url}/commit/${repo.commit})
        Diff: [`${repo.prev}...${repo.commit}`](${repo.url}/compare/${repo.prev}...${repo.commit})
        By: [`${BUILD_USER_ID}`](${repo.url}/commits?author=${BUILD_USER_ID})
      """,
    )
  }
}

return this
