#pragma once

#include "negentropy.h"



namespace negentropy { namespace storage {


struct Vector : StorageBase {
    std::vector<Item> items;
    bool sealed = false;

    void insert(uint64_t createdAt, std::string_view id) {
        if (sealed) throw negentropy::err("already sealed");
        if (id.size() != ID_SIZE) throw negentropy::err("bad id size for added item");
        items.emplace_back(createdAt, id);
    }

    void insertItem(const Item &item) {
        insert(item.timestamp, item.getId());
    }

    void seal() {
        if (sealed) throw negentropy::err("already sealed");
        sealed = true;

        std::sort(items.begin(), items.end());

        for (size_t i = 1; i < items.size(); i++) {
            if (items[i - 1] == items[i]) throw negentropy::err("duplicate item inserted");
        }
    }

    void unseal() {
        sealed = false;
    }

    uint64_t size() {
        checkSealed();
        return items.size();
    }

    const Item &getItem(size_t i) {
        checkSealed();
        return items.at(i);
    }

    void iterate(size_t begin, size_t end, std::function<bool(const Item &, size_t)> cb) {
        checkSealed();
        checkBounds(begin, end);

        for (auto i = begin; i < end; ++i) {
            if (!cb(items[i], i)) break;
        }
    }

    size_t findLowerBound(size_t begin, size_t end, const Bound &bound) {
        checkSealed();
        checkBounds(begin, end);

        return std::lower_bound(items.begin() + begin, items.begin() + end, bound.item) - items.begin();
    }

    Fingerprint fingerprint(size_t begin, size_t end) {
        Accumulator out;
        out.setToZero();

        iterate(begin, end, [&](const Item &item, size_t){
            out.add(item);
            return true;
        });

        return out.getFingerprint(end - begin);
    }

  private:
    void checkSealed() {
        if (!sealed) throw negentropy::err("not sealed");
    }

    void checkBounds(size_t begin, size_t end) {
        if (begin > end || end > items.size()) throw negentropy::err("bad range");
    }
};


}}
