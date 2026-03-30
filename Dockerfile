# syntax=docker/dockerfile:1
# SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
# SPDX-License-Identifier: Apache-2.0

################################################################################
ARG BUILDPLATFORM

FROM --platform=${BUILDPLATFORM} golang:1.26 AS builder
ARG TARGETOS
ARG TARGETARCH

WORKDIR /workspace

# Go modules / checksum DB: honor proxy build-args (BuildKit does not always inject these into RUN).
# GOPROXY can be overridden (e.g. https://goproxy.cn,direct) when proxy.golang.org is slow or unreachable.
ARG GOPROXY=https://proxy.golang.org,direct
ENV GOPROXY=${GOPROXY}
ARG GOSUMDB=sum.golang.org
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

# Ref: https://github.com/GoogleContainerTools/distroless
FROM gcr.io/distroless/static:nonroot AS manager
WORKDIR /
COPY --from=builder /workspace/bin/manager .
USER 65532:65532
ENTRYPOINT ["/manager"]

################################################################################

# Ref: https://github.com/GoogleContainerTools/distroless
FROM gcr.io/distroless/static:nonroot AS webhook
WORKDIR /
COPY --from=builder /workspace/bin/webhook .
USER 65532:65532
ENTRYPOINT ["/webhook"]
