ARG BASE_IMAGE=volcanosh/vc-scheduler:base-required
FROM ${BASE_IMAGE}
COPY bin/vc-scheduler /vc-scheduler
