#pragma once

#include "negentropy.h"
#include "negentropy/storage/btree/core.h"


namespace negentropy { namespace storage {


struct BTreeMem : btree::BTreeCore {
    std::unordered_map<uint64_t, btree::Node> _nodeStorageMap;
    uint64_t _rootNodeId = 0; // 0 means no root
    uint64_t _nextNodeId = 1;

    // Interface

    const btree::NodePtr getNodeRead(uint64_t nodeId) {
        if (nodeId == 0) return {nullptr, 0};
        auto res = _nodeStorageMap.find(nodeId);
        if (res == _nodeStorageMap.end()) return btree::NodePtr{nullptr, 0};
        return btree::NodePtr{&res->second, nodeId};
    }

    btree::NodePtr getNodeWrite(uint64_t nodeId) {
        return getNodeRead(nodeId);
    }

    btree::NodePtr makeNode() {
        uint64_t nodeId = _nextNodeId++;
        _nodeStorageMap.try_emplace(nodeId);
        return getNodeRead(nodeId);
    }

    void deleteNode(uint64_t nodeId) {
        _nodeStorageMap.erase(nodeId);
    }

    uint64_t getRootNodeId() {
        return _rootNodeId;
    }

    void setRootNodeId(uint64_t newRootNodeId) {
        _rootNodeId = newRootNodeId;
    }
};


}}
