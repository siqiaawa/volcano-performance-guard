ARG BASE_RUNNER_IMAGE=volcano-candidate-runner:d57d10f47129b11f12d875de1195a42c0a53270f

FROM ${BASE_RUNNER_IMAGE} AS runner-tools
FROM golang:1.26.2

ARG CANDIDATE_COMMIT
ARG TOOLS_VERSION=performance-guard-tools-v1

LABEL org.opencontainers.image.title="Volcano Performance Guard Tools" \
      org.opencontainers.image.version="${TOOLS_VERSION}" \
      io.volcano.performance-guard.candidate.commit="${CANDIDATE_COMMIT}" \
      io.volcano.performance-guard.tools.version="${TOOLS_VERSION}"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

COPY tools/requirements.txt /opt/performance-guard/requirements.txt
COPY tools/vendor /opt/performance-guard/vendor
COPY --from=runner-tools /usr/local/bin/docker-real /usr/local/bin/docker

ENV PYTHONPATH=/opt/performance-guard/vendor

WORKDIR /workspace/project
CMD ["bash"]
