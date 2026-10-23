FROM fedora:44
RUN dnf install -y --setopt=install_weak_deps=False \
    binutils ca-certificates dbus-daemon dejavu-sans-fonts gnome-keyring \
    gvfs gtk3 ibus-gtk3 libglvnd-egl libglvnd-gles libglvnd-glx libsecret libX11 systemd-libs \
    mesa-dri-drivers glx-utils openbox python3 python3-gobject python3-pillow \
    scrot tesseract tesseract-langpack-eng xdotool xorg-x11-server-Xvfb xorg-x11-xauth \
    && dnf clean all
RUN useradd --create-home smoke
COPY . /opt/linux-smoke/
USER smoke
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 GDK_BACKEND=x11 \
    LIBGL_ALWAYS_SOFTWARE=true GALLIUM_DRIVER=llvmpipe
ENTRYPOINT ["xvfb-run", "-a", "-s", "-screen 0 1600x1000x24", "dbus-run-session", "--", "python3", "/opt/linux-smoke/smoke.py"]
