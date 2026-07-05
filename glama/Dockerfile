# Directory-inspection shim for the Glama MCP registry (https://glama.ai).
#
# Beckett itself is a zero-sidecar MCP server embedded in the Godot 4 editor;
# there is no standalone process to install. This tiny stdio server exists ONLY
# so Glama can build a container, speak MCP over stdio, run the tools/list
# introspection, and grade tool-definition quality + server coherence. It ships
# no product code - just the (already public) tool schemas in tools.json.
#
# Pure Node standard library: nothing to `npm install`.
FROM node:20-alpine
WORKDIR /app
COPY package.json server.js tools.json ./
ENTRYPOINT ["node", "server.js"]
