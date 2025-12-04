# RLN FFI Migration Documentation

## 📚 Document Overview

This directory contains comprehensive documentation for migrating nwaku's RLN (Rate Limiting Nullifier) FFI from zerokit v0.8.0 to the master branch with stateless features.

---

## 📄 Available Documents

### 1. **RLN_FFI_MIGRATION_PLAN.md** (Main Document)
**Purpose:** Complete migration plan with all 8 phases  
**Use when:** Planning the entire migration, understanding scope  
**Length:** ~1000 lines, comprehensive  
**Key sections:**
- Overview and key changes
- 8 detailed phases with timelines
- Critical considerations
- Rollback plan
- Success criteria

**Start here if:** You need the full picture and detailed timeline.

---

### 2. **RLN_FFI_QUICK_REFERENCE.md** (Cheat Sheet)
**Purpose:** Quick lookup for common changes  
**Use when:** Coding and need quick answers  
**Length:** ~500 lines, focused  
**Key sections:**
- Function migration map (old → new)
- Common mistakes and fixes
- Code snippets for each change
- Testing checklist

**Start here if:** You know what you're doing and need quick reference.

---

### 3. **RLN_PHASE1_IMPLEMENTATION.md** (Getting Started)
**Purpose:** Step-by-step guide for Phase 1  
**Use when:** Starting the migration  
**Length:** ~600 lines, actionable  
**Key sections:**
- Day-by-day breakdown
- Specific tasks and commands
- Self-assessment questions
- Deliverables checklist

**Start here if:** You're ready to begin and want a structured approach.

---

## 🚀 Getting Started

### For First-Time Readers

**Recommended Reading Order:**

1. **Start:** Read this README (you are here!)
2. **Understand:** Read "Key Changes Summary" below
3. **Plan:** Skim `RLN_FFI_MIGRATION_PLAN.md` (focus on Phases 1-3)
4. **Learn:** Read `RLN_FFI_QUICK_REFERENCE.md` completely
5. **Execute:** Follow `RLN_PHASE1_IMPLEMENTATION.md` day by day

**Time Investment:**
- Initial reading: 2-3 hours
- Phase 1 execution: 2-3 days
- Total migration: 5-7 weeks

---

## 🔑 Key Changes Summary

### What's Changing?

#### 1. **Mode: Stateful → Stateless**
- **Before:** Local Merkle tree in RLN instance
- **After:** Merkle tree in smart contract only
- **Impact:** Must fetch tree data from contract

#### 2. **Build: Default → Stateless+Parallel**
- **Before:** `cargo build -p rln --release`
- **After:** `cargo build -p rln --release --no-default-features --features stateless,parallel`
- **Impact:** Different binary, different features

#### 3. **Functions: Many → Fewer**
- **Before:** ~20 FFI functions
- **After:** ~12 FFI functions (tree functions removed)
- **Impact:** Some code won't work anymore

#### 4. **API: Simple → Enhanced**
- **Before:** Functions return `bool`
- **After:** Functions return `CBoolResult` with error info
- **Impact:** Better error handling, code changes needed

---

## ⚠️ Critical Breaking Changes

### 🔴 High Impact

1. **No Local Tree Operations**
   - Removed: `set_leaf`, `get_leaf`, `delete_leaf`, `get_root`, etc.
   - Reason: Stateless mode has no local tree
   - Solution: Get all tree data from smart contract

2. **Proof Generation Requires Merkle Path**
   - Old: `generate_proof(ctx, input, output)`
   - New: `generate_proof_with_witness(ctx, input_with_path, output)`
   - Reason: Need path to recalculate root
   - Solution: Fetch path from smart contract before generating proof

3. **Verification Requires Roots**
   - Old: `verify(ctx, proof, &isValid)`
   - New: `verify_with_roots(ctx, proof, roots) -> CBoolResult`
   - Reason: Need to check against acceptable roots
   - Solution: Fetch roots from smart contract before verifying

### ⚠️ Medium Impact

4. **Instance Creation Simplified**
   - Old: `new_circuit(tree_depth, config_buffer, ctx)`
   - New: `new_circuit(ctx)`
   - Reason: No tree configuration needed
   - Solution: Remove tree config code

5. **Function Names Changed**
   - Old: `new`, `new_with_params`
   - New: `ffi_rln_new`, `ffi_rln_new_with_params`
   - Reason: Better naming convention
   - Solution: Update all import declarations

6. **Binary Names Changed**
   - Old: `*-rln.tar.gz`
   - New: `*-stateless-parallel-rln.tar.gz`
   - Reason: Different build features
   - Solution: Update download scripts

---

## 📋 Migration Phases Overview

### Phase 1: Preparation (2-3 days) 📖
- Understand current implementation
- Study new FFI
- Create function mapping
- **Deliverable:** Complete understanding and plan

### Phase 2: Build System (1 day) 🔧
- Update Makefile
- Update build scripts
- Update submodule
- **Deliverable:** New FFI builds successfully

### Phase 3: FFI Interface (3-4 days) 💻
- Update `rln_interface.nim`
- Add new result types
- Remove unavailable functions
- **Deliverable:** Interface matches new FFI

### Phase 4: Wrappers (3-4 days) 🎁
- Update `wrappers.nim`
- Simplify instance creation
- Update error handling
- **Deliverable:** High-level API works

### Phase 5: Usage Patterns (4-5 days) 🔄
- Update proof generation
- Update verification
- Update all call sites
- **Deliverable:** All code uses new patterns

### Phase 6: Smart Contract (3-4 days) 🌐
- Add Merkle path fetching
- Add root management
- Update group manager
- **Deliverable:** Smart contract integration complete

### Phase 7: Testing (5-6 days) ✅
- Unit tests
- Integration tests
- Performance tests
- **Deliverable:** All tests pass

### Phase 8: Documentation (2-3 days) 📝
- Update docs
- Create migration guide
- Cleanup old code
- **Deliverable:** Ready for production

**Total Timeline:** 23-34 days (5-7 weeks)

---

## 🎯 Quick Decision Tree

**"Where should I start?"**

```
Are you just exploring?
├─ Yes → Read RLN_FFI_MIGRATION_PLAN.md (Overview section)
└─ No ↓

Do you understand the changes?
├─ No → Read RLN_FFI_QUICK_REFERENCE.md (full document)
└─ Yes ↓

Ready to start coding?
├─ No → Follow RLN_PHASE1_IMPLEMENTATION.md
└─ Yes ↓

Need quick lookup while coding?
└─ Use RLN_FFI_QUICK_REFERENCE.md (as reference)
```

---

## 🔍 Finding Information

### "How do I...?"

**...understand what changed?**
→ `RLN_FFI_QUICK_REFERENCE.md` - Function Migration Map

**...know what to do first?**
→ `RLN_PHASE1_IMPLEMENTATION.md` - Day 1 tasks

**...update a specific function?**
→ `RLN_FFI_QUICK_REFERENCE.md` - Search for function name

**...understand the timeline?**
→ `RLN_FFI_MIGRATION_PLAN.md` - Timeline Estimate section

**...know what's risky?**
→ `RLN_FFI_MIGRATION_PLAN.md` - Critical Considerations

**...test my changes?**
→ `RLN_FFI_QUICK_REFERENCE.md` - Testing Checklist

**...roll back if needed?**
→ `RLN_FFI_MIGRATION_PLAN.md` - Rollback Plan

---

## 💡 Pro Tips

### Before You Start
1. ✅ Read all three documents (at least skim)
2. ✅ Understand stateless vs stateful
3. ✅ Set up test environment
4. ✅ Create feature branch
5. ✅ Have rollback plan ready

### While Working
1. 📝 Keep notes of issues encountered
2. ✅ Test after each phase
3. 💬 Ask questions early
4. 🔄 Commit frequently
5. 📊 Track progress

### Best Practices
1. **Don't rush Phase 1** - Understanding saves time later
2. **Test incrementally** - Don't change everything at once
3. **Use little-endian** - Recommended by zerokit team
4. **Check errors** - New result types provide better info
5. **Keep old code** - Don't delete until migration complete

---

## 🆘 Common Questions

### Q: Do we need to support both stateful and stateless?
**A:** No, we're fully migrating to stateless (smart contract-based).

### Q: Can I use the old `generate_proof` function?
**A:** No, it's not available in stateless mode. Use `generate_proof_with_witness`.

### Q: Why does stateless use more RAM?
**A:** During initialization, it loads more data. This is a known trade-off.

### Q: How many roots should we keep for verification?
**A:** Typically current root + last 5-10 roots. Discuss with team.

### Q: What if smart contract calls are too slow?
**A:** Implement caching layer for Merkle paths and roots.

### Q: Can I skip Phase 1?
**A:** Not recommended. Phase 1 builds understanding needed for later phases.

---

## 📞 Getting Help

### If You're Stuck

1. **Check Quick Reference** - Most common issues covered
2. **Review Phase 1 Guide** - Might have missed something
3. **Search Zerokit Issues** - Others might have same problem
4. **Ask Team** - Don't struggle alone
5. **Check Ekaterina's Messages** - Included in main plan

### Useful Commands

```bash
# Search for function usage
grep -r "function_name" waku/ --include="*.nim"

# Find all RLN-related files
find waku/waku_rln_relay -name "*.nim" -type f

# Check current zerokit version
git submodule status vendor/zerokit

# Test build
make clean-librln && make librln

# Run specific test
make test tests/waku_rln_relay/test_file.nim
```

---

## ✅ Success Criteria

### Migration Complete When:

- [ ] All 8 phases completed
- [ ] All tests pass
- [ ] No memory leaks
- [ ] Performance acceptable
- [ ] Documentation updated
- [ ] Code reviewed
- [ ] CI/CD passes
- [ ] Team approval

---

## 📊 Progress Tracking

### Suggested Format

Create a file `MIGRATION_PROGRESS.md`:

```markdown
# RLN FFI Migration Progress

## Phase 1: Preparation ⏳
- [x] Task 1.1: Map current FFI functions
- [x] Task 1.2: Identify usage patterns
- [ ] Task 1.3: Understand build process
- [ ] Task 1.4: Study instance creation
...

## Blockers
- None yet

## Questions
1. Which smart contract to use?
2. Performance requirements?

## Notes
- Stateless uses more RAM during init
- Must use little-endian
```

---

## 🔗 External Resources

### Zerokit
- **Repository:** https://github.com/vacp2p/zerokit
- **FFI Source:** `vendor/zerokit/rln/src/ffi.rs`
- **Releases:** https://github.com/vacp2p/zerokit/releases
- **v0.9.0 Release:** https://github.com/vacp2p/zerokit/releases/tag/v0.9.0

### nwaku
- **RLN Interface:** `waku/waku_rln_relay/rln/rln_interface.nim`
- **Wrappers:** `waku/waku_rln_relay/rln/wrappers.nim`
- **Tests:** `tests/waku_rln_relay/`
- **Build Script:** `scripts/build_rln.sh`

---

## 📝 Document Maintenance

### Keeping Docs Updated

As you progress:
1. Update progress tracking
2. Add new findings to notes
3. Document issues and solutions
4. Update timelines if needed
5. Add new questions

### After Completion

1. Archive these docs (don't delete)
2. Create final migration report
3. Update main project docs
4. Share learnings with team

---

## 🎓 Learning Outcomes

After completing this migration, you'll understand:

- ✅ FFI (Foreign Function Interface) in Nim
- ✅ Zero-knowledge proofs (RLN, Groth16)
- ✅ Merkle trees and proofs
- ✅ Stateful vs stateless architectures
- ✅ Smart contract integration
- ✅ Rust-Nim interop
- ✅ Build system configuration
- ✅ Large-scale refactoring

---

## 🙏 Acknowledgments

- **Ekaterina** - For detailed explanations and guidance
- **Zerokit Team** - For the new FFI implementation
- **nwaku Team** - For existing codebase

---

## 📅 Document History

- **2024-12-01:** Initial creation
- **Version:** 1.0
- **Status:** Ready for use

---

## 🚀 Ready to Start?

1. ✅ Read this README completely
2. ✅ Skim all three documents
3. ✅ Create feature branch: `git checkout -b zerokit_ffi_upgrade`
4. ✅ Open `RLN_PHASE1_IMPLEMENTATION.md`
5. ✅ Start Day 1, Task 1.1

**Good luck with the migration! 🎉**

---

**Questions?** Review the "Getting Help" section above.  
**Stuck?** Check the "Common Questions" section.  
**Need quick info?** Use the "Finding Information" section.

**Remember:** Take your time with Phase 1. Understanding now = confidence later! 💪
