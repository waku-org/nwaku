# BUILD IMAGE --------------------------------------------------------

FROM alpine:edge AS nim-build

ARG NIMFLAGS
ARG MAKE_TARGET=wakunode2
ARG RLN=true

# Get build tools and required header files
RUN apk add --no-cache bash git cargo build-base pcre-dev linux-headers

WORKDIR /app
COPY . .

# Ran separately from 'make' to avoid re-doing
RUN git submodule update --init --recursive

# Slowest build step for the sake of caching layers
RUN make -j$(nproc) deps RLN="$RLN"

# Build the final node binary
RUN make -j$(nproc) $MAKE_TARGET NIMFLAGS="$NIMFLAGS" RLN="$RLN"

# ACTUAL IMAGE -------------------------------------------------------

FROM alpine:3.16

ARG MAKE_TARGET=wakunode2

LABEL maintainer="jakub@status.im"
LABEL source="https://github.com/status-im/nim-waku"
LABEL description="Wakunode: Waku and Whisper client"
LABEL commit="unknown"

# DevP2P, LibP2P, and JSON RPC ports
EXPOSE 30303 60000 8545

# Referenced in the binary
RUN apk add --no-cache libgcc pcre-dev

# Fix for 'Error loading shared library libpcre.so.3: No such file or directory'
RUN ln -s /usr/lib/libpcre.so /usr/lib/libpcre.so.3

# Copy to separate location to accomodate different MAKE_TARGET values
COPY --from=nim-build /app/build/$MAKE_TARGET /usr/local/bin/

# If rln enabled: fix for 'Error loading shared library vendor/rln/target/debug/librln.so: No such file or directory'
COPY --from=nim-build /app/vendor/zerokit/target/release/librln.so vendor/zerokit/target/release/librln.so
COPY --from=nim-build /app/vendor/zerokit/rln/resources/ vendor/zerokit/rln/resources/

# Copy migration scripts for DB upgrades
COPY --from=nim-build /app/migrations/ /app/migrations/

# Symlink the correct wakunode binary
RUN ln -sv /usr/local/bin/$MAKE_TARGET /usr/bin/wakunode

ENTRYPOINT ["/usr/bin/wakunode"]
# By default just show help if called without arguments
CMD ["--help"]
