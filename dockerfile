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
ARG KERNEL_INSTALL_ENABLED

# =============================================================================
# USER & GROUP SETUP - Standardized across all Slurm services
# =============================================================================

# --- 0. Set root user ---
USER root

# --- 2. Set root password ---
RUN echo "root:changeme" | chpasswd

# --- 1. Create Slurm service user (UID 999) ---
RUN groupadd -g 999 slurm && useradd -u 999 -g 999 -m -s /bin/bash slurm

# --- 2. Create Munge authentication user (UID 972) ---
RUN groupadd -g 972 munge && useradd -u 972 -g 972 -m -s /sbin/nologin munge 

# --- 3. Create wwuser user accounts (UID 2000) ---
RUN groupadd -g 2000 wwgroup && \
    useradd -u 2000 -m -d /local/home/wwuser -g wwgroup -G sudo,munge -s /bin/bash wwuser && \
    echo "wwuser:wwpassword" | chpasswd

# --- 4. Create slurmrest user for REST API (UID 971) ---
RUN groupadd -g 971 slurmrest && useradd -u 971 -g 971 -m -s /bin/false slurmrest

# --- 5. Create distributive.network user (UID 2001) ---
RUN groupadd -g 2001 distgroup && \
    useradd -u 2001 -m -d /local/home/dist -g distgroup -s /bin/bash dist

# --- 5. Install Core Tools, Debugging, and Dependencies ---
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
    less \
    htop \
    sysstat \
    cron \
    ipmitool \
    smartmontools \
    lm-sensors \
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
    tcpdump \
    strace \
    lsof \
    jq \
    git \
    iputils-ping \
    lsb-release \
    bash-completion \
    bpfcc-tools \
    cgroup-tools \
    auditd \
    apt-transport-https \
    software-properties-common \
    gnupg-agent \
    ignition \
    gdisk \
    initramfs-tools \
    xfsprogs \
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
    dkms \
    munge && \
    if [ "$KERNEL_INSTALL_ENABLED" = "true" ]; then \
        apt-get install -y \
            linux-image-${KERNEL_VERSION} \
            linux-headers-${KERNEL_VERSION} \
            linux-modules-${KERNEL_VERSION} \
            linux-modules-extra-${KERNEL_VERSION} && \
        ln -s /usr/src/linux-headers-${KERNEL_VERSION} /lib/modules/${KERNEL_VERSION}/build; \
    fi && \
    mkdir -p /var/log/journal && \
    systemd-tmpfiles --create --prefix /var/log/journal && \
    systemctl mask \
      systemd-udevd.service \
      systemd-udevd-kernel.socket \
      systemd-udevd-control.socket \
      systemd-modules-load.service \
      sys-kernel-config.mount \
      sys-kernel-debug.mount \
      sys-fs-fuse-connections.mount \
      systemd-remount-fs.service \
      getty.target \
      systemd-logind.service \
      systemd-vconsole-setup.service \
      systemd-timesyncd.service

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
    apt-get autoremove -y 

# --- 8. Install NVIDIA Driver if enabled (requires kernel installation) ---
# proprietary: required for pre-Turing GPUs (Pascal GTX1080 = this fleet);
# open kernel modules support Turing+ only.
ARG NVIDIA_MODULE_TYPE="proprietary"
RUN if [ "$NVIDIA_INSTALL_ENABLED" = "true" ] && [ "$KERNEL_INSTALL_ENABLED" = "true" ]; then \
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
                          --kernel-module-type=${NVIDIA_MODULE_TYPE} \
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
        [ -e /dev/nvidia-uvm-tools ] || mknod -m 666 /dev/nvidia-uvm-tools c 243 1 ; \
    fi

# --- 9. Prepare Slurm DEBs ---
COPY slurm-debs/*.deb /slurm-debs/

RUN mkdir -p /slurm-debs && \
    if [ "$SLURM_VERSION" != "0" ]; then \
        debver=$(echo "$SLURM_VERSION" | sed 's/^\([0-9]*\)-\([0-9]*\)-\([0-9]*\)-\([0-9]*\)$/\1.\2.\3-\4/') && \
        echo "🧹 Keeping only *_${debver}_*.deb packages..." && \
        find /slurm-debs -type f -name '*.deb' ! -name "*_${debver}_*.deb" -delete; \
    fi && \
    echo "🔎 Filtering unwanted packages..." && \
    EXCLUDE_KEYWORDS="slurmctld slurmrestd slurmdbd" && \
    mkdir -p /tmp/keep-debs && \
    for deb in /slurm-debs/*.deb; do \
        skip=false; \
        for keyword in $EXCLUDE_KEYWORDS; do \
            if echo "$deb" | grep -q "$keyword"; then \
                skip=true; \
                break; \
            fi; \
        done; \
        if [ "$skip" = false ]; then \
            echo "✅ Keeping: $(basename "$deb")"; \
            cp "$deb" /tmp/keep-debs/; \
        else \
            echo "🚫 Skipping: $(basename "$deb")"; \
        fi; \
    done && \
    rm -rf /slurm-debs && \
    mv /tmp/keep-debs /slurm-debs

RUN dpkg -i /slurm-debs/*.deb || (echo "⚠️ dpkg failed, attempting fix..." && apt-get install -f -y)

# --- 9b. Optional Pyxis/Enroot Container Stack (PYXIS_ENABLED=true) ---
# Staged by the workflow: pyxis/ (source at resolved ref) and enroot.deb.
# Installs the SPANK plugin, enroot runtime and uidmap together. The dev
# headers come from the staged slurm-smd-dev DEB, so the plugin ABI always
# matches the Slurm in this image. squashfuse + fuse-overlayfs enable
# pyxis use_squashfuse=true (direct RO-sqsh start: no enroot-create
# extraction, nothing written to the user's home/quota). No-op when
# disabled.
ARG PYXIS_ENABLED="false"
COPY pxstage/ /pxstage/
COPY enroot-switchroot-rootfs.patch /tmp/
RUN if [ "$PYXIS_ENABLED" = "true" ]; then \
        make -C /pxstage/pyxis && \
        install -m 644 /pxstage/pyxis/spank_pyxis.so /usr/lib/x86_64-linux-gnu/slurm/ && \
        dpkg -i /pxstage/enroot.deb || apt-get install -f -y && \
        apt-get install -y uidmap libbsd-dev patch squashfuse fuse-overlayfs && \
        mkdir -p /tmp/enroot-src && \
        tar -xf /pxstage/enroot-src.tar.gz -C /tmp/enroot-src --strip-components=1 && \
        patch -d /tmp/enroot-src -p1 < /tmp/enroot-switchroot-rootfs.patch && \
        gcc -std=c99 -O2 -o /tmp/enroot-switchroot /tmp/enroot-src/bin/enroot-switchroot.c -I/tmp/enroot-src/bin -lbsd && \
        install -m 755 /tmp/enroot-switchroot /usr/bin/enroot-switchroot; \
        printf 'd /run/enroot 1777 root root -\n' > /etc/tmpfiles.d/enroot.conf; \
    fi && \
    rm -rf /pxstage /tmp/enroot-src /tmp/enroot-switchroot /tmp/enroot-switchroot-rootfs.patch

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
RUN if [ "$FIRSTBOOT_ENABLED" = "true" ]; then \
        chmod +x /usr/local/sbin/firstboot.sh && \
        systemctl enable firstboot.service; \
    else \
        rm -f /etc/systemd/system/multi-user.target.wants/firstboot.service && \
        rm -f /usr/local/sbin/firstboot.sh; \
    fi

RUN systemctl enable \
    munge.service \
    rsyslog.service \
    ssh.service \
    auditd.service

# --- 12. Generate Initramfs for Selected Kernel (if kernel is installed) ---
RUN if [ "$KERNEL_INSTALL_ENABLED" = "true" ]; then \
        update-initramfs -u -k "$KERNEL_VERSION"; \
    fi
	
# --- 13. Final Cleanup ---
RUN apt-mark manual libvulkan1 mesa-vulkan-drivers libglvnd0 && \
    apt-get purge -y \
        mesa-common-dev xserver-xorg-dev xorg-dev \
        libx*dev libgl*dev libegl*dev libgles*dev \
        libx11-dev libxext-dev libxft-dev \
        build-essential dkms gcc make pkg-config \
        libfreetype-dev libpng-dev uuid-dev libexpat1-dev \
        openscap-common \
        python-babel-localedata \
        humanity-icon-theme \
        iso-codes \
        cmake \
        libtool \
        zlib1g-dev \
        autoconf \
        automake \
        bpfcc-tools \
        xorg-dev \
        libx11-dev \
        libxext-dev \
        initramfs-tools \
        gettext && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf \
        /var/lib/apt/lists/* \
        /tmp/* \
        /var/tmp/* \
        /build \
        /slurm-debs \
        /var/log/apt/* \
        /usr/share/doc \
        /usr/share/man \
        /usr/share/locale \
        /usr/share/locale-langpack \
        /usr/share/info \
        /NVIDI* \
        /root/.cache \
        /root/.wget-hsts \
        /run/slurm/conf && \
    mkdir -p /var/spool/slurmd && \
    mkdir -p /var/log/munge && \
    chown munge:munge -R /var/log/munge && \
    find / -name '*.bash_history' -delete && \
    find /var/log/ -type f -exec rm -f {} + && \
    find / -name '.wget-hsts' -delete && \
    find / -name '.cache' -exec rm -rf {} +

RUN systemctl unmask \
    systemd-udevd.service \
    systemd-udevd-kernel.socket \
    systemd-udevd-control.socket \
    systemd-modules-load.service \
    sys-kernel-config.mount \
    sys-kernel-debug.mount \
    sys-fs-fuse-connections.mount \
    systemd-remount-fs.service \
    getty.target \
    systemd-logind.service \
    systemd-vconsole-setup.service \
    systemd-timesyncd.service && \
    systemctl enable \
    systemd-udevd.service \
    systemd-modules-load.service \
    getty@tty1.service \
    systemd-logind.service \
    ssh.service \
    rsyslog.service \
    auditd.service

# --- 14. Systemd-compatible boot (Warewulf) ---
#STOPSIGNAL SIGRTMIN+3
#CMD ["/sbin/init"]
