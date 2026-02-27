ARG BASE_IMAGE
FROM ${BASE_IMAGE}

USER root

# Typst — modern typesetting system
RUN curl -LsSf https://github.com/typst/typst/releases/latest/download/typst-x86_64-unknown-linux-musl.tar.xz \
    | tar -xJ --strip-components=1 -C /usr/local/bin

# Quarto — scientific publishing system
RUN curl -LO https://github.com/quarto-dev/quarto-cli/releases/download/v1.7.29/quarto-1.7.29-linux-amd64.deb \
    && dpkg -i quarto-*.deb && rm quarto-*.deb

USER claude
