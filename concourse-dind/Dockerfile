FROM public.ecr.aws/docker/library/alpine:3
ENV DIND_COMMIT d58df1fc6c866447ce2cd129af10e5b507705624
# A lot of this is from docker:dind
#https://github.com/docker-library/docker/blob/12a4554648b671111eaf4cf4636cb1d6310c65e1/24/dind/Dockerfile#L79k
# https://github.com/docker/docker/blob/master/project/PACKAGERS.md#runtime-dependencies
RUN set -eux; \
	apk update && apk add --no-cache \
    git \
		btrfs-progs \
		e2fsprogs \
		e2fsprogs-extra \
		ip6tables \
		iptables \
		openssl \
		shadow-uidmap \
    bash \
    docker \
    docker-compose\
		xfsprogs \
		xz \
# pigz: https://github.com/moby/moby/pull/35697 (faster gzip implementation)
		pigz \
	; \
	wget -O /usr/local/bin/dind "https://raw.githubusercontent.com/docker/docker/${DIND_COMMIT}/hack/dind"; \
	chmod +x /usr/local/bin/dind; \
	addgroup -S dockremap; \
	adduser -S -G dockremap dockremap; \
	echo 'dockremap:165536:65536' >> /etc/subuid; \
	echo 'dockremap:165536:65536' >> /etc/subgid \
  dockerd --version; \
	containerd --version; \
	runc --version; \
# only install zfs if it's available for the current architecture
# https://git.alpinelinux.org/cgit/aports/tree/main/zfs/APKBUILD?h=3.6-stable#n9 ("all !armhf !ppc64le" as of 2017-11-01)
# "apk info XYZ" exits with a zero exit code but no output when the package exists but not for this arch
	if zfs="$(apk info --no-cache --quiet zfs)" && [ -n "$zfs" ]; then \
		apk add --no-cache zfs; \
	fi
COPY modprobe.sh /usr/local/bin/modprobe
COPY docker-utils.sh /opt/
COPY docker-entrypoint.sh /usr/local/bin/
COPY dockerd-entrypoint.sh /usr/local/bin/
COPY concourse-dind-entrypoint.sh /usr/local/bin/
VOLUME /var/lib/docker
EXPOSE 2375 2376
ENTRYPOINT concourse-dind-entrypoint.sh
