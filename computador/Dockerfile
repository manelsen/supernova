# The agent's computer. Run it with the gVisor runtime (runsc): see
# docs/operations/COMPUTADOR.md. It holds no Supernova secrets.
FROM mcr.microsoft.com/playwright:v1.65.0-noble

# Everyday tools for the shell the agent gets.
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 python3-pip python3-venv git curl jq unzip zip less file \
      ca-certificates locales tzdata tini \
      xvfb x11vnc novnc websockify \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/computador
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force
# The Playwright MCP needs the alpha Playwright it was built with (PRD-S,
# S24); that version's headless Chromium is installed next to the base's.
RUN npx playwright install chromium-headless-shell
COPY agent.mjs mcp.mjs rede.mjs shell.mjs lancador.mjs portao.mjs tela.mjs ./
COPY test ./test

# Two users (PRD-K, K-05, K-07): pwuser (uid 1001, comes with the Playwright
# image) is svc, the service and its browsers; sh (uid 1002) runs the
# shell's commands, with no proxy credential and the person's files
# read-only. The launcher starts as root, with only CHOWN, SETUID, SETGID and
# KILL (given by the dispatcher), and hands everything else to them.
RUN groupadd --gid 1002 sh && useradd --uid 1002 --gid 1002 --no-create-home --shell /bin/bash sh
ENV HOME=/home/pwuser \
    TZ=America/Sao_Paulo \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
# The launcher, root without DAC_OVERRIDE, must be able to walk the home.
RUN mkdir -p /home/pwuser/trabalho /home/pwuser/.navegador /home/pwuser/rascunho /home/pwuser/pessoas \
 && chmod 755 /home/pwuser /home/pwuser/trabalho /home/pwuser/.navegador /home/pwuser/rascunho /home/pwuser/pessoas \
 && chown pwuser:pwuser /home/pwuser /home/pwuser/trabalho /home/pwuser/.navegador /home/pwuser/pessoas \
 && chown sh:sh /home/pwuser/rascunho
WORKDIR /opt/computador

EXPOSE 7070
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:7070/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
# tini as PID 1 reaps background processes the agent leaves behind, so they
# do not pile up as zombies against the pid limit.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "/opt/computador/lancador.mjs"]
