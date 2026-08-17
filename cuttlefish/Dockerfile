# AAOS Cuttlefish with Child Present Detection APK pre-installed at boot.
#
# Build (APK must already exist at cuttlefish/apks/ChildPresentDetection.apk):
#   docker build -t cpd-cuttlefish:latest -f cuttlefish/Dockerfile .
#
# Or via CI / scripts/build-images.sh (builds APK first).

ARG BASE_IMAGE=remotivelabs/remotivelabs-cuttlefish:15.0.0-4
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="cpd-cuttlefish" \
      org.opencontainers.image.description="AAOS Cuttlefish with Child Present Detection HMI" \
      org.opencontainers.image.source="https://github.com/MinhTuan76800310/remotive_cuttlefish_cpd"

# Boot script installs APKs from /root/apks and launches com.emtek.cpd
COPY cuttlefish/init.sh /root/init.sh
RUN chmod +x /root/init.sh

# Pre-bake the CPD APK so the image is self-contained (no host bind-mount required)
COPY cuttlefish/apks/ /root/apks/

ENV CPD_PACKAGE=com.emtek.cpd \
    CPD_ACTIVITY=.MainActivity

# Base image ENTRYPOINT is already /root/init.sh
