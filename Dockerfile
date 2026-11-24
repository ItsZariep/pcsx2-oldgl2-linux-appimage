FROM i386/debian:wheezy

# wheezy is archived: point apt to archive.debian.org, ignore expired Release files
RUN printf '%s\n' \
	'deb http://archive.debian.org/debian wheezy main contrib non-free' \
	'deb http://archive.debian.org/debian-security wheezy/updates main contrib non-free' \
	> /etc/apt/sources.list \
&& echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99archive \
&& echo 'APT::Get::AllowUnauthenticated "true";' >> /etc/apt/apt.conf.d/99archive

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
	build-essential cmake autoconf automake libtool pkg-config git ca-certificates \
	subversion file wget gettext libsparsehash-dev portaudio19-dev gtk2-engines \
	libwxgtk2.8-dev libgtk2.0-dev \
	nvidia-cg-toolkit libglew-dev libgl1-mesa-dev libglu1-mesa-dev \
	libasound2-dev libpulse-dev libsoundtouch-dev libsdl1.2-dev \
	libjpeg-dev libpng12-dev libbz2-dev zlib1g-dev libaio-dev \
	libx11-dev libxext-dev libxxf86vm-dev \
&& rm -rf /var/lib/apt/lists/*

ARG PCSX2_REF=heads/0.9.8
ENV PCSX2_REF=${PCSX2_REF}

COPY build-appdir.sh AppRun /opt/
RUN chmod +x /opt/build-appdir.sh /opt/AppRun

WORKDIR /src
CMD ["/opt/build-appdir.sh"]
