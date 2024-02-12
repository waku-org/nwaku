#pragma once

#include <algorithm>

#include "negentropy.h"



namespace negentropy { namespace storage { namespace btree {

using err = std::runtime_error;

/*

Each node contains an array of keys. For leaf nodes, the keys are 0. For non-leaf nodes, these will
be the nodeIds of the children leaves. The items in the keys of non-leaf nodes are the first items
in the corresponding child nodes.

Except for the right-most nodes in the tree at each level (which includes the root node), all nodes
contain at least MIN_ITEMS and at most MAX_ITEMS.

If a node falls below MIN_ITEMS, a neighbour node (which always has the same parent) is selected.
  * If between the two nodes there are REBALANCE_THRESHOLD or fewer total items, all items are
    moved into one node and the other is deleted.
  * If there are more than REBALANCE_THRESHOLD total items, then the items are divided into two
    approximately equal-sized halves.

If a node goes above MAX_ITEMS then a new neighbour node is created.
  * If the node is the right-most in its level, pack the old node to MAX_ITEMS, and move the rest
    into the new neighbour. This optimises space-usage in the case of append workloads.
  * Otherwise, split the node into two approximately equal-sized halves.

*/


#ifdef NE_FUZZ_TEST

// Fuzz test mode: Causes a large amount of tree structure changes like splitting, moving, and rebalancing

const size_t MIN_ITEMS = 2;
const size_t REBALANCE_THRESHOLD = 4;
const size_t MAX_ITEMS = 6;

#else

// Production mode: Nodes fit into 4k pages, and oscillating insert/erase will not cause tree structure changes

const size_t MIN_ITEMS = 30;
const size_t REBALANCE_THRESHOLD = 60;
const size_t MAX_ITEMS = 80;

#endif

static_assert(MIN_ITEMS < REBALANCE_THRESHOLD);
static_assert(REBALANCE_THRESHOLD < MAX_ITEMS);
static_assert(MAX_ITEMS / 2 > MIN_ITEMS);
static_assert(MIN_ITEMS % 2 == 0 && REBALANCE_THRESHOLD % 2 == 0 && MAX_ITEMS % 2 == 0);


struct Key {
    Item item;
    uint64_t nodeId;

    void setToZero() {
        item = Item();
        nodeId = 0;
    }
};

inline bool operator<(const Key &a, const Key &b) {
    return a.item < b.item;
};

struct Node {
    uint64_t numItems; // Number of items in this Node
    uint64_t accumCount; // Total number of items in or under this Node
    uint64_t nextSibling; // Pointer to next node in this level
    uint64_t prevSibling; // Pointer to previous node in this level

    Accumulator accum;

    Key items[MAX_ITEMS + 1];


    Node() {
        memset((void*)this, '\0', sizeof(*this));
    }

    std::string_view sv() {
        return std::string_view(reinterpret_cast<char*>(this), sizeof(*this));
    }
};

struct NodePtr {
    Node *p;
    uint64_t nodeId;


    bool exists() {
        return p != nullptr;
    }

    Node &get() const {
        return *p;
    }
};

struct Breadcrumb {
    size_t index;
    NodePtr nodePtr;
};


struct BTreeCore : StorageBase {
    //// Node Storage

    virtual const NodePtr getNodeRead(uint64_t nodeId) = 0;

    virtual NodePtr getNodeWrite(uint64_t nodeId) = 0;

    virtual NodePtr makeNode() = 0;

    virtual void deleteNode(uint64_t nodeId) = 0;

    virtual uint64_t getRootNodeId() = 0;

    virtual void setRootNodeId(uint64_t newRootNodeId) = 0;


    //// Search

    std::vector<Breadcrumb> searchItem(uint64_t rootNodeId, const Item &newItem, bool &found) {
        found = false;
        std::vector<Breadcrumb> breadcrumbs;

        auto foundNode = getNodeRead(rootNodeId);

        while (foundNode.nodeId) {
            const auto &node = foundNode.get();
            size_t index = node.numItems - 1;

            if (node.numItems > 1) {
                for (size_t i = 1; i < node.numItems + 1; i++) {
                    if (i == node.numItems + 1 || newItem < node.items[i].item) {
                        index = i - 1;
                        break;
                    }
                }
            }

            if (!found && (newItem == node.items[index].item)) found = true;

            breadcrumbs.push_back({index, foundNode});
            foundNode = getNodeRead(node.items[index].nodeId);
        }

        return breadcrumbs;
    }


    //// Insert

    bool insert(uint64_t createdAt, std::string_view id) {
        return insertItem(Item(createdAt, id));
    }

    bool insertItem(const Item &newItem) {
        // Make root leaf in case it doesn't exist

        auto rootNodeId = getRootNodeId();

        if (!rootNodeId) {
            auto newNodePtr = makeNode();
            auto &newNode = newNodePtr.get();

            newNode.items[0].item = newItem;
            newNode.numItems++;
            newNode.accum.add(newItem);
            newNode.accumCount = 1;

            setRootNodeId(newNodePtr.nodeId);
            return true;
        }


        // Traverse interior nodes, leaving breadcrumbs along the way


        bool found;
        auto breadcrumbs = searchItem(rootNodeId, newItem, found);

        if (found) return false; // already inserted


        // Follow breadcrumbs back to root

        Key newKey = { newItem, 0 };
        bool needsMerge = true;

        while (breadcrumbs.size()) {
            auto crumb = breadcrumbs.back();
            breadcrumbs.pop_back();

            auto &node = getNodeWrite(crumb.nodePtr.nodeId).get();

            if (!needsMerge) {
                node.accum.add(newItem);
                node.accumCount++;
            } else if (crumb.nodePtr.get().numItems < MAX_ITEMS) {
                // Happy path: Node has room for new item

                node.items[node.numItems] = newKey;
                std::inplace_merge(node.items, node.items + node.numItems, node.items + node.numItems + 1);
                node.numItems++;

                node.accum.add(newItem);
                node.accumCount++;

                needsMerge = false;
            } else {
                // Node is full: Split it into 2

                auto &left = node;
                auto rightPtr = makeNode();
                auto &right = rightPtr.get();

                left.items[MAX_ITEMS] = newKey;
                std::inplace_merge(left.items, left.items + MAX_ITEMS, left.items + MAX_ITEMS + 1);

                left.accum.setToZero();
                left.accumCount = 0;

                if (!left.nextSibling) {
                    // If right-most node, pack as tightly as possible to optimise for append workloads
                    left.numItems = MAX_ITEMS;
                    right.numItems = 1;
                } else {
                    // Otherwise, split the node equally
                    left.numItems = (MAX_ITEMS / 2) + 1;
                    right.numItems = MAX_ITEMS / 2;
                }

                for (size_t i = 0; i < left.numItems; i++) {
                    addToAccum(left.items[i], left);
                }

                for (size_t i = 0; i < right.numItems; i++) {
                    right.items[i] = left.items[left.numItems + i];
                    addToAccum(right.items[i], right);
                }

                for (size_t i = left.numItems; i < MAX_ITEMS + 1; i++) left.items[i].setToZero();

                right.nextSibling = left.nextSibling;
                left.nextSibling = rightPtr.nodeId;
                right.prevSibling = crumb.nodePtr.nodeId;

                if (right.nextSibling) {
                    auto &rightRight = getNodeWrite(right.nextSibling).get();
                    rightRight.prevSibling = rightPtr.nodeId;
                }

                newKey = { right.items[0].item, rightPtr.nodeId };
            }

            // Update left-most key, in case item was inserted at the beginning

            refreshIndex(node, 0);
        }

        // Out of breadcrumbs but still need to merge: New level required

        if (needsMerge) {
            auto &left = getNodeRead(rootNodeId).get();
            auto &right = getNodeRead(newKey.nodeId).get();

            auto newRootPtr = makeNode();
            auto &newRoot = newRootPtr.get();
            newRoot.numItems = 2;

            newRoot.accum.add(left.accum);
            newRoot.accum.add(right.accum);
            newRoot.accumCount = left.accumCount + right.accumCount;

            newRoot.items[0] = left.items[0];
            newRoot.items[0].nodeId = rootNodeId;
            newRoot.items[1] = right.items[0];
            newRoot.items[1].nodeId = newKey.nodeId;

            setRootNodeId(newRootPtr.nodeId);
        }

        return true;
    }



    /// Erase

    bool erase(uint64_t createdAt, std::string_view id) {
        return eraseItem(Item(createdAt, id));
    }

    bool eraseItem(const Item &oldItem) {
        auto rootNodeId = getRootNodeId();
        if (!rootNodeId) return false;


        // Traverse interior nodes, leaving breadcrumbs along the way

        bool found;
        auto breadcrumbs = searchItem(rootNodeId, oldItem, found);
        if (!found) return false;


        // Remove from node

        bool needsRemove = true;
        bool neighbourRefreshNeeded = false;

        while (breadcrumbs.size()) {
            auto crumb = breadcrumbs.back();
            breadcrumbs.pop_back();

            auto &node = getNodeWrite(crumb.nodePtr.nodeId).get();

            if (!needsRemove) {
                node.accum.sub(oldItem);
                node.accumCount--;
            } else {
                for (size_t i = crumb.index + 1; i < node.numItems; i++) node.items[i - 1] = node.items[i];
                node.numItems--;
                node.items[node.numItems].setToZero();

                node.accum.sub(oldItem);
                node.accumCount--;

                needsRemove = false;
            }


            if (crumb.index < node.numItems) refreshIndex(node, crumb.index);

            if (neighbourRefreshNeeded) {
                refreshIndex(node, crumb.index + 1);
                neighbourRefreshNeeded = false;
            }


            if (node.numItems < MIN_ITEMS && breadcrumbs.size() && breadcrumbs.back().nodePtr.get().numItems > 1) {
                auto rebalance = [&](Node &leftNode, Node &rightNode) {
                    size_t totalItems = leftNode.numItems + rightNode.numItems;
                    size_t numLeft = (totalItems + 1) / 2;
                    size_t numRight = totalItems - numLeft;

                    Accumulator accum;
                    accum.setToZero();
                    uint64_t accumCount = 0;

                    if (rightNode.numItems >= numRight) {
                        // Move extra from right to left

                        size_t numMove = rightNode.numItems - numRight;

                        for (size_t i = 0; i < numMove; i++) {
                            auto &item = rightNode.items[i];
                            if (item.nodeId == 0) {
                                accum.add(item.item);
                                accumCount++;
                            } else {
                                auto &movingNode = getNodeRead(item.nodeId).get();
                                accum.add(movingNode.accum);
                                accumCount += movingNode.accumCount;
                            }
                            leftNode.items[leftNode.numItems + i] = item;
                        }

                        ::memmove(rightNode.items, rightNode.items + numMove, (rightNode.numItems - numMove) * sizeof(rightNode.items[0]));

                        for (size_t i = numRight; i < rightNode.numItems; i++) rightNode.items[i].setToZero();

                        leftNode.accum.add(accum);
                        rightNode.accum.sub(accum);

                        leftNode.accumCount += accumCount;
                        rightNode.accumCount -= accumCount;

                        neighbourRefreshNeeded = true;
                    } else {
                        // Move extra from left to right

                        size_t numMove = leftNode.numItems - numLeft;

                        ::memmove(rightNode.items + numMove, rightNode.items, rightNode.numItems * sizeof(rightNode.items[0]));

                        for (size_t i = 0; i < numMove; i++) {
                            auto &item = leftNode.items[numLeft + i];
                            if (item.nodeId == 0) {
                                accum.add(item.item);
                                accumCount++;
                            } else {
                                auto &movingNode = getNodeRead(item.nodeId).get();
                                accum.add(movingNode.accum);
                                accumCount += movingNode.accumCount;
                            }
                            rightNode.items[i] = item;
                        }

                        for (size_t i = numLeft; i < leftNode.numItems; i++) leftNode.items[i].setToZero();

                        leftNode.accum.sub(accum);
                        rightNode.accum.add(accum);

                        leftNode.accumCount -= accumCount;
                        rightNode.accumCount += accumCount;
                    }

                    leftNode.numItems = numLeft;
                    rightNode.numItems = numRight;
                };

                if (breadcrumbs.back().index == 0) {
                    // Use neighbour to the right

                    auto &leftNode = node;
                    auto &rightNode = getNodeWrite(node.nextSibling).get();
                    size_t totalItems = leftNode.numItems + rightNode.numItems;

                    if (totalItems <= REBALANCE_THRESHOLD) {
                        // Move all items into right

                        ::memmove(rightNode.items + leftNode.numItems, rightNode.items, sizeof(rightNode.items[0]) * rightNode.numItems);
                        ::memcpy(rightNode.items, leftNode.items, sizeof(leftNode.items[0]) * leftNode.numItems);

                        rightNode.numItems += leftNode.numItems;
                        rightNode.accumCount += leftNode.accumCount;
                        rightNode.accum.add(leftNode.accum);

                        if (leftNode.prevSibling) getNodeWrite(leftNode.prevSibling).get().nextSibling = leftNode.nextSibling;
                        rightNode.prevSibling = leftNode.prevSibling;

                        leftNode.numItems = 0;
                    } else {
                        // Rebalance from left to right

                        rebalance(leftNode, rightNode);
                    }
                } else {
                    // Use neighbour to the left

                    auto &leftNode = getNodeWrite(node.prevSibling).get();
                    auto &rightNode = node;
                    size_t totalItems = leftNode.numItems + rightNode.numItems;

                    if (totalItems <= REBALANCE_THRESHOLD) {
                        // Move all items into left

                        ::memcpy(leftNode.items + leftNode.numItems, rightNode.items, sizeof(rightNode.items[0]) * rightNode.numItems);

                        leftNode.numItems += rightNode.numItems;
                        leftNode.accumCount += rightNode.accumCount;
                        leftNode.accum.add(rightNode.accum);

                        if (rightNode.nextSibling) getNodeWrite(rightNode.nextSibling).get().prevSibling = rightNode.prevSibling;
                        leftNode.nextSibling = rightNode.nextSibling;

                        rightNode.numItems = 0;
                    } else {
                        // Rebalance from right to left

                        rebalance(leftNode, rightNode);
                    }
                }
            }

            if (node.numItems == 0) {
                if (node.prevSibling) getNodeWrite(node.prevSibling).get().nextSibling = node.nextSibling;
                if (node.nextSibling) getNodeWrite(node.nextSibling).get().prevSibling = node.prevSibling;

                needsRemove = true;

                deleteNode(crumb.nodePtr.nodeId);
            }
        }

        if (needsRemove) {
            setRootNodeId(0);
        } else {
            auto &node = getNodeRead(rootNodeId).get();

            if (node.numItems == 1 && node.items[0].nodeId) {
                setRootNodeId(node.items[0].nodeId);
                deleteNode(rootNodeId);
            }
        }

        return true;
    }


    //// Compat with the vector interface

    void seal() {
    }

    void unseal() {
    }


    //// Utils

    void refreshIndex(Node &node, size_t index) {
        auto childNodePtr = getNodeRead(node.items[index].nodeId);
        if (childNodePtr.exists()) {
            auto &childNode = childNodePtr.get();
            node.items[index].item = childNode.items[0].item;
        }
    }

    void addToAccum(const Key &k, Node &node) {
        if (k.nodeId == 0) {
            node.accum.add(k.item);
            node.accumCount++;
        } else {
            auto nodePtr = getNodeRead(k.nodeId);
            node.accum.add(nodePtr.get().accum);
            node.accumCount += nodePtr.get().accumCount;
        }
    }

    void traverseToOffset(size_t index, const std::function<void(Node &node, size_t index)> &cb, std::function<void(Node &)> customAccum = nullptr) {
        auto rootNodePtr = getNodeRead(getRootNodeId());
        if (!rootNodePtr.exists()) return;
        auto &rootNode = rootNodePtr.get();

        if (index > rootNode.accumCount) throw err("out of range");
        return traverseToOffsetAux(index, rootNode, cb, customAccum);
    }

    void traverseToOffsetAux(size_t index, Node &node, const std::function<void(Node &node, size_t index)> &cb, std::function<void(Node &)> customAccum) {
        if (node.numItems == node.accumCount) {
            cb(node, index);
            return;
        }

        for (size_t i = 0; i < node.numItems; i++) {
            auto &child = getNodeRead(node.items[i].nodeId).get();
            if (index < child.accumCount) return traverseToOffsetAux(index, child, cb, customAccum);
            index -= child.accumCount;
            if (customAccum) customAccum(child);
        }
    }



    //// Interface

    uint64_t size() {
        auto rootNodePtr = getNodeRead(getRootNodeId());
        if (!rootNodePtr.exists()) return 0;
        auto &rootNode = rootNodePtr.get();
        return rootNode.accumCount;
    }

    const Item &getItem(size_t index) {
        if (index >= size()) throw err("out of range");

        Item *out;
        traverseToOffset(index, [&](Node &node, size_t index){
            out = &node.items[index].item;
        });
        return *out;
    }

    void iterate(size_t begin, size_t end, std::function<bool(const Item &, size_t)> cb) {
        checkBounds(begin, end);

        size_t num = end - begin;

        traverseToOffset(begin, [&](Node &node, size_t index){
            Node *currNode = &node;
            for (size_t i = 0; i < num; i++) {
                if (!cb(currNode->items[index].item, begin + i)) return;
                index++;
                if (index >= currNode->numItems) {
                    currNode = getNodeRead(currNode->nextSibling).p;
                    index = 0;
                }
            }
        });
    }

    size_t findLowerBound(size_t begin, size_t end, const Bound &value) {
        checkBounds(begin, end);

        auto rootNodePtr = getNodeRead(getRootNodeId());
        if (!rootNodePtr.exists()) return end;
        auto &rootNode = rootNodePtr.get();
        if (value.item <= rootNode.items[0].item) return begin;
        return std::min(findLowerBoundAux(value, rootNodePtr, 0), end);
    }

    size_t findLowerBoundAux(const Bound &value, NodePtr nodePtr, uint64_t numToLeft) {
        if (!nodePtr.exists()) return numToLeft + 1;

        Node &node = nodePtr.get();

        for (size_t i = 1; i < node.numItems; i++) {
            if (value.item <= node.items[i].item) {
                return findLowerBoundAux(value, getNodeRead(node.items[i - 1].nodeId), numToLeft);
            } else {
                if (node.items[i - 1].nodeId) numToLeft += getNodeRead(node.items[i - 1].nodeId).get().accumCount;
                else numToLeft++;
            }
        }

        return findLowerBoundAux(value, getNodeRead(node.items[node.numItems - 1].nodeId), numToLeft);
    }

    Fingerprint fingerprint(size_t begin, size_t end) {
        checkBounds(begin, end);

        auto getAccumLeftOf = [&](size_t index) {
            Accumulator accum;
            accum.setToZero();

            traverseToOffset(index, [&](Node &node, size_t index){
                for (size_t i = 0; i < index; i++) accum.add(node.items[i].item);
            }, [&](Node &node){
                accum.add(node.accum);
            });

            return accum;
        };

        auto accum1 = getAccumLeftOf(begin);
        auto accum2 = getAccumLeftOf(end);

        accum1.negate();
        accum2.add(accum1);

        return accum2.getFingerprint(end - begin);
    }

  private:
    void checkBounds(size_t begin, size_t end) {
        if (begin > end || end > size()) throw negentropy::err("bad range");
    }
};


}}}
