#pragma once

#include <map>

#include "lmdbxx/lmdb++.h"

#include "negentropy.h"
#include "negentropy/storage/btree/core.h"


namespace negentropy { namespace storage {

using err = std::runtime_error;
using Node = negentropy::storage::btree::Node;
using NodePtr = negentropy::storage::btree::NodePtr;


struct BTreeLMDB : btree::BTreeCore {
    lmdb::txn &txn;
    lmdb::dbi dbi;
    uint64_t treeId;

    struct MetaData {
        uint64_t rootNodeId;
        uint64_t nextNodeId;

        bool operator==(const MetaData &other) const {
            return rootNodeId == other.rootNodeId && nextNodeId == other.nextNodeId;
        }
    };

    MetaData metaDataCache;
    MetaData origMetaData;
    std::map<uint64_t, Node> dirtyNodeCache;


    static lmdb::dbi setupDB(lmdb::txn &txn, std::string_view tableName) {
        return lmdb::dbi::open(txn, tableName, MDB_CREATE | MDB_REVERSEKEY);
    }

    BTreeLMDB(lmdb::txn &txn, lmdb::dbi dbi, uint64_t treeId) : txn(txn), dbi(dbi), treeId(treeId) {
        static_assert(sizeof(MetaData) == 16);
        std::string_view v;
        bool found = dbi.get(txn, getKey(0), v);
        metaDataCache = found ? lmdb::from_sv<MetaData>(v) : MetaData{ 0, 1, };
        origMetaData = metaDataCache;
    }

    ~BTreeLMDB() {
        flush();
    }

    void flush() {
        for (auto &[nodeId, node] : dirtyNodeCache) {
            dbi.put(txn, getKey(nodeId), node.sv());
        }
        dirtyNodeCache.clear();

        if (metaDataCache != origMetaData) {
            dbi.put(txn, getKey(0), lmdb::to_sv<MetaData>(metaDataCache));
            origMetaData = metaDataCache;
        }
    }


    // Interface

    const btree::NodePtr getNodeRead(uint64_t nodeId) {
        if (nodeId == 0) return {nullptr, 0};

        auto res = dirtyNodeCache.find(nodeId);
        if (res != dirtyNodeCache.end()) return NodePtr{&res->second, nodeId};

        std::string_view sv;
        bool found = dbi.get(txn, getKey(nodeId), sv);
        if (!found) throw err("couldn't find node");
        return NodePtr{(Node*)sv.data(), nodeId};
    }

    btree::NodePtr getNodeWrite(uint64_t nodeId) {
        if (nodeId == 0) return {nullptr, 0};

        {
            auto res = dirtyNodeCache.find(nodeId);
            if (res != dirtyNodeCache.end()) return NodePtr{&res->second, nodeId};
        }

        std::string_view sv;
        bool found = dbi.get(txn, getKey(nodeId), sv);
        if (!found) throw err("couldn't find node");

        auto res = dirtyNodeCache.try_emplace(nodeId);
        Node *newNode = &res.first->second;
        memcpy(newNode, sv.data(), sizeof(Node));

        return NodePtr{newNode, nodeId};
    }

    btree::NodePtr makeNode() {
        uint64_t nodeId = metaDataCache.nextNodeId++;
        auto res = dirtyNodeCache.try_emplace(nodeId);
        return NodePtr{&res.first->second, nodeId};
    }

    void deleteNode(uint64_t nodeId) {
        if (nodeId == 0) throw err("can't delete metadata");
        dirtyNodeCache.erase(nodeId);
        dbi.del(txn, getKey(nodeId));
    }

    uint64_t getRootNodeId() {
        return metaDataCache.rootNodeId;
    }

    void setRootNodeId(uint64_t newRootNodeId) {
        metaDataCache.rootNodeId = newRootNodeId;
    }

    // Internal utils

  private:
    std::string getKey(uint64_t n) {
        uint64_t treeIdCopy = treeId;

        if constexpr (std::endian::native == std::endian::big) {
            auto byteswap = [](uint64_t &n) {
                uint8_t *first = reinterpret_cast<uint8_t*>(&n);
                uint8_t *last = first + 8;
                std::reverse(first, last);
            };

            byteswap(n);
            byteswap(treeIdCopy);
        } else {
            static_assert(std::endian::native == std::endian::little);
        }

        std::string k;
        k += lmdb::to_sv<uint64_t>(treeIdCopy);
        k += lmdb::to_sv<uint64_t>(n);
        return k;
    }
};


}}
