# docker image to build an RT kernel for the RPI4 based on Ubuntu 20.04 RPI4 image
#
# By default it finds and takes the latest raspi image and the RT_PREEMPT patch closest to it
# if the build arguments defined it will build the corresponding version instead
# $ docker build [--build-arg UNAME_R=<raspi release>] [--build-arg RT_PATCH=<RT patch>] -t rtwg-image .
#
# where <raspi release> is in a form of 5.4.0-1058-raspi,
#     see http://ports.ubuntu.com/pool/main/l/linux-raspi/
# and <RT patch> is in a form of 5.4.177-rt69,
#     see http://cdn.kernel.org/pub/linux/kernel/projects/rt/5.4/older
#
# $ docker run -it rtwg-image bash
#
# and then inside the docker
# $ cd $HOME/linux_build/linux-raspi
# $ make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION=-raspi -j `nproc` bindeb-pkg
#
# user ~/linux_build/linux-raspi $ ls -la ../*.deb
# -rw-r--r-- 1 user user  11442412 Apr  8 13:20 ../linux-headers-5.4.174-rt69-raspi_5.4.174-rt69-raspi-1_arm64.deb
# -rw-r--r-- 1 user user  40261364 Apr  8 13:21 ../linux-image-5.4.174-rt69-raspi_5.4.174-rt69-raspi-1_arm64.deb
# -rw-r--r-- 1 user user   1055452 Apr  8 13:20 ../linux-libc-dev_5.4.174-rt69-raspi-1_arm64.deb
#
# copy deb packages to the host, or directly to the RPI4 target
# $ scp ../*.deb <user>@172.17.0.1:/home/<user>/.

FROM ubuntu:focal

USER root
ARG DEBIAN_FRONTEND=noninteractive

# setup timezone
RUN echo 'Etc/UTC' > /etc/timezone \
    && ln -s -f /usr/share/zoneinfo/Etc/UTC /etc/localtime \
    && apt-get update && apt-get install -q -y tzdata apt-utils lsb-release software-properties-common openssh-client \
    && rm -rf /var/lib/apt/lists/*

ARG ARCH=arm64
ARG UNAME_R
ARG RT_PATCH
ARG triple=aarch64-linux-gnu
ARG KERNEL_VERSION=5.4.0
ARG UBUNTU_VERSION=focal
ARG LTTNG_VERSION=2.12
ARG KERNEL_DIR=linux-raspi

# setup arch
RUN apt-get update && apt-get install -q -y \
    gcc-${triple} \
    && dpkg --add-architecture ${ARCH} \
    && sed -i 's/deb h/deb [arch=amd64] h/g' /etc/apt/sources.list \
    && add-apt-repository -n -s "deb [arch=$ARCH] http://ports.ubuntu.com/ubuntu-ports/ $(lsb_release -s -c) main universe restricted" \
    && add-apt-repository -n -s "deb [arch=$ARCH] http://ports.ubuntu.com/ubuntu-ports $(lsb_release -s -c)-updates main universe restricted" \
    && rm -rf /var/lib/apt/lists/*

# setup environment
ENV LANG C.UTF-8
ENV LC_ALL C.UTF-8

# install build deps
RUN apt-get update && apt-get build-dep -q -y linux \
    && apt-get install -q -y \
    libncurses-dev flex bison openssl libssl-dev dkms libelf-dev libudev-dev libpci-dev libiberty-dev autoconf \
    fakeroot \
    && rm -rf /var/lib/apt/lists/*

# setup user
RUN apt-get update && apt-get install -q -y sudo \
    && useradd -m -d /home/user -s /bin/bash user \
    && gpasswd -a user sudo \
    && echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers \
    && echo 'user\nuser\n' | passwd user \
    && rm -rf /var/lib/apt/lists/*

# install extra packages needed for the patch handling
RUN apt-get update && apt-get install -q -y wget curl gzip git time \
    && rm -rf /var/lib/apt/lists/*

USER user

# find the latest UNAME_R and store it locally for the later usage
# if $UNAME_R is set via --build-arg, take it
RUN if test -z $UNAME_R; then UNAME_R=`curl -s http://ports.ubuntu.com/pool/main/l/linux-raspi/ | grep linux-buildinfo | grep -o -P '(?<=<a href=").*(?=">l)' | grep ${ARCH} | grep ${KERNEL_VERSION} | sort | tail -n 1 | cut -d '-' -f 3-4`-raspi; fi \
    && echo $UNAME_R > /home/user/uname_r

# install linux sources from git
RUN mkdir /home/user/linux_build \
    && cd /home/user/linux_build \
    && time git clone -b master --single-branch https://git.launchpad.net/~ubuntu-kernel/ubuntu/+source/linux-raspi/+git/${UBUNTU_VERSION} ${KERNEL_DIR} \
    && cd ${KERNEL_DIR} \
    && git fetch --tag

# checkout necessary tag
RUN cd /home/user/linux_build/${KERNEL_DIR} \
    && git tag -l *`cat /home/user/uname_r | cut -d '-' -f 2`* | tail -1 > /home/user/linux_build/tag \
    && git checkout `cat /home/user/linux_build/tag`

# install buildinfo to retieve `raspi` kernel config
RUN cd /home/user \
    && wget http://ports.ubuntu.com/pool/main/l/linux-raspi/linux-buildinfo-${KERNEL_VERSION}-`cat /home/user/uname_r | cut -d '-' -f 2`-raspi_${KERNEL_VERSION}-`cat /home/user/linux_build/tag | cut -d '-' -f 4`_${ARCH}.deb \
    && dpkg -X *.deb /home/user/

# install lttng dependencies
RUN sudo apt-get update \
    && sudo apt-get install -y libuuid1 libpopt0 liburcu6 libxml2 numactl

COPY ./getpatch.sh /home/user/.

# get the nearest RT patch to the kernel SUBLEVEL
# if $RT_PATCH is set via --build-arg, take it
RUN cd /home/user/linux_build/${KERNEL_DIR} \
    && if test -z $RT_PATCH; then /home/user/getpatch.sh `make kernelversion` > /home/user/rt_patch; else echo $RT_PATCH > /home/user/rt_patch; fi

# download and unzip RT patch
RUN cd /home/user/linux_build \
    && wget http://cdn.kernel.org/pub/linux/kernel/projects/rt/`echo ${KERNEL_VERSION} | cut -d '.' -f 1-2`/older/patch-`cat /home/user/rt_patch`.patch.gz \
    && gunzip patch-`cat /home/user/rt_patch`.patch.gz

# download lttng source for use later
# TODO(flynneva): make script to auto-determine which version to get?
RUN cd /home/user/ \
    && sudo apt-add-repository ppa:lttng/stable-${LTTNG_VERSION} \
    && sudo apt-get update \
    && apt-get source lttng-modules-dkms

WORKDIR /home/user

# run lttng built-in script to configure RT kernel
RUN set -x \
    cd /home/user \
    && cd `ls -d lttng-modules-*` \
    && ./scripts/built-in.sh ${HOME}/linux_build/${KERNEL_DIR}

# patch kernel, do not fail if some patches are skipped
RUN cd /home/user/linux_build/${KERNEL_DIR} \
    && OUT="$(patch -p1 --forward < ../patch-`cat $HOME/rt_patch`.patch)" || echo "${OUT}" | grep "Skipping patch" -q || (echo "$OUT" && false);

# setup build environment
RUN cd /home/user/linux_build/${KERNEL_DIR} \
    && export $(dpkg-architecture -a${ARCH}) \
    && export CROSS_COMPILE=${triple}- \
    && fakeroot debian/rules clean \
    && LANG=C fakeroot debian/rules printenv

COPY ./.config-fragment /home/user/linux_build/.

# config RT kernel and merge config fragment
RUN cd /home/user/linux_build/${KERNEL_DIR} \
    && cp /home/user/usr/lib/linux/`cat /home/user/uname_r`/config .config \
    && ARCH=${ARCH} CROSS_COMPILE=${triple}- ./scripts/kconfig/merge_config.sh .config $HOME/linux_build/.config-fragment

RUN cd /home/user/linux_build/${KERNEL_DIR} \
    && fakeroot debian/rules clean
