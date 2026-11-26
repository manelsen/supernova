FROM mcr.microsoft.com/playwright:v1.65.0-noble
WORKDIR /opt/m
RUN npm init -y >/dev/null && npm i --no-audit --no-fund playwright@1.65.0 >/dev/null
COPY measure.mjs ./
USER pwuser
ENV HOME=/home/pwuser
CMD ["node","/opt/m/measure.mjs"]
