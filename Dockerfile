FROM ubuntu:resolute

ARG DEBIAN_FRONTEND=noninteractive

WORKDIR /workspace

COPY qemu/debian/control /tmp/qemu-control
COPY qemu-hwe/debian/control /tmp/qemu-hwe-control

RUN apt-get update \
	&& apt-get install -y --no-install-recommends dpkg-dev devscripts equivs \
	&& mk-build-deps --install --remove --tool 'apt-get -y --no-install-recommends' /tmp/qemu-control \
	&& mk-build-deps --install --remove --tool 'apt-get -y --no-install-recommends' /tmp/qemu-hwe-control \
	&& rm -f /tmp/qemu-control /tmp/qemu-hwe-control \
	&& rm -rf /var/lib/apt/lists/*

CMD ["build"]
