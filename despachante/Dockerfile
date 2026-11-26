# The dispatcher (PRD-K, K20): the only container with the Docker socket.
# No dependencies beyond Node itself. Pinned by digest (24.13.0-alpine3.23).
FROM node:24.13.0-alpine3.23@sha256:cd6fb7efa6490f039f3471a189214d5f548c11df1ff9e5b181aa49e22c14383e

WORKDIR /opt/despachante
COPY package.json docker.mjs despachante.mjs ./
COPY test ./test

EXPOSE 7071
CMD ["node", "/opt/despachante/despachante.mjs"]
