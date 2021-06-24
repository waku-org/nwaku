pipeline {
  agent { label 'linux' }

  options {
    timestamps()
    /* manage how many builds we keep */
    buildDiscarder(logRotator(
      numToKeepStr: '10',
      daysToKeepStr: '30',
    ))
  }

  /* WARNING: Two more parameters can be defined.
   * See 'environment' section. */
  parameters {
    string(
      name: 'MAKE_TARGET',
      description: 'Makefile target to build. Optional Parameter.',
      defaultValue: params.MAKE_TARGET ?: 'wakunode2',
    )
    string(
      name: 'IMAGE_TAG',
      description: 'Name of Docker tag to push. Optional Parameter.',
      defaultValue: params.IMAGE_TAG ?: 'deploy-v2-test',
    )
    string(
      name: 'IMAGE_NAME',
      description: 'Name of Docker image to push.',
      defaultValue: params.IMAGE_NAME ?: 'statusteam/nim-waku',
    )
    string(
      name: 'NIM_PARAMS',
      description: 'Flags for Nim compilation.',
      defaultValue: params.NIM_PARAMS ?: '-d:disableMarchNative -d:chronicles_colors:none -d:insecure',
    )
  }

  stages {
    stage('Build') {
      steps { script {
        image = docker.build(
          "${params.IMAGE_NAME}:${env.GIT_COMMIT.take(6)}",
          "--build-arg=MAKE_TARGET='${params.MAKE_TARGET}' " +
          "--build-arg=NIM_PARAMS='${params.NIM_PARAMS}' ."
        )
      } }
    }

    stage('Push') {
      steps { script {
        withDockerRegistry([credentialsId: "dockerhub-statusteam-auto", url: ""]) {
          image.push()
          image.push(env.IMAGE_TAG)
        }
      } }
    }
  } // stages
  post {
    always { sh 'docker image prune -f' }
  } // post
} // pipeline
