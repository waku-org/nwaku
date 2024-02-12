// (C) 2023 Doug Hoyte. MIT license

#pragma once

#include <openssl/sha.h>


namespace negentropy {

using err = std::runtime_error;

const size_t ID_SIZE = 32;
const size_t FINGERPRINT_SIZE = 16;


enum class Mode {
    Skip = 0,
    Fingerprint = 1,
    IdList = 2,
};


struct Item {
    uint64_t timestamp;
    uint8_t id[ID_SIZE];

    explicit Item(uint64_t timestamp = 0) : timestamp(timestamp) {
        memset(id, '\0', sizeof(id));
    }

    explicit Item(uint64_t timestamp, std::string_view id_) : timestamp(timestamp) {
        if (id_.size() != sizeof(id)) throw negentropy::err("bad id size for Item");
        memcpy(id, id_.data(), sizeof(id));
    }

    std::string_view getId() const {
        return std::string_view(reinterpret_cast<const char*>(id), sizeof(id));
    }

    bool operator==(const Item &other) const {
        return timestamp == other.timestamp && getId() == other.getId();
    }
};

inline bool operator<(const Item &a, const Item &b) {
    return a.timestamp != b.timestamp ? a.timestamp < b.timestamp : a.getId() < b.getId();
};

inline bool operator<=(const Item &a, const Item &b) {
    return a.timestamp != b.timestamp ? a.timestamp <= b.timestamp : a.getId() <= b.getId();
};


struct Bound {
    Item item;
    size_t idLen;

    explicit Bound(uint64_t timestamp = 0, std::string_view id = "") : item(timestamp), idLen(id.size()) {
        if (idLen > ID_SIZE) throw negentropy::err("bad id size for Bound");
        memcpy(item.id, id.data(), idLen);
    }

    explicit Bound(const Item &item_) : item(item_), idLen(ID_SIZE) {}

    bool operator==(const Bound &other) const {
        return item == other.item;
    }
};

inline bool operator<(const Bound &a, const Bound &b) {
    return a.item < b.item;
};


struct Fingerprint {
    uint8_t buf[FINGERPRINT_SIZE];

    std::string_view sv() const {
        return std::string_view(reinterpret_cast<const char*>(buf), sizeof(buf));
    }
};

struct Accumulator {
    uint8_t buf[ID_SIZE];

    void setToZero() {
        memset(buf, '\0', sizeof(buf));
    }

    void add(const Item &item) {
        add(item.id);
    }

    void add(const Accumulator &acc) {
        add(acc.buf);
    }

    void add(const uint8_t *otherBuf) {
        uint64_t currCarry = 0, nextCarry = 0;
        uint64_t *p = reinterpret_cast<uint64_t*>(buf);
        const uint64_t *po = reinterpret_cast<const uint64_t*>(otherBuf);

        auto byteswap = [](uint64_t &n) {
            uint8_t *first = reinterpret_cast<uint8_t*>(&n);
            uint8_t *last = first + 8;
            std::reverse(first, last);
        };

        for (size_t i = 0; i < 4; i++) {
            uint64_t orig = p[i];
            uint64_t otherV = po[i];

            if constexpr (std::endian::native == std::endian::big) {
                byteswap(orig);
                byteswap(otherV);
            } else {
                static_assert(std::endian::native == std::endian::little);
            }

            uint64_t next = orig;

            next += currCarry;
            if (next < orig) nextCarry = 1;

            next += otherV;
            if (next < otherV) nextCarry = 1;

            if constexpr (std::endian::native == std::endian::big) {
                byteswap(next);
            }

            p[i] = next;
            currCarry = nextCarry;
            nextCarry = 0;
        }
    }

    void negate() {
        for (size_t i = 0; i < sizeof(buf); i++) {
            buf[i] = ~buf[i];
        }

        Accumulator one;
        one.setToZero();
        one.buf[0] = 1;
        add(one.buf);
    }

    void sub(const Item &item) {
        sub(item.id);
    }

    void sub(const Accumulator &acc) {
        sub(acc.buf);
    }

    void sub(const uint8_t *otherBuf) {
        Accumulator neg;
        memcpy(neg.buf, otherBuf, sizeof(buf));
        neg.negate();
        add(neg);
    }

    std::string_view sv() const {
        return std::string_view(reinterpret_cast<const char*>(buf), sizeof(buf));
    }

    Fingerprint getFingerprint(uint64_t n) {
        std::string input;
        input += sv();
        input += encodeVarInt(n);

        unsigned char hash[SHA256_DIGEST_LENGTH];
        SHA256(reinterpret_cast<unsigned char*>(input.data()), input.size(), hash);

        Fingerprint out;
        memcpy(out.buf, hash, FINGERPRINT_SIZE);

        return out;
    }
};


}
