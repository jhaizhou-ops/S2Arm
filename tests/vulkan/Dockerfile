# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Official Microsoft SDK 10.0.403 noble multi-architecture manifest, verified
# against mcr.microsoft.com; apt packages come from one signed Ubuntu snapshot.
FROM --platform=linux/amd64 mcr.microsoft.com/dotnet/sdk:10.0.403-noble@sha256:de4fe90a98845d75910b9769662465c84de1a934665c431279d1382b2bddc02b
ARG APT_SNAPSHOT=20261030T000000Z
RUN apt-get update --snapshot "$APT_SNAPSHOT" \
 && apt-get install -y --no-install-recommends --snapshot "$APT_SNAPSHOT" \
      python3 git build-essential libvulkan-dev mesa-vulkan-drivers \
      vulkan-validationlayers vulkan-tools glslc spirv-tools \
 && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh result.sh /opt/s2arm-vulkan/
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 \
    DOTNET_NOLOGO=1 LP_NUM_THREADS=1 HOME=/tmp/s2arm-home \
    XDG_CACHE_HOME=/tmp/s2arm-cache XDG_RUNTIME_DIR=/tmp/s2arm-runtime
WORKDIR /src
ENTRYPOINT ["bash", "/opt/s2arm-vulkan/entrypoint.sh"]
