# RLN FFI Quick Reference Guide

## 🚀 Quick Start

### Current Status
- **From:** v0.8.0 (stateful with local tree)
- **To:** master (stateless with smart contract tree)
- **Mode:** Stateless + Parallel

---

## 📋 Critical Changes Checklist

### Build Changes
```bash
# OLD
cargo build --release -p rln

# NEW
cargo build -p rln --release --no-default-features --features stateless,parallel
```

### Binary Names
```bash
# OLD
x86_64-unknown-linux-gnu-rln.tar.gz

# NEW
x86_64-unknown-linux-gnu-stateless-parallel-rln.tar.gz
```

---

## 🔄 Function Migration Map

### Instance Creation

```nim
# OLD - Stateful
proc new_circuit*(
  tree_depth: uint, 
  input_buffer: ptr Buffer, 
  ctx: ptr (ptr RLN)
): bool {.importc: "new".}

# NEW - Stateless
proc new_circuit*(
  ctx: ptr (ptr RLN)
): bool {.importc: "ffi_rln_new".}
```

**Changes:**
- ❌ Remove `tree_depth` parameter
- ❌ Remove `input_buffer` parameter
- ✅ Change import name: `"new"` → `"ffi_rln_new"`

---

### Instance Creation with Parameters

```nim
# OLD
proc new_circuit_from_data*(
  zkey_buffer: ptr Buffer,
  vk_buffer: ptr Buffer,      # ❌ REMOVED
  circom_buffer: ptr Buffer,  # ❌ RENAMED
  ctx: ptr (ptr RLN)
): bool {.importc: "new_with_params".}

# NEW
proc new_circuit_from_data*(
  zkey_buffer: ptr Buffer,
  graph_buffer: ptr Buffer,   # ✅ NEW NAME
  ctx: ptr (ptr RLN)
): bool {.importc: "ffi_rln_new_with_params".}
```

**Changes:**
- ❌ Remove `vk_buffer` (extracted from zkey automatically)
- ✅ Rename `circom_buffer` → `graph_buffer` (graph.bin file)
- ✅ Change import: `"new_with_params"` → `"ffi_rln_new_with_params"`

---

### Key Generation

```nim
# UNCHANGED - Already correct!
proc key_gen*(
  output_buffer: ptr Buffer, 
  is_little_endian: bool  # Use true for little-endian
): bool {.importc: "extended_key_gen".}

proc seeded_key_gen*(
  input_buffer: ptr Buffer, 
  output_buffer: ptr Buffer, 
  is_little_endian: bool  # Use true for little-endian
): bool {.importc: "seeded_extended_key_gen".}
```

**Status:** ✅ No changes needed, already using new names

---

### Proof Generation

```nim
# OLD - NOT AVAILABLE IN STATELESS
proc generate_proof*(
  ctx: ptr RLN, 
  input_buffer: ptr Buffer, 
  output_buffer: ptr Buffer
): bool {.importc: "generate_rln_proof".}

# NEW - ONLY THIS ONE FOR STATELESS
proc generate_proof_with_witness*(
  ctx: ptr RLN, 
  input_buffer: ptr Buffer, 
  output_buffer: ptr Buffer
): bool {.importc: "generate_rln_proof_with_witness".}
```

**Input Format (RLN-v2):**
```
[ identity_secret<32> 
| user_message_limit<32> 
| message_id<32> 
| path_elements<Vec<32>>        ⬅️ FROM SMART CONTRACT
| identity_path_index<Vec<1>>   ⬅️ FROM SMART CONTRACT
| x<32> 
| external_nullifier<32> ]
```

**Key Requirement:** Must fetch `path_elements` and `identity_path_index` from smart contract!

---

### Proof Verification

```nim
# OLD - NOT AVAILABLE IN STATELESS
proc verify*(
  ctx: ptr RLN, 
  proof_buffer: ptr Buffer, 
  proof_is_valid_ptr: ptr bool
): bool {.importc: "verify_rln_proof".}

# NEW - ONLY THIS ONE FOR STATELESS
type CBoolResult* = object
  value*: bool
  error*: cstring

proc verify_with_roots*(
  ctx: ptr RLN,
  proof_buffer: ptr Buffer,
  roots_buffer: ptr Buffer  # ⬅️ FROM SMART CONTRACT
): CBoolResult {.importc: "ffi_verify_with_roots".}
```

**Changes:**
- ✅ Return type: `bool` → `CBoolResult`
- ✅ Must provide `roots_buffer` from smart contract
- ✅ Better error handling via `result.error`

**Usage:**
```nim
let result = verify_with_roots(ctx, addr proofBuffer, addr rootsBuffer)
if result.error != nil:
  error "Verification failed", msg = $result.error
else:
  let isValid = result.value
```

---

### Hash Functions

```nim
# UNCHANGED
proc sha256*(
  input_buffer: ptr Buffer, 
  output_buffer: ptr Buffer, 
  is_little_endian: bool  # Use true
): bool {.importc: "hash".}

proc poseidon*(
  input_buffer: ptr Buffer, 
  output_buffer: ptr Buffer, 
  is_little_endian: bool  # Use true
): bool {.importc: "poseidon_hash".}
```

**Status:** ✅ No changes needed

---

## ❌ Functions NOT Available in Stateless

These functions are **removed** in stateless mode:

```nim
# Tree operations - ALL REMOVED
- set_leaf
- get_leaf
- delete_leaf
- set_tree
- leaves_set
- get_root

# Metadata operations - ALL REMOVED
- set_metadata
- get_metadata
- flush

# Proof operations - REPLACED
- generate_proof (use generate_proof_with_witness)
- verify (use verify_with_roots)
```

---

## 🆕 New Result Types

Add these to `rln_interface.nim`:

```nim
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
```

---

## 🔧 Wrapper Updates

### Old RLN Instance Creation

```nim
# OLD - wrappers.nim
proc createRLNInstanceLocal(): RLNResult =
  let rln_config = RlnConfig(
    resources_folder: "tree_height_/",
    tree_config: RlnTreeConfig(
      cache_capacity: 15_000,
      mode: "high_throughput",
      compression: false,
      flush_every_ms: 500,
    ),
  )
  
  var serialized_rln_config = $(%rln_config)
  var
    rlnInstance: ptr RLN
    merkleDepth: csize_t = uint(20)
    configBuffer = serialized_rln_config.toOpenArrayByte(...).toBuffer()

  let res = new_circuit(merkleDepth, addr configBuffer, addr rlnInstance)
  if (res == false):
    return err("error in parameters generation")
  return ok(rlnInstance)
```

### New RLN Instance Creation

```nim
# NEW - wrappers.nim
proc createRLNInstanceLocal(): RLNResult =
  # No config needed for stateless!
  var rlnInstance: ptr RLN

  let res = new_circuit(addr rlnInstance)
  if (res == false):
    return err("error in RLN instance creation")
  return ok(rlnInstance)
```

**Changes:**
- ❌ Remove `RlnConfig` and `RlnTreeConfig`
- ❌ Remove `merkleDepth`
- ❌ Remove `configBuffer`
- ✅ Simple one-line call

---

## 🌐 Smart Contract Integration

### Required Functions

You **must** implement these to work with stateless RLN:

```nim
# 1. Get Merkle path for a member
proc getMerklePathForMember*(
  memberIndex: uint
): RlnRelayResult[MerklePath] =
  # Call smart contract
  # Return path_elements and path_indices
  ...

# 2. Get acceptable roots
proc getAcceptableRoots*(): RlnRelayResult[seq[MerkleNode]] =
  # Get current root + recent roots from contract
  # Typically current + last 5-10 roots
  ...

# 3. Validate root
proc isRootValid*(root: MerkleNode): bool =
  # Check if root exists in contract
  ...
```

---

## 📊 Proof Generation Flow

### Old Flow (Stateful)
```
1. Get identity credentials
2. Call generate_proof()
   ↳ RLN uses local tree
3. Done!
```

### New Flow (Stateless)
```
1. Get identity credentials
2. Fetch Merkle path from smart contract ⬅️ NEW!
3. Construct witness with path
4. Call generate_proof_with_witness()
5. Done!
```

---

## 📊 Verification Flow

### Old Flow (Stateful)
```
1. Receive proof
2. Call verify()
   ↳ RLN checks against local tree
3. Done!
```

### New Flow (Stateless)
```
1. Receive proof
2. Fetch acceptable roots from smart contract ⬅️ NEW!
3. Call verify_with_roots()
   ↳ Checks if proof root matches any acceptable root
4. Check result.error for errors
5. Done!
```

---

## ⚠️ Common Mistakes

### 1. Wrong Build Flags
```bash
# ❌ WRONG - Will include default tree features
cargo build -p rln --release --features stateless,parallel

# ✅ CORRECT - Must use --no-default-features
cargo build -p rln --release --no-default-features --features stateless,parallel
```

### 2. Wrong Endianness
```nim
# ❌ WRONG
key_gen(keysBufferPtr, false)  # big-endian not fully supported

# ✅ CORRECT
key_gen(keysBufferPtr, true)   # little-endian recommended
```

### 3. Missing Merkle Path
```nim
# ❌ WRONG - Can't generate proof without path
let input = serializeIdentityOnly(identity)
generate_proof_with_witness(ctx, addr input, addr output)

# ✅ CORRECT - Must include path from contract
let merklePath = getMerklePathForMember(memberIndex)
let input = serializeWithWitness(identity, merklePath)
generate_proof_with_witness(ctx, addr input, addr output)
```

### 4. Not Checking Errors
```nim
# ❌ WRONG - Ignoring error information
let result = verify_with_roots(ctx, addr proof, addr roots)
let isValid = result.value  # Might be false due to error!

# ✅ CORRECT - Check error first
let result = verify_with_roots(ctx, addr proof, addr roots)
if result.error != nil:
  error "Verification error", msg = $result.error
  return err($result.error)
let isValid = result.value
```

### 5. Using Removed Functions
```nim
# ❌ WRONG - These don't exist in stateless
set_leaf(ctx, index, addr leafBuffer)
get_root(ctx, addr rootBuffer)

# ✅ CORRECT - Get data from smart contract
let root = fetchRootFromContract()
```

---

## 🎯 Testing Checklist

Before considering migration complete:

- [ ] Key generation works (with and without seed)
- [ ] RLN instance creation works
- [ ] Can fetch Merkle paths from smart contract
- [ ] Proof generation works with witness
- [ ] Can fetch roots from smart contract
- [ ] Proof verification works with roots
- [ ] Error handling works correctly
- [ ] No memory leaks detected
- [ ] Performance is acceptable
- [ ] All existing tests pass
- [ ] Cross-platform builds work
- [ ] Binary downloads work

---

## 🔗 Key Files to Modify

1. **`scripts/build_rln.sh`** - Build flags and binary names
2. **`Makefile`** - Version and build targets
3. **`waku/waku_rln_relay/rln/rln_interface.nim`** - FFI declarations
4. **`waku/waku_rln_relay/rln/wrappers.nim`** - High-level wrappers
5. **`waku/waku_rln_relay/protocol.nim`** - Usage patterns
6. **`waku/waku_rln_relay/group_manager/`** - Smart contract integration

---

## 📚 References

- **Zerokit FFI:** `vendor/zerokit/rln/src/ffi.rs`
- **Full Migration Plan:** `RLN_FFI_MIGRATION_PLAN.md`
- **Zerokit Releases:** https://github.com/vacp2p/zerokit/releases

---

## 💡 Pro Tips

1. **Start Simple:** Get basic instance creation working first
2. **Test Incrementally:** Don't change everything at once
3. **Use Little-Endian:** Recommended by Ekaterina
4. **Cache Smart Contract Data:** Reduce latency
5. **Check Errors:** New result types provide better error info
6. **Keep Rollback Ready:** Don't delete old code immediately

---

**Last Updated:** 2024-12-01  
**For:** nwaku RLN FFI Migration  
**Version:** 1.0
