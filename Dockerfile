FROM swipl:stable

USER root
WORKDIR /dali2

# CA certificates needed for HTTPS calls (e.g. OpenRouter AI Oracle)
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*

# library(redis) is built into SWI-Prolog >= 8.3 — no pack install needed

# Copy source and web files
COPY src/ src/
COPY web/ web/

# Ensure all files are readable
RUN chmod -R a+r /dali2

# Default port
EXPOSE 8080

# Entry point: swipl loads server.pl, passes port and agent file as args
ENTRYPOINT ["swipl", "-l", "src/server.pl", "-g", "main", "-t", "halt", "--"]
CMD ["8080"]
