# syntax=docker/dockerfile:1

FROM node:24-alpine

LABEL org.opencontainers.image.title="Node.js Jenkins CI/CD Demo"
LABEL org.opencontainers.image.description="Developer project directory application built through Jenkins"
LABEL org.opencontainers.image.source="https://github.com/younghadiz/nodejs-jenkins-cicd-pipeline"

ENV NODE_ENV=production

WORKDIR /usr/src/app

# Copy dependency manifests separately to improve Docker layer caching.
COPY app/package.json app/package-lock.json ./

# Install exact locked dependencies and omit development packages.
# Jest is currently listed under dependencies in the source project, so
# production installation still succeeds. In a later enhancement, move Jest
# to devDependencies and run tests before the production image build.
RUN npm ci --omit=dev && npm cache clean --force

# Copy application files only after dependencies are installed.
COPY app/ ./

EXPOSE 3000

# Run as the non-root user already provided by the official Node image.
USER node

CMD ["node", "server.js"]