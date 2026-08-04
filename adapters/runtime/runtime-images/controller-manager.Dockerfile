ARG BASE_IMAGE=volcanosh/vc-controller-manager:base-required
FROM ${BASE_IMAGE}
COPY bin/vc-controller-manager /vc-controller-manager
