ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# Note: no USER directive needed — the base image runs as root and the
# entrypoint handles privilege dropping via gosu.

# Typst — modern typesetting system
RUN curl -LsSf https://github.com/typst/typst/releases/latest/download/typst-x86_64-unknown-linux-musl.tar.xz \
    | tar -xJ --strip-components=1 -C /usr/local/bin

# Quarto — self-contained tarball install (no apt dependencies)
ARG QUARTO_VERSION=1.8.27
RUN curl -fL "https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-amd64.tar.gz" \
    | tar -xz -C /opt \
    && ln -s /opt/quarto-${QUARTO_VERSION}/bin/quarto /usr/local/bin/quarto
