ARG BASE_IMAGE=volcanosh/vc-agent:base-required
FROM ${BASE_IMAGE}
COPY bin/vc-agent /vc-agent
COPY bin/network-qos /usr/local/bin/network-qos
COPY assets/volcano-agent-install.sh /usr/local/bin/install.sh
RUN chmod +x /vc-agent /usr/local/bin/network-qos /usr/local/bin/install.sh \
    && setcap "cap_dac_override=eip" /vc-agent \
    && setcap "cap_dac_override=eip" /usr/local/bin/network-qos
