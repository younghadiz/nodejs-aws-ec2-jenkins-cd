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

        DOCKER_IMAGE_REPOSITORY =
            'younghadiz/nodejs-jenkins-cicd'

        GITHUB_REPOSITORY_HOST_PATH =
            'github.com/younghadiz/nodejs-aws-ec2-jenkins-cd.git'
    }

    options {
        buildDiscarder(
            logRotator(
                numToKeepStr: '20',
                artifactNumToKeepStr: '10'
            )
        )

        disableConcurrentBuilds()

        timestamps()

        timeout(
            time: 30,
            unit: 'MINUTES'
        )
    }

    stages {
        stage('Validate Environment') {
            steps {
                sh '''
                    set -eu

                    echo "Branch: ${BRANCH_NAME}"
                    echo "Node:"
                    node --version

                    echo "npm:"
                    npm --version

                    echo "Docker:"
                    docker --version

                    echo "Docker Compose:"
                    docker compose version

                    echo "Git:"
                    git --version

                    echo "SSH:"
                    ssh -V
                '''
            }
        }

        /*
         * Tests run on every branch.
         *
         * This is the quality gate for feature, bugfix, develop, and main.
         * No version increment is performed before feature-branch testing.
         */
        stage('Install Dependencies and Run Tests') {
            steps {
                script {
                    runNodeTests(env.APP_DIR)
                }
            }
        }

        /*
         * Everything below this point is production-main only.
         */
        stage('Increment Version') {
            when {
                branch 'main'
            }

            steps {
                script {
                    incrementNpmVersion(
                        env.APP_DIR,
                        'minor'
                    )
                }
            }
        }

        stage('Build and Push Docker Image') {
            when {
                branch 'main'
            }

            steps {
                script {
                    buildAndPushNodeImage(
                        env.DOCKER_IMAGE_REPOSITORY,
                        env.IMAGE_TAG,
                        'docker-credentials',
                        '.'
                    )
                }
            }
        }

        stage('Deploy to Amazon EC2') {
            when {
                branch 'main'
            }

            steps {
                withCredentials([
                    string(
                        credentialsId: 'ec2-server-host',
                        variable: 'EC2_HOST'
                    )
                ]) {
                    script {
                        deployNodeAppToEc2(
                            env.DOCKER_IMAGE_REPOSITORY,
                            env.IMAGE_TAG,
                            env.EC2_HOST,
                            'ec2-server-key',
                            'ec2-user',
                            '/opt/nodejs-aws-jenkins',
                            'deploy/docker-compose.yaml',
                            'deploy/server-commands.sh'
                        )
                    }
                }
            }
        }

        stage('Verify Deployment') {
            when {
                branch 'main'
            }

            steps {
                withCredentials([
                    string(
                        credentialsId: 'ec2-server-host',
                        variable: 'EC2_HOST'
                    )
                ]) {
                    sh '''
                        set -eu

                        response_code="$(
                          curl \
                            --silent \
                            --output /dev/null \
                            --write-out '%{http_code}' \
                            --retry 10 \
                            --retry-delay 3 \
                            --retry-connrefused \
                            "http://${EC2_HOST}:3000"
                        )"

                        echo "Application HTTP status: ${response_code}"

                        test "${response_code}" = "200"
                    '''
                }
            }
        }

        /*
         * Commit only after the image is published and deployment succeeds.
         */
        stage('Commit Version Update') {
            when {
                branch 'main'
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
            echo "Pipeline status: ${currentBuild.currentResult}"

            sh '''
                docker logout >/dev/null 2>&1 || true
            '''

            deleteDir()
        }

        success {
            script {
                if (env.BRANCH_NAME == 'main') {
                    echo(
                        "Production deployment completed: " +
                        "${env.DOCKER_IMAGE_REPOSITORY}:${env.IMAGE_TAG}"
                    )
                } else {
                    echo(
                        "Tests completed successfully for branch " +
                        "${env.BRANCH_NAME}. Deployment was intentionally skipped."
                    )
                }
            }
        }

        failure {
            echo(
                'Pipeline failed. Review the failed stage and console output.'
            )
        }
    }
}