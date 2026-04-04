# 不使用 # syntax=docker/dockerfile:1，避免 BuildKit 从 Docker Hub 拉取 dockerfile 前端（国内常超时）。
# SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
# SPDX-License-Identifier: Apache-2.0

################################################################################
ARG BUILDPLATFORM
# 构建阶段基础镜像可覆盖（国内可设 docker.m.daocloud.io/library/golang:1.26 或 Harbor 同步后的地址）
ARG GO_BUILDER_IMAGE=golang:1.26
FROM --platform=${BUILDPLATFORM} ${GO_BUILDER_IMAGE} AS builder
ARG TARGETOS
ARG TARGETARCH

WORKDIR /workspace

# Go modules / checksum DB: honor proxy build-args (BuildKit does not always inject these into RUN).
# 默认可在国内网络使用；海外构建可传 --build-arg GOPROXY=https://proxy.golang.org,direct
ARG GOPROXY=https://goproxy.cn,direct
ENV GOPROXY=${GOPROXY}
ARG GOSUMDB=sum.golang.google.cn
ENV GOSUMDB=${GOSUMDB}

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ENV HTTP_PROXY=${HTTP_PROXY} HTTPS_PROXY=${HTTPS_PROXY} NO_PROXY=${NO_PROXY}

# Prefer IPv4 when dialing; avoids hangs on broken IPv6 routes to public module proxies.
ENV GODEBUG=netpreferipv4=1

# Copy the Go Modules manifests
COPY go.mod go.sum ./
# cache deps before building and copying source so that we don't need to re-download as much
# and so that source changes don't invalidate our downloaded layer
RUN go mod download

# Copy the go source
COPY . .

# Build
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} go build -o /workspace/bin/ ./...

################################################################################

# 不用 gcr.io/distroless（国内/内网常连不上）；与 distroless nonroot 一样用 UID 65532，CA 从 golang 镜像复制以便访问 K8s API HTTPS。
FROM scratch AS manager
WORKDIR /
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /workspace/bin/manager /manager
USER 65532:65532
ENTRYPOINT ["/manager"]

################################################################################

FROM scratch AS webhook
WORKDIR /
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /workspace/bin/webhook /webhook
USER 65532:65532
ENTRYPOINT ["/webhook"]
