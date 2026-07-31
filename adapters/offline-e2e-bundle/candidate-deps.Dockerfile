ARG BASE_RUNNER=volcano-offline-runner:base-required
FROM ${BASE_RUNNER}

ARG CANDIDATE_COMMIT
COPY go-mod-supplement.tar.gz /tmp/go-mod-supplement.tar.gz
RUN test -n "${CANDIDATE_COMMIT}" \
    && tar -xzf /tmp/go-mod-supplement.tar.gz -C /go/pkg/mod \
    && rm -f /tmp/go-mod-supplement.tar.gz

LABEL io.volcano.performance-guard.candidate.commit="${CANDIDATE_COMMIT}" \
      io.volcano.performance-guard.asset="go-module-supplement"

ENV GOPROXY=off \
    GOSUMDB=off \
    GOTOOLCHAIN=local \
    GOFLAGS=-mod=readonly

WORKDIR /workspace/volcano
