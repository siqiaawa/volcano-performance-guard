ARG BASE_IMAGE=volcanosh/vc-webhook-manager:base-required
FROM ${BASE_IMAGE}
COPY bin/vc-webhook-manager /vc-webhook-manager
COPY assets/gen-admission-secret.sh /gen-admission-secret.sh
RUN chmod +x /gen-admission-secret.sh
