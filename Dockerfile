# BUILD IMAGE --------------------------------------------------------
FROM alpine:3.11 AS nim-build

ARG NIM_PARAMS

# Get build tools and required header files
RUN apk add --no-cache bash build-base pcre-dev linux-headers git

RUN mkdir /app
WORKDIR /app
ADD . .

# Ran separately from 'make' to avoid re-doing
RUN git submodule update --init --recursive

# Build the node binary
RUN make -j$(nproc) wakunode NIM_PARAMS="${NIM_PARAMS}"

# ACTUAL IMAGE -------------------------------------------------------
FROM alpine:3.11

LABEL maintainer="jakub@status.im"
LABEL source="https://github.com/status-im/nim-waku"
LABEL description="Wakunode: Waku and Whisper client"

EXPOSE 1234

# Referenced in the binary
RUN apk add --no-cache libgcc pcre-dev

# Fix for 'Error loading shared library libpcre.so.3: No such file or directory'
RUN ln -s /usr/lib/libpcre.so /usr/lib/libpcre.so.3

COPY --from=nim-build /app/build/wakunode /usr/bin/wakunode

ENTRYPOINT ["/usr/bin/wakunode"]
# By default just show help if called without arguments
CMD ["--help"]
