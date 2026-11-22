# The agent's computer. Run it with the gVisor runtime (runsc): see
# docs/operations/COMPUTADOR.md. It holds no Supernova secrets.
FROM mcr.microsoft.com/playwright:v1.48.0-jammy

# Everyday tools for the shell the agent gets.
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 python3-pip python3-venv git curl jq unzip zip less file \
      ca-certificates locales tzdata \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/computador
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force
COPY agent.mjs ./
COPY test ./test

# pwuser comes with the Playwright image; its home is the persistent volume.
USER pwuser
ENV HOME=/home/pwuser \
    TZ=America/Sao_Paulo \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN mkdir -p /home/pwuser/trabalho /home/pwuser/.navegador
WORKDIR /home/pwuser/trabalho

EXPOSE 7070
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:7070/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "/opt/computador/agent.mjs"]
