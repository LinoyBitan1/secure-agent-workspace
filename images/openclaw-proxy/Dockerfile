FROM quay.io/redhat-et/openclaw:csb-aipcc-based-amd64-2026.08.19

USER root
COPY gog /usr/local/bin/gog
RUN chmod +x /usr/local/bin/gog
USER 1001

ENV GOG_READONLY=1
