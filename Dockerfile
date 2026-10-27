# A pinned wrapper around the OFFICIAL Porkbun MCP connector.
#
# Base images are digest-pinned for reproducibility (see README "Pin evidence").
# The official package ships prebuilt dist/ JS - no build step beyond npm ci.
#
# FROM node:22-alpine@sha256:fe4f6d74e20370acb04ad889077d14d0f64a9c8ea6a42bc60cddf1e844699914

FROM node:22-alpine@sha256:fe4f6d74e20370acb04ad889077d14d0f64a9c8ea6a42bc60cddf1e844699914 AS deps
WORKDIR /app
ENV NPM_CONFIG_UPDATE_NOTIFIER=false
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM node:22-alpine@sha256:fe4f6d74e20370acb04ad889077d14d0f64a9c8ea6a42bc60cddf1e844699914
# loadConfig() builds the Porkbun API User-Agent from npm_package_version;
# set it to the pinned upstream version so calls report porkbun-mcp/0.52.0.
ENV NODE_ENV=production
ENV npm_package_version=0.52.0
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
USER node
EXPOSE 3008
CMD ["node", "/app/node_modules/@porkbunllc/mcp-server/dist/http.js"]