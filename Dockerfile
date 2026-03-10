FROM ubuntu:resolute

ARG DEBIAN_FRONTEND=noninteractive

WORKDIR /workspace

RUN apt-get update \
	&& apt-get install -y --no-install-recommends dpkg-dev devscripts equivs software-properties-common

CMD ["build"]
