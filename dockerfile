FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# --- 0. Set root user ---
USER root

# --- 1. Install Core Tools, Debugging, Kubernetes Dependencies, and Kernel ---
RUN apt-get update && apt-get install -y \
    sudo \
    openssh-server \
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
    linux-image-generic \
    linux-headers-generic \
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
    gnupg \
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
    systemd \
    rsyslog \
    logrotate \
    systemd-journal-remote \
    ca-certificates && \
    apt-get clean && \
    mkdir -p /var/log/journal && \
    systemd-tmpfiles --create --prefix /var/log/journal && \
    rm -rf /var/lib/apt/lists/*

# --- 2. Set root password ---
RUN echo "root:changeme" | chpasswd

RUN groupadd wwgroup && \
    useradd -m -d /local/home/wwuser -g sudo -s /bin/bash wwuser && \
    echo "wwuser:wwpassword" | chpasswd 

# Temporarily disable service configuration
RUN echo '#!/bin/sh\nexit 101' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d

# Install Helm
RUN curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 && \
    chmod 700 get_helm.sh && \
    ./get_helm.sh && \
    rm -f get_helm.sh

# Create fake systemctl for environments without systemd
RUN mkdir -p /tmp/bin && \
    cp /usr/bin/systemctl /usr/bin/systemctl.bak && \
    echo '#!/bin/sh\nexit 0' > /tmp/bin/systemctl && \
    chmod +x /tmp/bin/systemctl && \
    ln -sf /tmp/bin/systemctl /usr/bin/systemctl

# --- 3. Fetch and Apply SCAP Security Guide Remediation ---
RUN export SSG_VERSION=$(curl -s https://api.github.com/repos/ComplianceAsCode/content/releases/latest | grep -oP '"tag_name": "\K[^"]+' || echo "0.1.66") && \
    echo "🔄 Using SCAP Security Guide version: $SSG_VERSION" && \
    SSG_VERSION_NO_V=$(echo "$SSG_VERSION" | sed 's/^v//') && \
    wget -O /ssg.zip "https://github.com/ComplianceAsCode/content/releases/download/${SSG_VERSION}/scap-security-guide-${SSG_VERSION_NO_V}.zip" && \
    mkdir -p /usr/share/xml/scap/ssg/content && \
    unzip -jo /ssg.zip "scap-security-guide-${SSG_VERSION_NO_V}/*" -d /usr/share/xml/scap/ssg/content/ && \
    rm -f /ssg.zip && \
    SCAP_GUIDE=$(find /usr/share/xml/scap/ssg/content -name "ssg-ubuntu*-ds.xml" | sort | tail -n1) && \
    echo "📘 Found SCAP guide: $SCAP_GUIDE" && \
    oscap xccdf eval \
        --remediate \
        --profile xccdf_org.ssgproject.content_profile_cis_level2_server \
        --results /root/oscap-results.xml \
        --report /root/oscap-report.html \
        "$SCAP_GUIDE" || true && \
    echo "✅ SCAP remediation done."

# --- 4. Clean up SCAP content and scanner ---
RUN rm -rf /usr/share/xml/scap/ssg/content && \
    apt remove -y openscap-scanner libopenscap25t64 && \
    apt autoremove -y && \
    apt clean && \
    rm -rf /var/lib/apt/lists/*

# --- 5. Install RKE2 (server mode) ---
RUN curl -sfL https://get.rke2.io | sh 

# --- Patch for kubectl, systemd unit, and audit logs ---
ENV PATH="/var/lib/rancher/rke2/bin:${PATH}"

RUN mkdir -p /etc/systemd/system && \
    mkdir -p /etc/rancher/rke2/ && \
    cp /usr/local/lib/systemd/system/rke2-server.service /etc/systemd/system/ && \
    ln -s /etc/systemd/system/rke2-server.service /etc/systemd/system/multi-user.target.wants/rke2-server.service && \
    mkdir -p /var/log/audit

# --- 7. Create sysctl config for K8s networking ---
RUN echo 'net.bridge.bridge-nf-call-iptables=1' >> /etc/sysctl.d/k8s.conf && \
    echo 'net.bridge.bridge-nf-call-ip6tables=1' >> /etc/sysctl.d/k8s.conf && \
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.d/k8s.conf && \
    sysctl --system || true

# Enable root autologin on tty1
RUN mkdir -p /etc/systemd/system/getty@tty1.service.d && \
    echo '[Service]' > /etc/systemd/system/getty@tty1.service.d/override.conf && \
    echo 'ExecStart=' >> /etc/systemd/system/getty@tty1.service.d/override.conf && \
    echo 'ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM' >> /etc/systemd/system/getty@tty1.service.d/override.conf

RUN apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /usr/src/* /var/lib/apt/lists/* /tmp/* \
           /var/tmp/* /var/log/* /usr/share/doc /usr/share/man \
           /usr/share/locale /usr/share/info /usr/sbin/policy-rc.d /usr/src/* 

# Remove fake systemctl after use
RUN rm -f /usr/bin/systemctl && \
    rm -rf /tmp/bin && \
    cp /usr/bin/systemctl.bak /usr/bin/systemctl

# --- 8. Rebuild initramfs (for PXE or WW images) ---
RUN update-initramfs -u

# --- 9. Systemd-compatible boot (Warewulf) ---
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
