FROM scratch

ARG CANDIDATE_COMMIT
COPY --chmod=0755 kube-apiserver-audit-exporter /kube-apiserver-audit-exporter

LABEL io.volcano.performance-guard.asset="candidate-audit-exporter" \
      io.volcano.performance-guard.candidate.commit="${CANDIDATE_COMMIT}"

ENTRYPOINT ["/kube-apiserver-audit-exporter"]
