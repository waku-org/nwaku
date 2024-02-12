#pragma once

#include <algorithm>

#include "negentropy.h"



namespace negentropy { namespace storage {


struct SubRange : StorageBase {
    StorageBase &base;
    size_t baseSize;
    size_t subBegin;
    size_t subEnd;
    size_t subSize;

    SubRange(StorageBase &base, const Bound &lowerBound, const Bound &upperBound) : base(base) {
        baseSize = base.size();
        subBegin = lowerBound == Bound(0) ? 0 : base.findLowerBound(0, baseSize, lowerBound);
        subEnd = upperBound == Bound(MAX_U64) ? baseSize : base.findLowerBound(subBegin, baseSize, upperBound);
        if (subEnd != baseSize && Bound(base.getItem(subEnd)) == upperBound) subEnd++; // instead of upper_bound: OK because items are unique
        subSize = subEnd - subBegin;
    }

    uint64_t size() {
        return subSize;
    }

    const Item &getItem(size_t i) {
        if (i >= subSize) throw negentropy::err("bad index");
        return base.getItem(subBegin + i);
    }

    void iterate(size_t begin, size_t end, std::function<bool(const Item &, size_t)> cb) {
        checkBounds(begin, end);

        base.iterate(subBegin + begin, subBegin + end, [&](const Item &item, size_t index){
            return cb(item, index - subBegin);
        });
    }

    size_t findLowerBound(size_t begin, size_t end, const Bound &bound) {
        checkBounds(begin, end);

        return std::min(base.findLowerBound(subBegin + begin, subBegin + end, bound) - subBegin, subSize);
    }

    Fingerprint fingerprint(size_t begin, size_t end) {
        checkBounds(begin, end);

        return base.fingerprint(subBegin + begin, subBegin + end);
    }

  private:
    void checkBounds(size_t begin, size_t end) {
        if (begin > end || end > subSize) throw negentropy::err("bad range");
    }
};


}}
