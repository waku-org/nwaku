# Phase 1 Implementation Guide: Preparation & Analysis

## Overview
This guide walks you through Phase 1 of the RLN FFI migration. Complete this phase before making any code changes. This will give you confidence to answer reviewer questions.

**Duration:** 2-3 days  
**Goal:** Understand current implementation and new FFI completely

---

## Day 1: Current Implementation Analysis

### Morning Session (3-4 hours)

#### Task 1.1: Map Current FFI Functions
Create a spreadsheet or document with all current FFI functions.

**Action:**
```bash
cd /Users/darshan/work/nwaku
grep -n "importc:" waku/waku_rln_relay/rln/rln_interface.nim > current_ffi_functions.txt
```

**Expected Output:** List of ~15-20 function declarations

**Document for each function:**
1. Function name
2. Parameters
3. Return type
4. Where it's used (search in codebase)
5. Purpose/what it does

**Template:**
```
Function: key_gen
Import Name: "extended_key_gen"
Parameters: output_buffer (ptr Buffer), is_little_endian (bool)
Returns: bool
Used In: wrappers.nim (line 25)
Purpose: Generate identity credentials
Status: ✅ Already compatible with new FFI
```

#### Task 1.2: Identify Usage Patterns

**Search for RLN usage:**
```bash
# Find all files using RLN functions
grep -r "generate_proof\|verify\|new_circuit\|key_gen" waku/ --include="*.nim" | cut -d: -f1 | sort -u

# Count usages
grep -r "generate_proof" waku/ --include="*.nim" | wc -l
grep -r "verify" waku/ --include="*.nim" | wc -l
grep -r "new_circuit" waku/ --include="*.nim" | wc -l
```

**Create a usage map:**
```
File: waku/waku_rln_relay/protocol.nim
- Uses: generate_proof (line X)
- Uses: verify (line Y)
- Context: Main protocol implementation
- Complexity: High (core functionality)
```

### Afternoon Session (3-4 hours)

#### Task 1.3: Understand Current Build Process

**Study build script:**
```bash
cat scripts/build_rln.sh
```

**Document:**
1. What cargo command is used? (line 52)
2. What features are enabled?
3. How are binaries downloaded?
4. What's the fallback if download fails?

**Test current build:**
```bash
# Try building current version
make clean-librln
make librln

# Check what was built
ls -lh librln_*.a
file librln_*.a
```

**Document:**
- Build time
- Output file size
- Any warnings/errors

#### Task 1.4: Study Current RLN Instance Creation

**Read carefully:**
```bash
# Study the wrapper
cat waku/waku_rln_relay/rln/wrappers.nim | grep -A 30 "proc createRLNInstanceLocal"
```

**Understand:**
1. What is `RlnConfig`?
2. What is `RlnTreeConfig`?
3. Why is `tree_height_/` used?
4. What does each config parameter do?
5. Where is this function called from?

**Trace the call chain:**
```bash
grep -r "createRLNInstance" waku/ --include="*.nim"
```

---

## Day 2: New FFI Study

### Morning Session (3-4 hours)

#### Task 2.1: Read New FFI Source Code

**Open and study:**
```bash
cd vendor/zerokit
git checkout master
git pull origin master

# Read the FFI
less rln/src/ffi.rs
```

**Focus on these sections:**
1. Lines 1-100: Macros and helper functions
2. Lines 200-350: RLN instance creation
3. Lines 450-550: Proof generation/verification
4. Lines 590-650: Key generation functions

**For each function, note:**
- Function signature
- Parameters (especially new ones)
- Return type (especially `CBoolResult`)
- `#[cfg(feature = "stateless")]` annotations
- Comments explaining behavior

#### Task 2.2: Compare Old vs New

**Create comparison table:**

| Function | Old Signature | New Signature | Changes | Breaking? |
|----------|---------------|---------------|---------|-----------|
| new | `new(depth, buffer, ctx)` | `ffi_rln_new(ctx)` | Removed params | ✅ Yes |
| ... | ... | ... | ... | ... |

**Identify:**
- ✅ Functions that are the same
- ⚠️ Functions with minor changes
- ❌ Functions that are removed
- 🆕 Functions that are new

### Afternoon Session (3-4 hours)

#### Task 2.3: Study Stateless Architecture

**Read Ekaterina's explanation again:**

Key concepts to understand:
1. **Two types of proofs:**
   - Merkle proof (tree-based)
   - ZK proof (Groth16)

2. **Stateless verification:**
   - Recalculate root from Merkle path
   - Compare with root from smart contract
   - Verify ZK proof

3. **Why it's slower:**
   - Must recalculate root each time
   - No local tree cache
   - Network calls to smart contract

**Draw a diagram:**
```
Stateful Flow:
User → RLN (with local tree) → Proof
                ↓
         Local tree lookup

Stateless Flow:
User → Smart Contract (get path) → RLN → Proof
                                     ↓
                            Recalculate root
```

#### Task 2.4: Understand Memory Implications

**From Ekaterina:**
> "new_circuit stateless function uses much more RAM compared to the stateful function"

**Research:**
1. Why does stateless use more RAM?
2. How much more? (test if possible)
3. Is this during initialization only?
4. Can we optimize?

**Test (if possible):**
```bash
# Build both versions and compare
cargo build -p rln --release --features stateful
ls -lh target/release/librln.a

cargo build -p rln --release --no-default-features --features stateless,parallel
ls -lh target/release/librln.a
```

---

## Day 3: Integration Planning

### Morning Session (3-4 hours)

#### Task 3.1: Smart Contract Interface Study

**Find current smart contract code:**
```bash
grep -r "contract\|ethereum\|web3" waku/waku_rln_relay/ --include="*.nim"
```

**Understand:**
1. Which smart contract is used?
2. How are members registered?
3. How is the tree stored?
4. What functions are available?

**Document required additions:**
```nim
# Need to add:
proc getMerklePathForMember*(index: uint): MerklePath
proc getAcceptableRoots*(): seq[MerkleNode]
proc getCurrentRoot*(): MerkleNode
```

#### Task 3.2: Create Detailed Function Mapping

**For each function in `rln_interface.nim`, create:**

```markdown
### Function: generate_proof

**Current Implementation:**
- Name: `generate_proof`
- Import: `"generate_rln_proof"`
- Parameters: ctx, input_buffer, output_buffer
- Returns: bool
- Used in: protocol.nim (line 123), group_manager.nim (line 456)

**New Implementation:**
- Name: `generate_proof_with_witness`
- Import: `"generate_rln_proof_with_witness"`
- Parameters: ctx, input_buffer (with witness), output_buffer
- Returns: bool
- Changes needed:
  1. Input buffer must include Merkle path
  2. Must fetch path from smart contract first
  3. Serialization format changes

**Migration Steps:**
1. Add getMerklePathForMember function
2. Update input buffer construction
3. Update all call sites
4. Add error handling
5. Add tests

**Risk Level:** 🔴 High (core functionality)
**Estimated Effort:** 2 days
```

### Afternoon Session (3-4 hours)

#### Task 3.3: Identify Risks and Challenges

**Create risk matrix:**

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Smart contract calls too slow | Medium | High | Add caching layer |
| Memory usage too high | Low | Medium | Profile and optimize |
| Breaking changes in tests | High | Medium | Update tests incrementally |
| Compatibility issues | Medium | High | Thorough testing |

#### Task 3.4: Create Test Strategy

**List all test files:**
```bash
find tests/waku_rln_relay -name "*.nim" -type f
```

**For each test file:**
1. What does it test?
2. Will it break with new FFI?
3. How to update it?
4. Priority (high/medium/low)?

**Plan new tests:**
```
New Test: test_stateless_proof_generation.nim
- Test proof generation with Merkle path
- Test with invalid path
- Test with multiple roots
- Test error handling
```

#### Task 3.5: Review with Team (if possible)

**Prepare presentation:**
1. Current state summary
2. New FFI overview
3. Key changes
4. Migration approach
5. Risks and mitigations
6. Timeline

**Questions to ask:**
- Is stateless-only acceptable?
- Performance requirements?
- Backward compatibility needs?
- Testing environment for smart contract?

---

## Deliverables Checklist

By end of Phase 1, you should have:

### Documentation
- [ ] Complete function mapping (old → new)
- [ ] Usage pattern analysis
- [ ] Risk assessment
- [ ] Test strategy
- [ ] Smart contract integration plan

### Understanding
- [ ] Can explain stateless vs stateful
- [ ] Understand all breaking changes
- [ ] Know which functions are removed
- [ ] Understand new return types
- [ ] Know build flag changes

### Technical
- [ ] Built current version successfully
- [ ] Checked out new zerokit master
- [ ] Read new FFI source code
- [ ] Identified all usage points
- [ ] Created migration checklist

### Confidence
- [ ] Can explain changes to reviewer
- [ ] Know what questions to ask
- [ ] Understand risks
- [ ] Have rollback plan
- [ ] Ready to start coding

---

## Self-Assessment Questions

Test your understanding:

### Basic Understanding
1. What's the main difference between stateful and stateless RLN?
2. Why was `tree_depth` removed from `new_circuit`?
3. What does `--no-default-features` do in the build command?
4. What's the new binary naming convention?

### Intermediate
5. Why can't we use `generate_proof` in stateless mode?
6. What's the difference between Merkle proof and ZK proof?
7. Why does `verify_with_roots` return `CBoolResult` instead of `bool`?
8. What data must come from the smart contract?

### Advanced
9. How does stateless verification work without a local tree?
10. Why does stateless use more RAM during initialization?
11. What happens if the smart contract root changes during verification?
12. How do we handle multiple acceptable roots?

**If you can answer all these confidently, you're ready for Phase 2!**

---

## Phase 1 Completion Criteria

✅ **Ready to proceed when:**
1. All deliverables completed
2. All self-assessment questions answered
3. Team review done (if applicable)
4. No blocking questions remaining
5. Confident in migration approach

---

## Next Steps

After completing Phase 1:
1. Review findings with team
2. Get approval to proceed
3. Create feature branch
4. Start Phase 2: Build System Updates

---

## Resources

### Reading Material
- Zerokit FFI: `vendor/zerokit/rln/src/ffi.rs`
- Current interface: `waku/waku_rln_relay/rln/rln_interface.nim`
- Ekaterina's messages (saved in main plan)

### Tools
```bash
# Search codebase
grep -r "pattern" waku/ --include="*.nim"

# Count occurrences
grep -r "pattern" waku/ --include="*.nim" | wc -l

# Find files
find waku/ -name "*.nim" -type f

# Check git history
git log --oneline -- waku/waku_rln_relay/rln/
```

### Documentation
- Main migration plan: `RLN_FFI_MIGRATION_PLAN.md`
- Quick reference: `RLN_FFI_QUICK_REFERENCE.md`
- This guide: `RLN_PHASE1_IMPLEMENTATION.md`

---

**Remember:** Phase 1 is about understanding, not coding. Take your time to understand everything thoroughly. This will save time in later phases and help you answer reviewer questions confidently.

**Good luck! 🚀**
