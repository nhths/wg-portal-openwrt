# Builder image for building wg-portal from source.
#
#   docker build -f Dockerfile.builder -t wg-portal-builder:local <srcdir>
ARG NODE_IMAGE=node:lts-alpine
ARG GO_IMAGE=golang:1.26-alpine

FROM ${NODE_IMAGE} AS frontend
WORKDIR /build
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci
ENV DIST_OUT_DIR=dist
COPY frontend .
RUN npm run build

FROM ${GO_IMAGE} AS builder
WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
COPY --from=frontend /build/dist/ ./internal/app/api/core/frontend-dist/
ENV CGO_ENABLED=0 GOOS=linux GOARCH=arm64
ENV GOCACHE=/root/.cache/go-build
CMD ["sh", "-c", "echo 'override with a build command'"]
