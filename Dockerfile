# Native HashiCorp Vault integration is built into the Datadog Agent (7.70+).
# Pin the Agent so the behavior tested here is reproducible.
FROM datadog/agent:7.85.0

# startup.sh uses curl. The Vault container uses wget instead.
RUN apt-get update && apt-get install -y --no-install-recommends curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /scripts
COPY scripts/startup.sh /scripts/
RUN chmod +x /scripts/startup.sh

COPY datadog.yaml /etc/datadog-agent/
COPY conf.d/ /etc/datadog-agent/conf.d/

ENV VAULT_ADDR=http://vault:8200

ENTRYPOINT ["/scripts/startup.sh"]
CMD ["agent", "run"]
