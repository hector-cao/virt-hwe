FROM ubuntu:resolute

ARG DEBIAN_FRONTEND=noninteractive

WORKDIR /workspace

RUN apt-get update \
	&& apt-get install -y --no-install-recommends dpkg-dev devscripts equivs \
	&& rm -rf /var/lib/apt/lists/*

CMD ["build"]
