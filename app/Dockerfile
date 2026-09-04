# Serves the project page from an NGINX image that already runs as a non-root user.
FROM nginxinc/nginx-unprivileged:1.30.4-alpine@sha256:45ce1e2e699234253d1def7baa96218a5d00b498d1ba0cbb1a17b6bdf73d1351

# Replaces the packaged server block so the listening port and probe path are
# declared here. A template rather than a finished config: the entrypoint runs
# envsubst over /etc/nginx/templates and writes the result to conf.d at start,
# which is how the Pod's own facts reach the served page.
COPY default.conf.template /etc/nginx/templates/default.conf.template
COPY index.html /usr/share/nginx/html/index.html

# Sourced before the template is rendered, so RUNTIME_UID is defined in time.
COPY 10-runtime-facts.envsh /docker-entrypoint.d/10-runtime-facts.envsh

# Restricts substitution to this project's variables, so an nginx variable that
# happens to share a name with something in the environment is left alone.
ENV NGINX_ENVSUBST_FILTER="^(POD_|NODE_|IMAGE_|RUNTIME_)"

# Ports below 1024 need a capability the restricted Pod Security standard forbids.
EXPOSE 8080

LABEL org.opencontainers.image.title="k8-lab frontend" \
      org.opencontainers.image.source="https://github.com/sindredg/k8-lab" \
      org.opencontainers.image.licenses="MIT"
