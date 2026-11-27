# The computers' only way out (PRD-K, K-05). No Docker socket, no
# dependencies beyond Node. Pinned by digest (24.13.0-alpine3.23).
FROM node:24.13.0-alpine3.23@sha256:cd6fb7efa6490f039f3471a189214d5f548c11df1ff9e5b181aa49e22c14383e

WORKDIR /opt/saida
COPY package.json rede.mjs saida.mjs ./
COPY test ./test
USER node
EXPOSE 3128 7072
CMD ["node", "/opt/saida/saida.mjs"]
