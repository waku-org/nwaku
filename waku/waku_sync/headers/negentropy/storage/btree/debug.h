#pragma once

#include <iostream>
#include <set>

#include <hoytech/hex.h>

#include "negentropy/storage/btree/core.h"
#include "negentropy/storage/BTreeMem.h"
#include "negentropy/storage/BTreeLMDB.h"


namespace negentropy { namespace storage { namespace btree {


using err = std::runtime_error;


inline void dump(BTreeCore &btree, uint64_t nodeId, int depth) {
    if (nodeId == 0) {
        if (depth == 0) std::cout << "EMPTY TREE" << std::endl;
        return;
    }

    auto nodePtr = btree.getNodeRead(nodeId);
    auto &node = nodePtr.get();
    std::string indent(depth * 4, ' ');

    std::cout << indent << "NODE id=" << nodeId << " numItems=" << node.numItems << " accum=" << hoytech::to_hex(node.accum.sv()) << " accumCount=" << node.accumCount << std::endl;

    for (size_t i = 0; i < node.numItems; i++) {
        std::cout << indent << "  item: " << node.items[i].item.timestamp << "," << hoytech::to_hex(node.items[i].item.getId()) << std::endl;
        dump(btree, node.items[i].nodeId, depth + 1);
    }
}

inline void dump(BTreeCore &btree) {
    dump(btree, btree.getRootNodeId(), 0);
}


struct VerifyContext {
    std::optional<uint64_t> leafDepth;
    std::set<uint64_t> allNodeIds;
    std::vector<uint64_t> leafNodeIds;
};

inline void verify(BTreeCore &btree, uint64_t nodeId, uint64_t depth, VerifyContext &ctx, Accumulator *accumOut = nullptr, uint64_t *accumCountOut = nullptr) {
    if (nodeId == 0) return;

    if (ctx.allNodeIds.contains(nodeId)) throw err("verify: saw node id again");
    ctx.allNodeIds.insert(nodeId);

    auto nodePtr = btree.getNodeRead(nodeId);
    auto &node = nodePtr.get();

    if (node.numItems == 0) throw err("verify: empty node");
    if (node.nextSibling && node.numItems < MIN_ITEMS) throw err("verify: too few items in node");
    if (node.numItems > MAX_ITEMS) throw err("verify: too many items");

    if (node.items[0].nodeId == 0) {
        if (ctx.leafDepth) {
            if (*ctx.leafDepth != depth) throw err("verify: mismatch of leaf depth");
        } else {
            ctx.leafDepth = depth;
        }

        ctx.leafNodeIds.push_back(nodeId);
    }

    // FIXME: verify unused items are zeroed

    Accumulator accum;
    accum.setToZero();
    uint64_t accumCount = 0;

    for (size_t i = 0; i < node.numItems; i++) {
        uint64_t childNodeId = node.items[i].nodeId;
        if (childNodeId == 0) {
            accum.add(node.items[i].item);
            accumCount++;
        } else {
            {
                auto firstChildPtr = btree.getNodeRead(childNodeId);
                auto &firstChild = firstChildPtr.get();
                if (firstChild.numItems == 0 || firstChild.items[0].item != node.items[i].item) throw err("verify: key does not match child's first key");
            }
            verify(btree, childNodeId, depth + 1, ctx, &accum, &accumCount);
        }

        if (i < node.numItems - 1) {
            if (!(node.items[i].item < node.items[i + 1].item)) throw err("verify: items out of order");
        }
    }

    for (size_t i = node.numItems; i < MAX_ITEMS + 1; i++) {
        for (size_t j = 0; j < sizeof(Key); j++) if (((char*)&node.items[i])[j] != '\0') throw err("verify: memory not zeroed out");
    }

    if (accumCount != node.accumCount) throw err("verify: accumCount mismatch");
    if (accum.sv() != node.accum.sv()) throw err("verify: accum mismatch");

    if (accumOut) accumOut->add(accum);
    if (accumCountOut) *accumCountOut += accumCount;
}

inline void verify(BTreeCore &btree, bool isLMDB) {
    VerifyContext ctx;
    Accumulator accum;
    accum.setToZero();
    uint64_t accumCount = 0;

    verify(btree, btree.getRootNodeId(), 0, ctx, &accum, &accumCount);

    if (ctx.leafNodeIds.size()) {
        uint64_t i = 0, totalItems = 0;
        auto nodePtr = btree.getNodeRead(ctx.leafNodeIds[0]);
        std::optional<Item> prevItem;
        uint64_t prevSibling = 0;

        while (nodePtr.exists()) {
            auto &node = nodePtr.get();
            if (nodePtr.nodeId != ctx.leafNodeIds[i]) throw err("verify: leaf id mismatch");

            if (prevSibling != node.prevSibling) throw err("verify: prevSibling mismatch");
            prevSibling = nodePtr.nodeId;

            nodePtr = btree.getNodeRead(node.nextSibling);
            i++;

            for (size_t j = 0; j < node.numItems; j++) {
                if (prevItem && !(*prevItem < node.items[j].item)) throw err("verify: leaf item out of order");
                prevItem = node.items[j].item;
                totalItems++;
            }
        }

        if (totalItems != accumCount) throw err("verify: leaf count mismatch");
    }

    // Check for leaks

    if (isLMDB) {
        static_assert(std::endian::native == std::endian::little); // FIXME

        auto &btreeLMDB = dynamic_cast<BTreeLMDB&>(btree);
        btreeLMDB.flush();

        std::string_view key, val;

        // Leaks

        auto cursor = lmdb::cursor::open(btreeLMDB.txn, btreeLMDB.dbi);

        if (cursor.get(key, val, MDB_FIRST)) {
            do {
                uint64_t nodeId = lmdb::from_sv<uint64_t>(key.substr(8));
                if (nodeId != 0 && !ctx.allNodeIds.contains(nodeId)) throw err("verify: memory leak");
            } while (cursor.get(key, val, MDB_NEXT));
        }

        // Dangling

        for (const auto &k : ctx.allNodeIds) {
            std::string tpKey;
            tpKey += lmdb::to_sv(btreeLMDB.treeId);
            tpKey += lmdb::to_sv(k);
            if (!btreeLMDB.dbi.get(btreeLMDB.txn, tpKey, val)) throw err("verify: dangling node");
        }
    } else {
        auto &btreeMem = dynamic_cast<BTreeMem&>(btree);

        // Leaks

        for (const auto &[k, v] : btreeMem._nodeStorageMap) {
            if (!ctx.allNodeIds.contains(k)) throw err("verify: memory leak");
        }

        // Dangling

        for (const auto &k : ctx.allNodeIds) {
            if (!btreeMem._nodeStorageMap.contains(k)) throw err("verify: dangling node");
        }
    }
}



}}}
