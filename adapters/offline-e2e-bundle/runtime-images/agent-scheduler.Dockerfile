ARG BASE_IMAGE=volcanosh/vc-agent-scheduler:base-required
FROM ${BASE_IMAGE}
COPY bin/vc-agent-scheduler /vc-agent-scheduler
