ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    binutils ca-certificates dbus-x11 fonts-dejavu-core fonts-liberation \
    gir1.2-gtk-3.0 gnome-keyring gvfs ibus-gtk3 libegl1 libgles2 libgl1-mesa-dri libgl1 libglib2.0-bin \
    libgtk-3-0 libsecret-1-0 libudev1 mesa-utils openbox python3 python3-gi \
    python3-pil scrot tesseract-ocr tesseract-ocr-eng xauth xdotool xvfb \
    && rm -rf /var/lib/apt/lists/*
RUN useradd --create-home smoke
COPY . /opt/linux-smoke/
USER smoke
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 GDK_BACKEND=x11 \
    LIBGL_ALWAYS_SOFTWARE=true GALLIUM_DRIVER=llvmpipe
ENTRYPOINT ["xvfb-run", "-a", "-s", "-screen 0 1600x1000x24", "dbus-run-session", "--", "python3", "/opt/linux-smoke/smoke.py"]
