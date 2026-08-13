# syntax=docker/dockerfile:1

# One recipe for both variants.  BASE_IMAGE is the only thing that differs
# between the bioconductor and bioc2u images; the install path is identical.
ARG BASE_IMAGE=ghcr.io/bioconductor/bioconductor:devel
FROM ${BASE_IMAGE}

ARG PACKAGE
ARG PACKAGE_VERSION
ARG BIOC_BRANCH
ARG VARIANT
ARG BASE_IMAGE
# STRICT=0 publishes the image even if some packages fail to install.
ARG STRICT=1
ARG NCPUS

LABEL org.opencontainers.image.source="https://github.com/almahmoud/biocpkgcontainers" \
      org.opencontainers.image.description="${PACKAGE} ${PACKAGE_VERSION} with its full Depends/Imports/LinkingTo/Suggests closure, on ${BASE_IMAGE}" \
      org.opencontainers.image.licenses="Artistic-2.0" \
      org.bioconductor.package="${PACKAGE}" \
      org.bioconductor.package.version="${PACKAGE_VERSION}" \
      org.bioconductor.branch="${BIOC_BRANCH}" \
      org.bioconductor.variant="${VARIANT}" \
      org.bioconductor.base-image="${BASE_IMAGE}"

ENV PACKAGE=${PACKAGE} \
    STRICT=${STRICT} \
    NCPUS=${NCPUS} \
    REPORT_DIR=/usr/local/share/biocpkgcontainers

COPY install.R /tmp/install.R
COPY pkgs.txt /tmp/pkgs.txt

RUN Rscript /tmp/install.R /tmp/pkgs.txt \
    && cp /tmp/pkgs.txt "${REPORT_DIR}/requested.txt" \
    && rm -rf /tmp/install.R /tmp/pkgs.txt /tmp/Rtmp* /tmp/downloaded_packages \
       /var/lib/apt/lists/* /root/.cache
