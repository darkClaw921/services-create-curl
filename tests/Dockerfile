# Образ для интеграционных тестов service.sh с НАСТОЯЩИМ systemd.
# Загружается как PID 1 (/sbin/init) в privileged-контейнере, поэтому
# systemctl/journalctl работают по-настоящему. nginx/ss/python3 — реальные.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
        systemd systemd-sysv \
        bash gawk coreutils \
        nginx \
        curl ca-certificates \
        iproute2 procps \
        python3 \
        shellcheck \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Чистим юниты, которые мешают старту systemd в контейнере
RUN find /etc/systemd/system /lib/systemd/system \
      -path '*.wants/*' \
      \( -name '*getty*' -o -name '*udev*' -o -name '*swap*' \
         -o -name 'systemd-firstboot*' -o -name '*networkd*' -o -name '*resolved*' \) \
      -delete 2>/dev/null || true

# Чтобы nginx не стартовал автоматически до того, как тесты будут готовы
RUN systemctl disable nginx 2>/dev/null || true

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
