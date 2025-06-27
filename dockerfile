FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# --- 0. Set root user ---
USER root



FROM ubuntu:24.04

# Set Environment Variables
ENV PATH=/usr/local/ssl/bin:$PREFIX/bin:/opt/software/slurm/sbin:${PATH:-}
ENV LD_LIBRARY_PATH=/usr/local/ssl/lib:${LD_LIBRARY_PATH:-}
ENV DEBIAN_FRONTEND=noninteractive
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility
ENV KERNEL_VERSION=6.8.0-59-generic
#ENV NVIDIA_DRIVER_VERSION=570.133.07
ENV NVIDIA_DRIVER_VERSION=570.133.20

# Temporarily disable service configuration
RUN echo '#!/bin/sh\nexit 101' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d

# Install System Dependencies and Upgrade
RUN apt-get update && apt-get install -y \
    # Core Utilities
    wget \
    curl \
    unzip \
    locales \
    ansible \
    net-tools \
    openssh-server \
    openssh-client \
    iproute2 \
    initramfs-tools \
    gnupg \
    procps \
    util-linux \
    lsb-release \
    ca-certificates \
    tzdata \
    systemd \
    openmpi-bin \
    kmod \
    numactl \
    sysstat \
    apt-utils \
    systemd-sysv \
    dbus \
    pciutils \
    netbase \
    cmake \
    libhwloc15 \
    libtool \
    zlib1g-dev \
    liblua5.3-0 \
    libnuma1 \
    libpam0g \
    librrd8 \
    libyaml-0-2 \
    libjson-c5 \
    libhttp-parser2.9 \
    libev4 \
    libssl3 \
    libcurl4 \
    libbpf1 \
    libdbus-1-3 \
    libfreeipmi17 \
    libibumad3 \
    libibmad5 \
    gettext \
    autoconf \
    automake \
    sudo \
    gcc \
    make \
    libmunge2 \
    libpmix-bin \
    rrdtool \
    lua5.3 \
    dkms \
    # Used by warewulf to partition disks (cvmfs cache, localscratch) \
    ignition \
    # Used by warewulf to parititon disks \
    gdisk \
    # To mount home directories from storage \
    nfs-common \
    # Build dependencies for NVIDIA driver. Keep these here. \
    linux-image-${KERNEL_VERSION} \
    linux-headers-${KERNEL_VERSION} \
    linux-modules-${KERNEL_VERSION} \
    linux-modules-extra-${KERNEL_VERSION} \
    build-essential \
    pkg-config \
    xorg-dev \
    libx11-dev \
    libxext-dev \
    libglvnd-dev && \
    ln -s /usr/src/linux-headers-${KERNEL_VERSION} /lib/modules/${KERNEL_VERSION}/build

# Create build directory
# Download the NVIDIA driver
# Old Line: https://us.download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_DRIVER_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run -O /tmp/NVIDIA.run && \
RUN mkdir /slurm-debs && mkdir -p /build && cd /build && \
    echo "📥 Downloading NVIDIA driver ${NVIDIA_DRIVER_VERSION}..." && \
    wget -q https://us.download.nvidia.com/tesla/${NVIDIA_DRIVER_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run -O /tmp/NVIDIA.run && \
    echo "📦 Extracting driver..." && \
    chmod +x /tmp/NVIDIA.run && \
    /tmp/NVIDIA.run --extract-only --target /build/nvidia && \
    cd /build/nvidia

# Create fake systemctl for environments without systemd
RUN mkdir -p /tmp/bin && \
    cp /usr/bin/systemctl /usr/bin/systemctl.bak && \
    echo '#!/bin/sh\nexit 0' > /tmp/bin/systemctl && \
    chmod +x /tmp/bin/systemctl && \
    ln -sf /tmp/bin/systemctl /usr/bin/systemctl

# Full installation with kernel modules
RUN cd /build/nvidia && chmod +x /tmp/bin/systemctl && \
    export PATH="/tmp/bin:$PATH" && \
    ./nvidia-installer --accept-license \
                       --no-questions \
                       --silent \
                       --no-backup \
                       --no-x-check \
                       --no-nouveau-check \
                       --no-systemd \
                       --no-check-for-alternate-installs \
                       --kernel-name=${KERNEL_VERSION} \
                       --kernel-source-path=/lib/modules/${KERNEL_VERSION}/build \
                       --x-prefix=/usr \
                       --x-module-path=/usr/lib/xorg/modules \
                       --x-library-path=/usr/lib 

# Create module configuration to load at boot
# Setup CUDA-specific UVM device nodes
RUN mkdir -p /etc/modules-load.d/ && \
    echo "nvidia" > /etc/modules-load.d/nvidia.conf && \
    echo "nvidia_uvm" >> /etc/modules-load.d/nvidia.conf && \
    echo "nvidia_drm" >> /etc/modules-load.d/nvidia.conf && \
    echo "nvidia_modeset" >> /etc/modules-load.d/nvidia.conf

# Create NVIDIA device nodes (if they don't exist)
RUN mkdir -p /dev/nvidia && \
    [ -e /dev/nvidia0 ] || mknod -m 666 /dev/nvidia0 c 195 0 && \
    [ -e /dev/nvidiactl ] || mknod -m 666 /dev/nvidiactl c 195 255 && \
    [ -e /dev/nvidia-uvm ] || mknod -m 666 /dev/nvidia-uvm c 243 0 && \
    [ -e /dev/nvidia-uvm-tools ] || mknod -m 666 /dev/nvidia-uvm-tools c 243 1

# Remove fake systemctl after use
RUN rm -f /usr/bin/systemctl && \
    rm -rf /tmp/bin && \
    cp /usr/bin/systemctl.bak /usr/bin/systemctl
    
# Optional: Persist the kernel modules into the initramfs
RUN update-initramfs -u -k ${KERNEL_VERSION}

# Copy Slurm Deb files into the container
COPY *.deb /slurm-debs/

RUN chmod +x /usr/local/sbin/firstboot.sh && \
    mkdir -p /etc/systemd/system/multi-user.target.wants && \
    ln -s /etc/systemd/system/firstboot.service /etc/systemd/system/multi-user.target.wants/firstboot.service || true

# Enable root autologin on tty1
RUN mkdir -p /etc/systemd/system/getty@tty1.service.d && \
    echo '[Service]' > /etc/systemd/system/getty@tty1.service.d/override.conf && \
    echo 'ExecStart=' >> /etc/systemd/system/getty@tty1.service.d/override.conf && \
    echo 'ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM' >> /etc/systemd/system/getty@tty1.service.d/override.conf

# Clean Up
RUN apt-get purge -y \
    build-essential \
    cmake \
    libtool \
    zlib1g-dev \
    liblua5.3-0 \
    pkg-config \
    xorg-dev \
    libx11-dev \
    libxext-dev \
    libglvnd-dev \
    gcc \
    make \
    autoconf \
    automake 
    
RUN apt-get autoremove -y && \
    apt-get clean && \
    apt-get install -y openscap-scanner netplan.io && \
    rm -rf /usr/src/* /var/lib/apt/lists/* /tmp/* \
           /var/tmp/* /var/log/* /usr/share/doc /usr/share/man \
           /usr/share/locale /usr/share/info && \
    rm /usr/sbin/policy-rc.d && \
    mkdir -p /local/home && \
    groupadd -r slurm && \
    useradd -r -g slurm -s /bin/false slurm && \
    groupadd wwgroup && \
    useradd -m -d /local/home/wwuser -g slurm -s /bin/bash wwuser && \
    echo "wwuser:wwpassword" | chpasswd && \
    usermod -aG sudo wwuser

# Fetch the latest SCAP Security Guide
RUN export SSG_VERSION=$(curl -s https://api.github.com/repos/ComplianceAsCode/content/releases/latest | grep -oP '"tag_name": "\K[^"]+' || echo "0.1.66") && \
    echo "🔄 Using SCAP Security Guide version: $SSG_VERSION" && \
    SSG_VERSION_NO_V=$(echo "$SSG_VERSION" | sed 's/^v//') && \
    echo "🔄 Stripped Version: $SSG_VERSION_NO_V" && \
    wget -O /ssg.zip "https://github.com/ComplianceAsCode/content/releases/download/${SSG_VERSION}/scap-security-guide-${SSG_VERSION_NO_V}.zip" && \
    mkdir -p /usr/share/xml/scap/ssg/content && \
    if [ -f "/ssg.zip" ]; then \
        unzip -jo /ssg.zip "scap-security-guide-${SSG_VERSION_NO_V}/*" -d /usr/share/xml/scap/ssg/content/ && \
        rm -f /ssg.zip; \
    else \
        echo "❌ Failed to download SCAP Security Guide"; exit 1; \
    fi

# Add OpenSCAP Scripts
COPY openscap_scan.sh /openscap_scan.sh
COPY openscap_remediate.sh /openscap_remediate.sh

# Make scripts executable
RUN chmod +x /openscap_scan.sh /openscap_remediate.sh \
    && rm -rf /NVIDIA-Linux* \
    && rm -rf /usr/src/* \
    && mkdir -p /etc/redfish_exporter/
