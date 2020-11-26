pipeline {
  agent { label 'linux' }

  parameters {
    string(
      name: 'BRANCH',
      defaultValue: 'master',
      description: 'Name of branch to build.'
    )
    string(
      name: 'IMAGE_TAG',
      defaultValue: 'wakunode2',
      description: 'Name of Docker tag to push.'
    )
    string(
      name: 'IMAGE_NAME',
      defaultValue: 'statusteam/nim-waku',
      description: 'Name of Docker image to push.'
    )
    string(
      name: 'NIM_PARAMS',
      defaultValue: '-d:disableMarchNative -d:chronicles_colors:none -d:insecure',
      description: 'Flags for Nim compilation.'
    )
  }

  options {
    timestamps()
    /* manage how many builds we keep */
    buildDiscarder(logRotator(
      numToKeepStr: '10',
      daysToKeepStr: '30',
    ))
  }

  stages {
    stage('Build') {
      steps { script {
        image = docker.build(
          "${params.IMAGE_NAME}:${env.GIT_COMMIT.take(6)}",
          "--build-arg=MAKE_TARGET='${params.IMAGE_TAG}' " +
          "--build-arg=NIM_PARAMS='${params.NIM_PARAMS}' ."
        )
      } }
    }

    stage('Push') {
      steps { script {
        withDockerRegistry([credentialsId: "dockerhub-statusteam-auto", url: ""]) {
          image.push()
        }
        withDockerRegistry([credentialsId: "dockerhub-statusteam-auto", url: ""]) {
          image.push(params.IMAGE_TAG)
        }
      } }
    }
  } // stages
  post {
    always { sh 'docker image prune -f' }
  } // post
} // pipeline
