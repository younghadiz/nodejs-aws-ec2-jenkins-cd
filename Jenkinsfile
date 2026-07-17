#!/usr/bin/env groovy

library(
    identifier: 'jenkins-nodejs-shared-library@main',
    retriever: modernSCM([
        $class: 'GitSCMSource',
        remote: 'https://github.com/younghadiz/jenkins-nodejs-shared-library.git',
        credentialsId: 'github-token'
    ])
)

pipeline {
    agent any

    tools {
        nodejs 'Node24'
    }

    environment {
        APP_DIR = 'app'
        DOCKER_IMAGE_REPOSITORY = 'younghadiz/nodejs-jenkins-cicd'
        GITHUB_REPOSITORY_HOST_PATH = 'github.com/younghadiz/nodejs-jenkins-cicd-pipeline.git'
    } 

    options {
        buildDiscarder(logRotator(
            numToKeepStr: '20',
            artifactNumToKeepStr: '10'
        ))

        disableConcurrentBuilds()
        timestamps()
        timeout(time: 30, unit: 'MINUTES')
    }

    stages {
        stage('Validate Environment') {
            steps {
                sh '''
                    set -eu
                    node --version
                    npm --version
                    docker --version
                    git --version
                '''
            }
        }

        stage('Increment Version') {
            steps {
                script {
                    incrementNpmVersion(
                        env.APP_DIR,
                        'minor'
                    )
                }
            }
        }

        stage('Install Dependencies and Run Tests') {
            steps {
                script {
                    runNodeTests(env.APP_DIR)
                }
            }
        }

        stage('Build and Push Docker Image') {
            steps {
                script {
                    buildAndPushNodeImage(
                        env.DOCKER_IMAGE_REPOSITORY,
                        env.IMAGE_TAG,
                        'dockerhub-creds',
                        '.'
                    )
                }
            }
        }

        stage('Commit Version Update') {
            when {
                anyOf {
                    branch 'develop'
                    branch 'main'
                }
            }

            steps {
                script {
                    commitNpmVersion(
                        env.APP_DIR,
                        'github-token',
                        env.GITHUB_REPOSITORY_HOST_PATH,
                        'Jenkins CI',
                        'jenkins@example.com'
                    )
                }
            }
        }
    }

    post {
        always {
            echo "Pipeline finished with status: ${currentBuild.currentResult}"

            sh '''
                docker logout >/dev/null 2>&1 || true
            '''

            deleteDir()
        }

        success {
            echo "Published ${env.DOCKER_IMAGE_REPOSITORY}:${env.IMAGE_TAG}"
        }

        failure {
            echo 'Pipeline failed. Review the failed stage and console output.'
        }
    }
}