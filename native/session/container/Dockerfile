# Build-time preparation only. Production startup is the Rust session executable.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ENV PATH="/opt/rayde/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    LD_LIBRARY_PATH="/opt/rayde/lib" HAXE_STD_PATH="/opt/rayde/haxe/std/" \
    HAXELIB_PATH="/opt/rayde/haxelib" RAYZOR_STD_PATH="/opt/rayde/haxe-std" \
    HOME="/workspace" TMPDIR="/tmp" SHELL="/bin/bash"
COPY payload/ /opt/rayde/
RUN ["/bin/sh", "/opt/rayde/bootstrap.sh"]
RUN ["python3", "/opt/rayde/container_image.py"]
RUN if ! getent passwd 1000 >/dev/null; then useradd --no-create-home --home-dir /workspace --uid 1000 rayde; fi \
    && chown -R 1000:1000 /workspace /state && chmod 700 /state
USER 1000:1000
WORKDIR /workspace/project
EXPOSE 8080
ENTRYPOINT ["/opt/rayde/bin/rayde-session", "container"]
