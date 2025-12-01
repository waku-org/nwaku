# RLN FFI Migration Plan: v0.8.0 → master (v0.9.0+)

## Overview
This document outlines the complete migration plan for upgrading nwaku's RLN (Rate Limiting Nullifier) FFI from zerokit v0.8.0 to the master branch (post v0.9.0). The migration focuses on transitioning to a **stateless RLN** implementation that relies on smart contract-based Merkle trees instead of local tree management.

**Current Status:**
- **Current Version:** v0.8.0 (submodule at `a4bb3feb` which is v0.9.0 tag)
- **Target:** master branch (latest stateless features)
- **Migration Type:** Stateless (smart contract-based Merkle tree)
- **Build Feature:** `stateless,parallel` (no local tree)

---

## Key Changes Summary

### 1. **Keygen Functions - Now Independent from RLN Instance**
- **Old:** Required RLN instance to generate keys
- **New:** Standalone functions with endianness flag
- **Impact:** Functions can be called without creating RLN instance first

### 2. **Circuit Format - arkzkey Only**
- **Old:** Multiple formats with flags
- **New:** arkzkey is the only format (no flag needed)
- **Impact:** Simplified initialization

### 3. **Build Configuration - Stateless + Parallel**
- **Old:** `cargo build -p rln --release`
- **New:** `cargo build -p rln --release --no-default-features --features stateless,parallel`
- **Impact:** Must use `--no-default-features` to avoid default tree features

### 4. **Binary Assets - New Naming Convention**
- **Old:** `*-rln.tar.gz`
- **New:** `*-stateless-parallel-rln.*`
- **Impact:** Download URLs and filenames need updating

### 5. **Proof Functions - Stateless Variants Only**
- **Old:** Multiple proof generation/verification functions
- **New:** Only `generate_rln_proof_with_witness` and `verify_with_roots` for stateless
- **Impact:** Must provide Merkle path and roots from smart contract

### 6. **Tree Functions - Not Available in Stateless**
- **Old:** Local tree operations (set_leaf, get_leaf, etc.)
- **New:** Not available in stateless mode
- **Impact:** All tree data comes from smart contract

### 7. **Function Naming - New Prefix Convention**
- **Old:** `new`, `new_with_params`
- **New:** `ffi_rln_new`, `ffi_rln_new_with_params`
- **Impact:** All FFI function imports need updating

### 8. **Return Types - Enhanced Error Handling**
- **Old:** Simple bool returns
- **New:** Result types: `CResultVecCFrVecU8`, `CResultVecU8VecU8`, `CBoolResult`
- **Impact:** Better error handling, memory leak fixes

---

## Migration Phases

### **Phase 1: Preparation & Analysis** ⏱️ 2-3 days

#### 1.1 Understand Current Implementation
- [x] Review current `rln_interface.nim` (169 lines)
- [x] Review current `wrappers.nim` (194 lines)
- [x] Review `build_rln.sh` script
- [x] Document all current FFI function usages
- [ ] Map current functions to new FFI equivalents
- [ ] Identify functions that won't be available in stateless mode

#### 1.2 Study New FFI API
- [ ] Read zerokit master branch FFI documentation
- [ ] Review Nim example in zerokit repo
- [ ] Understand new return types and error handling
- [ ] Document memory management changes
- [ ] Understand endianness handling (use little-endian for now)

#### 1.3 Create Function Mapping Document
Create a detailed mapping of:
```
OLD FUNCTION → NEW FUNCTION → CHANGES REQUIRED
```

**Example Mappings:**

| Old Function | New Function | Status | Changes |
|--------------|--------------|--------|---------|
| `key_gen` | `extended_key_gen` | ✅ Available | Add endianness param (use `true` for little-endian) |
| `seeded_key_gen` | `seeded_extended_key_gen` | ✅ Available | Add endianness param |
| `new_circuit(tree_depth, buffer, ctx)` | `ffi_rln_new(ctx)` | ⚠️ Changed | No tree_depth or buffer needed in stateless |
| `new_circuit_from_data(zkey, vk, ctx)` | `ffi_rln_new_with_params(zkey, graph, ctx)` | ⚠️ Changed | vk_buffer removed, circom_buffer → graph_buffer |
| `generate_proof` | N/A | ❌ Not for stateless | Use `generate_rln_proof_with_witness` |
| `verify` | N/A | ❌ Not for stateless | Use `verify_with_roots` |
| `generate_proof_with_witness` | `generate_rln_proof_with_witness` | ✅ Available | Same name, check signature |
| `verify_with_roots` | `verify_with_roots` | ✅ Available | Now returns `CBoolResult` |
| `set_leaf`, `get_leaf`, etc. | N/A | ❌ Removed | Not available in stateless mode |

---

### **Phase 2: Build System Updates** ⏱️ 1 day

#### 2.1 Update Makefile
**File:** `/Users/darshan/work/nwaku/Makefile`

**Current (line 186):**
```makefile
LIBRLN_VERSION := v0.9.0
```

**Action:** Update to master branch or specific commit
```makefile
LIBRLN_VERSION := master  # or specific commit hash
```

#### 2.2 Update Build Script
**File:** `/Users/darshan/work/nwaku/scripts/build_rln.sh`

**Current (line 52):**
```bash
cargo build --release -p rln --manifest-path "${build_dir}/rln/Cargo.toml"
```

**Required Change:**
```bash
cargo build -p rln --release --no-default-features --features stateless,parallel --manifest-path "${build_dir}/rln/Cargo.toml"
```

**Critical:** The `--no-default-features` flag is essential to avoid including local tree features.

#### 2.3 Update Binary Download Logic
**File:** `/Users/darshan/work/nwaku/scripts/build_rln.sh`

**Current (line 22):**
```bash
tarball+="-rln.tar.gz"
```

**Required Change:**
```bash
tarball+="-stateless-parallel-rln.tar.gz"
```

#### 2.4 Update Submodule
```bash
cd vendor/zerokit
git checkout master
git pull origin master
cd ../..
git add vendor/zerokit
git commit -m "chore: update zerokit to master for new stateless FFI"
```

---

### **Phase 3: FFI Interface Updates** ⏱️ 3-4 days

#### 3.1 Update `rln_interface.nim`
**File:** `/Users/darshan/work/nwaku/waku/waku_rln_relay/rln/rln_interface.nim`

**Changes Required:**

##### A. Update Key Generation Functions (Lines 25-44)
```nim
# OLD
proc key_gen*(
  output_buffer: ptr Buffer, is_little_endian: bool
): bool {.importc: "extended_key_gen".}

proc seeded_key_gen*(
  input_buffer: ptr Buffer, output_buffer: ptr Buffer, is_little_endian: bool
): bool {.importc: "seeded_extended_key_gen".}
```

**Status:** ✅ These are already correct! Just verify they work with new FFI.

##### B. Update RLN Instance Creation (Lines 126-146)

**OLD - Stateful Version:**
```nim
proc new_circuit*(
  tree_depth: uint, input_buffer: ptr Buffer, ctx: ptr (ptr RLN)
): bool {.importc: "new".}
```

**NEW - Stateless Version:**
```nim
proc new_circuit*(ctx: ptr (ptr RLN)): bool {.importc: "ffi_rln_new".}
```

**OLD - With Parameters:**
```nim
proc new_circuit_from_data*(
  zkey_buffer: ptr Buffer, graph_buffer: ptr Buffer, ctx: ptr (ptr RLN)
): bool {.importc: "new_with_params".}
```

**NEW - With Parameters (Stateless):**
```nim
proc new_circuit_from_data*(
  zkey_buffer: ptr Buffer, graph_buffer: ptr Buffer, ctx: ptr (ptr RLN)
): bool {.importc: "ffi_rln_new_with_params".}
```

**Key Changes:**
- Function name: `new` → `ffi_rln_new`
- Function name: `new_with_params` → `ffi_rln_new_with_params`
- Removed: `tree_depth` parameter (not needed in stateless)
- Removed: `vk_buffer` parameter (zerokit extracts it from zkey)
- Changed: `circom_buffer` → `graph_buffer` (graph.bin file)

##### C. Update Proof Generation (Lines 46-72)

**Remove or Mark as Unavailable:**
```nim
# This function is NOT available in stateless mode
# proc generate_proof*(
#   ctx: ptr RLN, input_buffer: ptr Buffer, output_buffer: ptr Buffer
# ): bool {.importc: "generate_rln_proof".}
```

**Keep Only Stateless Version:**
```nim
proc generate_proof_with_witness*(
  ctx: ptr RLN, input_buffer: ptr Buffer, output_buffer: ptr Buffer
): bool {.importc: "generate_rln_proof_with_witness".}
```

**Input Buffer Format (RLN-v2):**
```
[ identity_secret<32> | user_message_limit<32> | message_id<32> | 
  path_elements<Vec<32>> | identity_path_index<Vec<1>> | 
  x<32> | external_nullifier<32> ]
```

**Output Buffer Format:**
```
[ proof<128> | root<32> | external_nullifier<32> | 
  share_x<32> | share_y<32> | nullifier<32> ]
```

##### D. Update Proof Verification (Lines 74-98)

**Remove or Mark as Unavailable:**
```nim
# This function is NOT available in stateless mode
# proc verify*(
#   ctx: ptr RLN, proof_buffer: ptr Buffer, proof_is_valid_ptr: ptr bool
# ): bool {.importc: "verify_rln_proof".}
```

**Update Return Type for Stateless Version:**
```nim
# OLD
proc verify_with_roots*(
  ctx: ptr RLN,
  proof_buffer: ptr Buffer,
  roots_buffer: ptr Buffer,
  proof_is_valid_ptr: ptr bool,
): bool {.importc: "verify_with_roots".}

# NEW - Returns CBoolResult instead of bool
# Need to define CBoolResult type first
type CBoolResult* = object
  value*: bool
  error*: cstring

proc verify_with_roots*(
  ctx: ptr RLN,
  proof_buffer: ptr Buffer,
  roots_buffer: ptr Buffer,
): CBoolResult {.importc: "ffi_verify_with_roots".}
```

**Input Format:**
```
proof_buffer: [ proof<128> | root<32> | external_nullifier<32> | 
                share_x<32> | share_y<32> | nullifier<32> | 
                signal_len<8> | signal<var> ]
roots_buffer: [ root1<32> | root2<32> | ... | rootN<32> ]
```

##### E. Remove Tree Functions (Lines 176-191)

**These are NOT available in stateless mode:**
```nim
# REMOVE THESE - Not available in stateless mode
# - set_leaf
# - get_leaf  
# - delete_leaf
# - set_tree
# - leaves_set
# - get_root
# - set_metadata
# - get_metadata
# - flush
```

##### F. Update Hash Functions (Lines 148-168)

**Verify these still work (should be unchanged):**
```nim
proc sha256*(
  input_buffer: ptr Buffer, output_buffer: ptr Buffer, is_little_endian: bool
): bool {.importc: "hash".}

proc poseidon*(
  input_buffer: ptr Buffer, output_buffer: ptr Buffer, is_little_endian: bool
): bool {.importc: "poseidon_hash".}
```

#### 3.2 Add New Result Types

**Add to `rln_interface.nim` after Buffer definition:**

```nim
# New result types for better error handling
type CResultVecCFrVecU8* = object
  value*: ptr UncheckedArray[byte]
  len*: uint
  error*: cstring

type CResultVecU8VecU8* = object
  value*: ptr UncheckedArray[byte]
  len*: uint
  error*: cstring

type CBoolResult* = object
  value*: bool
  error*: cstring

# Helper functions for working with vecFr
proc bytes_le_to_vec_cfr*(
  input_buffer: ptr Buffer
): CResultVecCFrVecU8 {.importc: "ffi_bytes_le_to_vec_cfr".}

proc bytes_be_to_vec_cfr*(
  input_buffer: ptr Buffer
): CResultVecCFrVecU8 {.importc: "ffi_bytes_be_to_vec_cfr".}

proc bytes_le_to_vec_u8*(
  input_buffer: ptr Buffer
): CResultVecU8VecU8 {.importc: "ffi_bytes_le_to_vec_u8".}

proc bytes_be_to_vec_u8*(
  input_buffer: ptr Buffer
): CResultVecU8VecU8 {.importc: "ffi_bytes_be_to_vec_u8".}
```

---

### **Phase 4: Wrapper Updates** ⏱️ 3-4 days

#### 4.1 Update `wrappers.nim`
**File:** `/Users/darshan/work/nwaku/waku/waku_rln_relay/rln/wrappers.nim`

##### A. Update `membershipKeyGen` (Lines 17-59)
**Status:** ✅ Should work as-is, but verify endianness flag is correct

**Current:**
```nim
var done = key_gen(keysBufferPtr, true)  # true = little endian
```

**Verify:** The `true` parameter means little-endian, which is correct per Ekaterina's recommendation.

##### B. Update `createRLNInstanceLocal` (Lines 83-112)

**OLD - Stateful:**
```nim
proc createRLNInstanceLocal(): RLNResult =
  let rln_config = RlnConfig(
    resources_folder: "tree_height_/",
    tree_config: RlnTreeConfig(...)
  )
  
  var
    rlnInstance: ptr RLN
    merkleDepth: csize_t = uint(20)
    configBuffer = serialized_rln_config.toOpenArrayByte(...).toBuffer()

  let res = new_circuit(merkleDepth, addr configBuffer, addr rlnInstance)
  ...
```

**NEW - Stateless:**
```nim
proc createRLNInstanceLocal(): RLNResult =
  # No config needed for stateless mode
  var rlnInstance: ptr RLN

  # Simple initialization without tree config
  let res = new_circuit(addr rlnInstance)
  
  if (res == false):
    info "error in RLN instance creation"
    return err("error in RLN instance creation")
  return ok(rlnInstance)
```

**Key Changes:**
- Removed: `RlnConfig` and `RlnTreeConfig` (not needed)
- Removed: `merkleDepth` parameter
- Removed: `configBuffer` parameter
- Simplified: Direct call to `new_circuit` with only context pointer

**Alternative - With Parameters (if using embedded circuit data):**
```nim
proc createRLNInstanceWithParams*(
  zkeyData: seq[byte], graphData: seq[byte]
): RLNResult =
  var
    rlnInstance: ptr RLN
    zkeyBuffer = zkeyData.toBuffer()
    graphBuffer = graphData.toBuffer()

  let res = new_circuit_from_data(
    addr zkeyBuffer, 
    addr graphBuffer, 
    addr rlnInstance
  )
  
  if (res == false):
    info "error in RLN instance creation with params"
    return err("error in RLN instance creation with params")
  return ok(rlnInstance)
```

##### C. Update Hash Functions (Lines 122-155)

**Status:** ✅ Should work as-is, already using endianness flag correctly

---

### **Phase 5: Usage Pattern Updates** ⏱️ 4-5 days

#### 5.1 Identify All RLN Usage Points

**Search for:**
```bash
grep -r "generate_proof\|verify\|new_circuit" waku/
```

**Common locations:**
- `waku/waku_rln_relay/protocol.nim`
- `waku/waku_rln_relay/group_manager/`
- Test files in `tests/waku_rln_relay/`

#### 5.2 Update Proof Generation Calls

**OLD Pattern:**
```nim
# This won't work in stateless mode
let proofGenSuccess = generate_proof(
  rlnInstance,
  addr inputBuffer,
  addr outputBuffer
)
```

**NEW Pattern - Must Provide Merkle Path:**
```nim
# Must construct witness with Merkle path from smart contract
let witness = constructWitness(
  identitySecret,
  userMessageLimit,
  messageId,
  merklePathFromContract,  # Get from smart contract
  identityPathIndex,       # Get from smart contract
  x,
  externalNullifier
)

let proofGenSuccess = generate_proof_with_witness(
  rlnInstance,
  addr witnessBuffer,
  addr outputBuffer
)
```

**Key Requirement:** You MUST fetch the Merkle path and indices from the smart contract before generating proofs.

#### 5.3 Update Verification Calls

**OLD Pattern:**
```nim
var proofIsValid: bool
let verifySuccess = verify(
  rlnInstance,
  addr proofBuffer,
  addr proofIsValid
)
```

**NEW Pattern - Must Provide Roots:**
```nim
# Get acceptable roots from smart contract
let rootsFromContract = fetchAcceptableRoots()  # Your implementation
let rootsBuffer = rootsFromContract.toBuffer()

let result = verify_with_roots(
  rlnInstance,
  addr proofBuffer,
  addr rootsBuffer
)

# Check result
if result.error != nil:
  # Handle error
  error "Verification failed", error = $result.error
else:
  let proofIsValid = result.value
  # Use proofIsValid
```

**Key Changes:**
- Return type is now `CBoolResult` instead of bool
- Must provide roots buffer with acceptable roots from smart contract
- Better error handling with error messages

---

### **Phase 6: Smart Contract Integration** ⏱️ 3-4 days

#### 6.1 Merkle Path Retrieval

**Required:** Implement functions to fetch Merkle paths from smart contract

```nim
proc getMerklePathForMember*(
  membershipIndex: uint
): RlnRelayResult[MerklePath] =
  # Call smart contract to get:
  # - path_elements: Vec<32 bytes>
  # - path_indices: Vec<1 byte>
  # Return as MerklePath object
  ...
```

#### 6.2 Root Management

**Required:** Implement root validation against smart contract

```nim
proc getAcceptableRoots*(): RlnRelayResult[seq[MerkleNode]] =
  # Fetch current and recent roots from smart contract
  # Typically: current root + last N roots for flexibility
  ...

proc isRootValid*(root: MerkleNode): bool =
  # Check if root exists in smart contract
  ...
```

#### 6.3 Update Group Manager

**Files to update:**
- `waku/waku_rln_relay/group_manager/on_chain/group_manager_onchain.nim`
- `waku/waku_rln_relay/group_manager/group_manager_base.nim`

**Changes:**
- Remove local tree management
- Add Merkle path fetching from contract
- Add root validation logic
- Update member registration flow

---

### **Phase 7: Testing Strategy** ⏱️ 5-6 days

#### 7.1 Unit Tests

**Create new test file:** `tests/waku_rln_relay/test_rln_stateless.nim`

**Test cases:**
1. ✅ Key generation (with and without seed)
2. ✅ RLN instance creation (simple and with params)
3. ✅ Hash functions (sha256, poseidon)
4. ✅ Proof generation with witness
5. ✅ Proof verification with roots
6. ✅ Error handling for invalid inputs
7. ✅ Memory management (no leaks)

#### 7.2 Integration Tests

**Update existing tests:**
- `tests/waku_rln_relay/test_rln_relay.nim`
- `tests/waku_rln_relay/test_waku_rln_relay.nim`

**Focus areas:**
1. End-to-end proof generation and verification
2. Smart contract interaction
3. Multiple roots handling
4. Concurrent operations

#### 7.3 Performance Tests

**Benchmark:**
- Proof generation time (with witness)
- Verification time (with multiple roots)
- Memory usage comparison
- Smart contract call overhead

#### 7.4 Compatibility Tests

**Verify:**
- Cross-platform builds (Linux, macOS, Windows)
- Android builds (if applicable)
- Binary downloads work correctly

---

### **Phase 8: Documentation & Cleanup** ⏱️ 2-3 days

#### 8.1 Update Code Documentation

**Files to update:**
- `docs/operators/how-to/configure-rln.md`
- `README.md` (if RLN mentioned)
- Inline code comments

**Key points to document:**
- Stateless mode requirements
- Smart contract dependency
- Merkle path handling
- Root validation

#### 8.2 Update Build Documentation

**Document:**
- New build flags
- Binary naming convention
- Troubleshooting common issues

#### 8.3 Create Migration Guide

**For users:**
- What changed
- How to update their setup
- Breaking changes
- Migration checklist

#### 8.4 Cleanup

**Remove:**
- Unused tree management code
- Old stateful function references
- Deprecated configuration options

---

## Critical Considerations

### 🔴 Breaking Changes

1. **No Local Tree:** All tree data must come from smart contract
2. **Merkle Path Required:** Cannot generate proofs without path from contract
3. **Roots Required:** Cannot verify without roots from contract
4. **Function Signatures Changed:** Many functions have different parameters
5. **Return Types Changed:** Better error handling but requires code updates

### ⚠️ Performance Implications

1. **Network Dependency:** Every proof operation requires smart contract data
2. **Latency:** Added latency from contract calls
3. **Caching Strategy:** Need to cache Merkle paths and roots efficiently
4. **Memory:** Stateless uses more RAM during initialization (per Ekaterina)

### 🔒 Security Considerations

1. **Root Validation:** Must validate roots against smart contract
2. **Path Verification:** Must verify Merkle paths are correct
3. **Replay Protection:** Ensure nullifiers are checked properly
4. **Contract Trust:** Fully dependent on smart contract integrity

### 🐛 Common Pitfalls

1. **Endianness:** Use little-endian (`true`) for all operations
2. **Buffer Management:** Proper memory cleanup to avoid leaks
3. **Error Handling:** Check `CBoolResult.error` for detailed errors
4. **Build Flags:** Must use `--no-default-features` in cargo build
5. **Binary Names:** Must use correct binary name for downloads

---

## Rollback Plan

### If Migration Fails

1. **Revert Submodule:**
   ```bash
   cd vendor/zerokit
   git checkout a4bb3feb  # v0.9.0 tag
   cd ../..
   git add vendor/zerokit
   ```

2. **Revert Build Scripts:**
   - Restore old `build_rln.sh`
   - Restore old Makefile

3. **Revert Code Changes:**
   ```bash
   git checkout HEAD -- waku/waku_rln_relay/rln/
   ```

4. **Keep Changes in Branch:**
   - Don't force push
   - Keep migration branch for future retry

---

## Timeline Estimate

| Phase | Duration | Dependencies |
|-------|----------|--------------|
| Phase 1: Preparation | 2-3 days | None |
| Phase 2: Build System | 1 day | Phase 1 |
| Phase 3: FFI Interface | 3-4 days | Phase 1, 2 |
| Phase 4: Wrappers | 3-4 days | Phase 3 |
| Phase 5: Usage Patterns | 4-5 days | Phase 4 |
| Phase 6: Smart Contract | 3-4 days | Phase 5 |
| Phase 7: Testing | 5-6 days | Phase 6 |
| Phase 8: Documentation | 2-3 days | Phase 7 |
| **Total** | **23-34 days** | **~5-7 weeks** |

---

## Success Criteria

### ✅ Migration Complete When:

1. All tests pass with new FFI
2. Proof generation works with smart contract paths
3. Proof verification works with smart contract roots
4. No memory leaks detected
5. Performance is acceptable
6. Documentation is updated
7. CI/CD pipeline passes
8. Code review approved

---

## Questions for Clarification

### Before Starting:

1. ❓ Which smart contract are we using for the Merkle tree?
2. ❓ What's the expected latency for smart contract calls?
3. ❓ How many roots should we keep for verification?
4. ❓ Do we need to support both stateful and stateless modes?
5. ❓ What's the caching strategy for Merkle paths?
6. ❓ Are there any backward compatibility requirements?
7. ❓ What's the testing environment for smart contract integration?

---

## Resources & References

### Zerokit Documentation
- **FFI Source:** `vendor/zerokit/rln/src/ffi.rs`
- **Nim Example:** Check zerokit repo for Nim examples
- **Release Notes:** https://github.com/vacp2p/zerokit/releases/tag/v0.9.0

### nwaku Current Implementation
- **RLN Interface:** `waku/waku_rln_relay/rln/rln_interface.nim`
- **Wrappers:** `waku/waku_rln_relay/rln/wrappers.nim`
- **Build Script:** `scripts/build_rln.sh`
- **Tests:** `tests/waku_rln_relay/`

### Conversation References
- Ekaterina's guidance on stateless features
- Discussion about memory usage
- Clarification on Merkle proof verification

---

## Next Steps

1. **Review this plan** with the team
2. **Get approval** for timeline and approach
3. **Set up development environment** with master branch
4. **Create feature branch** for migration
5. **Start Phase 1** - Preparation & Analysis

---

## Notes

- This is a **major migration** requiring careful testing
- **Stateless mode** is fundamentally different from stateful
- **Smart contract integration** is critical for success
- **Performance testing** is essential before production
- **Rollback plan** must be ready before deployment

---

**Document Version:** 1.0  
**Created:** 2024-12-01  
**Author:** Migration Planning  
**Status:** Ready for Review
