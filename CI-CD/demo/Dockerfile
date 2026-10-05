FROM node:22-alpine

WORKDIR /app
COPY package.json app.js ./

# The pipeline passes the commit ID in, so the running app knows its version
ARG GIT_SHA=dev
ENV GIT_SHA=$GIT_SHA \
    NODE_ENV=production

USER node
EXPOSE 3000
CMD ["node", "app.js"]
