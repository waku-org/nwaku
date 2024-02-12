#pragma once

#include <functional>

#include "negentropy/types.h"


namespace negentropy {

struct StorageBase {
    virtual uint64_t size() = 0;

    virtual const Item &getItem(size_t i) = 0;

    virtual void iterate(size_t begin, size_t end, std::function<bool(const Item &, size_t)> cb) = 0;

    virtual size_t findLowerBound(size_t begin, size_t end, const Bound &value) = 0;

    virtual Fingerprint fingerprint(size_t begin, size_t end) = 0;
};

}
