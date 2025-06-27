FROM ubuntu:24.04

# Set noninteractive frontend
ENV DEBIAN_FRONTEND=noninteractive

# Define build arguments from GitHub Actions workflow
ARG SLURM_VERSION
ARG KERNEL_VERSION
ARG DISABLE_AUTOLOGIN
ARG NVIDIA_INSTALL_ENABLED
ARG NVIDIA_DRIVER_URL
ARG FIRSTBOOT_ENABLED

# --- 0. Set root user ---
USER root

# --- 2. Set root and user accounts ---
RUN echo "root:changeme" | chpasswd && \
    groupadd -r -g 999 slurm && \
    useradd -r -u 999 -g slurm -s /bin/false slurm && \
    groupadd -g 998 wwgroup && \
    useradd -m -u 998 -d /local/home/wwuser -g wwgroup -s /bin/bash wwuser && \
    echo "wwuser:wwpassword" | chpasswd && \
    usermod -aG sudo wwuser

# --- 1. Install Core Tools, Debugging, and Dependencies ---
RUN apt-get update && apt-get install -y \
    sudo \
    openssh-server \
    openssh-client \
    net-tools \
    iproute2 \
    pciutils \
    lvm2 \
    nfs-common \
    multipath-tools \
    ifupdown \
    rsync \
    curl \
    wget \
    vim \
    tmux \
    less \
    htop \
    sysstat \
    cron \
    ipmitool \
    smartmontools \
    lm-sensors \
    python3 \
    python3-pip \
    netplan.io \
    unzip \
    gnupg \
    ansible \
    systemd \
    systemd-sysv \
    dbus \
    initramfs-tools \
    openscap-scanner \
    libopenscap25t64 \
    openscap-common \
    socat \
    conntrack \
    ebtables \
    ethtool \
    ipset \
    iptables \
    chrony \
    tcpdump \
    strace \
    lsof \
    jq \
    git \
    iputils-ping \
    lsb-release \
    bash-completion \
    open-iscsi \
    bpfcc-tools \
    cgroup-tools \
    auditd \
    apt-transport-https \
    software-properties-common \
    gnupg-agent \
    ignition \
    gdisk \
    rsyslog \
    logrotate \
    systemd-journal-remote \
    ca-certificates \
    openmpi-bin \
    kmod \
    numactl \
    apt-utils \
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
    gcc \
    make \
    libmunge2 \
    libpmix-bin \
    rrdtool \
    lua5.3 \
    dkms && \
    apt-get clean && \
    mkdir -p /var/log/journal && \
    systemd-tmpfiles --create --prefix /var/log/journal && \
    rm -rf /var/lib/apt/lists/*

# Install specific kernel if provided, otherwise use generic
RUN if [ "$KERNEL_VERSION" != "latest" ]; then \
        apt-get update && apt-get install -y \
            linux-image-${KERNEL_VERSION} \
            linux-headers-${KERNEL_VERSION} \
            linux-modules-${KERNEL_VERSION} \
            linux-modules-extra-${KERNEL_VERSION} && \
        ln -s /usr/src/linux-headers-${KERNEL_VERSION} /lib/modules/${KERNEL_VERSION}/build && \
        apt-get clean && rm -rf /var/lib/apt/lists/*; \
    else \
        apt-get update && apt-get install -y \
            linux-image-generic \
            linux-headers-generic && \
        apt-get clean && rm -rf /var/lib/apt/lists/*; \
    fi

# --- 3. Temporarily disable service configuration ---
RUN echo '#!/bin/sh\nexit 101' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d

# --- 4. Create fake systemctl for environments without systemd ---
RUN mkdir -p /tmp/bin && \
    cp /usr/bin/systemctl /usr/bin/systemctl.bak && \
    echo '#!/bin/sh\nexit 0' > /tmp/bin/systemctl && \
    chmod +x /tmp/bin/systemctl && \
    ln -sf /tmp/bin/systemctl /usr/bin/systemctl

# --- 5. Fetch and Apply SCAP Security Guide Remediation ---
RUN export SSG_VERSION=$(curl -s https://api.github.com/repos/ComplianceAsCode/content/releases/latest | grep -oP '"tag_name": "\K[^"]+' || echo "0.1.66") && \
    echo "🔄 Using SCAP Security Guide version: $SSG_VERSION" && \
    SSG_VERSION_NO_V=$(echo "$SSG_VERSION" | sed 's/^v//') && \
    wget -O /ssg.zip "https://github.com/ComplianceAsCode/content/releases/download/${SSG_VERSION}/scap-security-guide-${SSG_VERSION_NO_V}.zip" && \
    mkdir -p /usr/share/xml/scap/ssg/content && \
    if [ -f "/ssg.zip" ]; then \
        unzip -jo /ssg.zip "scap-security-guide-${SSG_VERSION_NO_V}/*" -d /usr/share/xml/scap/ssg/content/ && \
        rm -f /ssg.zip; \
    else \
        echo "❌ Failed to download SCAP Security Guide"; exit 1; \
    fi && \
    SCAP_GUIDE=$(find /usr/share/xml/scap/ssg/content -name "ssg-ubuntu*-ds.xml" | sort | tail -n1) && \
    echo "📘 Found SCAP guide: $SCAP_GUIDE" && \
    oscap xccdf eval \
        --remediate \
        --profile xccdf_org.ssgproject.content_profile_cis_level2_server \
        --results /root/oscap-results.xml \
        --report /root/oscap-report.html \
        "$SCAP_GUIDE" || true

# --- 6. Clean up SCAP content and scanner ---
RUN rm -rf /usr/share/xml/scap/ssg/content && \
    apt-get remove -y openscap-scanner libopenscap25t64 && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# --- 8. Install NVIDIA Driver if enabled ---
RUN if [ "$NVIDIA_INSTALL_ENABLED" = "true" ]; then \
        apt-get update && apt-get install -y \
            build-essential \
            pkg-config \
            xorg-dev \
            libx11-dev \
            libxext-dev \
            libglvnd-dev && \
        mkdir -p /build && cd /build && \
        echo "📥 Downloading NVIDIA driver from ${NVIDIA_DRIVER_URL}..." && \
        wget -q "${NVIDIA_DRIVER_URL}" -O /tmp/NVIDIA.run && \
        echo "📦 Extracting driver..." && \
        chmod +x /tmp/NVIDIA.run && \
        /tmp/NVIDIA.run --extract-only --target /build/nvidia && \
        cd /build/nvidia && \
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
                          --x-library-path=/usr/lib && \
        mkdir -p /etc/modules-load.d/ && \
        echo "nvidia" > /etc/modules-load.d/nvidia.conf && \
        echo "nvidia_uvm" >> /etc/modules-load.d/nvidia.conf && \
        echo "nvidia_drm" >> /etc/modules-load.d/nvidia.conf && \
        echo "nvidia_modeset" >> /etc/modules-load.d/nvidia.conf && \
        mkdir -p /dev/nvidia && \
        [ -e /dev/nvidia0 ] || mknod -m 666 /dev/nvidia0 c 195 0 && \
        [ -e /dev/nvidiactl ] || mknod -m 666 /dev/nvidiactl c 195 255 && \
        [ -e /dev/nvidia-uvm ] || mknod -m 666 /dev/nvidia-uvm c 243 0 && \
        [ -e /dev/nvidia-uvm-tools ] || mknod -m 666 /dev/nvidia-uvm-tools c 243 1 && \
        apt-get purge -y \
            build-essential \
            pkg-config \
            xorg-dev \
            libx11-dev \
            libxext-dev \
            libglvnd-dev && \
        apt-get autoremove -y && \
        apt-get clean && \
        rm -rf /var/lib/apt/lists/* /tmp/* /build; \
    fi

# ---  9. Install Slurm ---
COPY slurm-debs/*.deb /slurm-debs/
RUN mkdir -p /slurm-debs && \
    if [ "$SLURM_VERSION" != "0" ]; then \
        apt-get update && \
        debver=$(echo "$SLURM_VERSION" | sed 's/^\([0-9]*\)-\([0-9]*\)-\([0-9]*\)-\([0-9]*\)$/\1.\2.\3-\4/') && \
        apt-get install -y /slurm-debs/*_${debver}_*.deb && \
        apt-get clean && rm -rf /var/lib/apt/lists/*; \
    fi


# --- 10. Configure Autologin based on DISABLE_AUTOLOGIN ---
RUN if [ "$DISABLE_AUTOLOGIN" != "true" ]; then \
        mkdir -p /etc/systemd/system/getty@tty1.service.d && \
        echo '[Service]' > /etc/systemd/system/getty@tty1.service.d/override.conf && \
        echo 'ExecStart=' >> /etc/systemd/system/getty@tty1.service.d/override.conf && \
        echo 'ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM' >> /etc/systemd/system/getty@tty1.service.d/override.conf; \
    else \
        rm -rf /etc/systemd/system/getty@tty1.service.d; \
    fi

# --- 11. Configure Firstboot Service ---
COPY firstboot.service /etc/systemd/system/
COPY firstboot.sh /usr/local/sbin/
RUN chmod +x /usr/local/sbin/firstboot.sh && \
    mkdir -p /etc/systemd/system/multi-user.target.wants && \
    if [ "$FIRSTBOOT_ENABLED" = "true" ]; then \
        ln -s /etc/systemd/system/firstboot.service /etc/systemd/system/multi-user.target.wants/firstboot.service || true; \
    else \
        rm -f /etc/systemd/system/multi-user.target.wants/firstboot.service; \
    fi

# --- 12. Generate Initramfs for Selected Kernel ---
RUN if [ -n "$KERNEL_VERSION" ] && [ "$KERNEL_VERSION" != "latest" ]; then \
        update-initramfs -u -k "$KERNEL_VERSION"; \
    else \
        update-initramfs -u; \
    fi
	
# --- 13. Final Cleanup ---
RUN rm -f /usr/bin/systemctl && \
    rm -rf /tmp/bin && \
    [ -f /usr/bin/systemctl.bak ] && mv /usr/bin/systemctl.bak /usr/bin/systemctl || true && \
    rm -f /usr/sbin/policy-rc.d && \
    apt-get purge -y \
        cmake \
        libtool \
        zlib1g-dev \
        liblua5.3-0 \
        gcc \
        make \
        autoconf \
        automake \
        bpfcc-tools \
        pkg-config \
        build-essential \
        gettext && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf \
        /slurm-debs \
        /usr/src/* \
        /var/lib/apt/lists/* \
        /tmp/* \
        /var/tmp/* \
        /var/log/* \
        /var/log/apt/* \
        /usr/share/doc \
        /usr/share/man \
        /usr/share/locale \
        /usr/share/locale-langpack \
        /usr/share/info \
        /usr/sbin/policy-rc.d \
        /NVIDIA-Linux* \
        /root/.cache \
        /root/.wget-hsts && \
    find / -name '*.bash_history' -delete && \
    find / -name '.wget-hsts' -delete && \
    find / -name '.cache' -exec rm -rf {} +

# --- 14. Systemd-compatible boot (Warewulf) ---
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
