# SPDX-FileCopyrightText: 2026 Shotwell contributors
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Build and run environment for the Shotwell import benchmark.
# See build-aux/bench/README for how to use it.

FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        desktop-file-utils \
        gettext \
        git \
        itstool \
        meson \
        ninja-build \
        pkg-config \
        bison \
        flex \
        xz-utils \
        gobject-introspection \
        libgirepository-2.0-dev \
        libgirepository1.0-dev \
        libexiv2-dev \
        libcairo2-dev \
        libgcr-4-dev \
        libgdk-pixbuf-2.0-dev \
        libgee-0.8-dev \
        libglib2.0-dev \
        libglycin-2-dev \
        libgphoto2-dev \
        libgstreamer-plugins-base1.0-dev \
        libgstreamer1.0-dev \
        libgtk-4-dev \
        libgudev-1.0-dev \
        libjson-glib-dev \
        libpango1.0-dev \
        libportal-dev \
        libportal-gtk4-dev \
        libraw-dev \
        libsecret-1-dev \
        libsoup-3.0-dev \
        libsqlite3-dev \
        libxml2-dev \
        # runtime: image loaders (glycin runs them in a bubblewrap sandbox)
        glycin-loaders \
        bubblewrap \
        adwaita-icon-theme \
        shared-mime-info \
        # headless session
        weston \
        dbus \
        dbus-daemon \
        xvfb \
        xauth \
        # corpus generation and lower-bound measurement
        exiv2 \
        libraw-bin \
        jq \
        python3 \
        time \
        util-linux \
    && rm -rf /var/lib/apt/lists/*

# Ubuntu 26.04 ships valac 0.56.18, whose gtk4.vapi predates GTK 4.20 (no Gtk.Calendar.set_date,
# Gdk.DragAction.NONE, Gdk.Key.ContextMenu), so master does not compile with it. 0.56.19 has
# them. Build it from the release tarball, which contains the generated C code, so no valac is
# needed to bootstrap.
ARG VALA_VERSION=0.56.19
ARG VALA_SHA256=5ad7cbbfcc0de61b403d6797c9ef60455bfbebd8e162aec33b5b0b097adfb9d5
RUN curl -fsSL -o /tmp/vala.tar.xz \
        "https://download.gnome.org/sources/vala/${VALA_VERSION%.*}/vala-${VALA_VERSION}.tar.xz" \
    && echo "${VALA_SHA256}  /tmp/vala.tar.xz" | sha256sum -c - \
    && mkdir /tmp/vala && tar -xJf /tmp/vala.tar.xz -C /tmp/vala --strip-components=1 \
    && cd /tmp/vala \
    && ./configure --prefix=/usr/local --disable-valadoc \
    && make -j"$(nproc)" && make install \
    && ldconfig \
    && cd / && rm -rf /tmp/vala /tmp/vala.tar.xz \
    && valac --version

# Ubuntu 26.04 ships gexiv2 0.14.6, but meson.build needs gexiv2-0.16 >= 0.15.0.
# The upstream Flatpak builds gexiv2 from git main; pin a release tag here so the
# image is reproducible.
ARG GEXIV2_TAG=0.16.2
ARG GEXIV2_COMMIT=3b30dae74e6cd30cc584b71482abd2a40ff5dc77
RUN git clone --depth 1 --branch "${GEXIV2_TAG}" https://gitlab.gnome.org/GNOME/gexiv2.git /tmp/gexiv2 \
    && test "$(git -C /tmp/gexiv2 rev-parse HEAD)" = "${GEXIV2_COMMIT}" \
    && meson setup /tmp/gexiv2/build /tmp/gexiv2 \
        --prefix=/usr/local \
        --buildtype=release \
        -Dpython3=false \
        -Dtools=false \
        -Dintrospection=true \
        -Dvapi=true \
    && ninja -C /tmp/gexiv2/build install \
    && ldconfig \
    && rm -rf /tmp/gexiv2

ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib/aarch64-linux-gnu/pkgconfig:/usr/local/lib/x86_64-linux-gnu/pkgconfig \
    XDG_DATA_DIRS=/usr/local/share:/usr/share

# The harness scripts are bind-mounted read-only at /bench by build.sh, run.sh and
# make-corpus.sh, so editing them does not need an image rebuild.

WORKDIR /work
