use crate::poseidon::{Poseidon as Hasher, PoseidonParams};
use sapling_crypto::bellman::pairing::ff::{Field, PrimeField, PrimeFieldRepr};
use sapling_crypto::bellman::pairing::Engine;
use std::io::{self, Error, ErrorKind};
use std::{collections::HashMap, hash::Hash};

enum SyncMode {
    Bootstarp,
    Maintain,
}

pub struct IncrementalMerkleTree<E>
where
    E: Engine,
{
    pub current_index: usize,
    merkle_tree: MerkleTree<E>,
}

impl<E> IncrementalMerkleTree<E>
where
    E: Engine,
{
    pub fn empty(hasher: Hasher<E>, depth: usize) -> Self {
        let mut zero: Vec<E::Fr> = Vec::with_capacity(depth + 1);
        zero.push(E::Fr::from_str("0").unwrap());
        for i in 0..depth {
            zero.push(hasher.hash([zero[i]; 2].to_vec()));
        }
        zero.reverse();
        let merkle_tree = MerkleTree {
            hasher: hasher,
            zero: zero.clone(),
            depth: depth,
            nodes: HashMap::new(),
        };
        let current_index: usize = 0;
        IncrementalMerkleTree {
            current_index,
            merkle_tree,
        }
    }

    pub fn update_next(&mut self, leaf: E::Fr) -> io::Result<()> {
        self.merkle_tree.update(self.current_index, leaf)?;
        self.current_index += 1;
        Ok(())
    }

    pub fn delete(&mut self, index: usize) -> io::Result<()> {
        let zero = E::Fr::from_str("0").unwrap();
        self.merkle_tree.update(index, zero)?;
        Ok(())
    }

    pub fn get_witness(&self, index: usize) -> io::Result<Vec<(E::Fr, bool)>> {
        if index >= self.current_index {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "index exceeds incremental index",
            ));
        }
        self.merkle_tree.get_witness(index)
    }

    pub fn hash(&self, inputs: Vec<E::Fr>) -> E::Fr {
        self.merkle_tree.hasher.hash(inputs)
    }

    pub fn check_inclusion(
        &self,
        witness: Vec<(E::Fr, bool)>,
        leaf_index: usize,
    ) -> io::Result<bool> {
        if leaf_index >= self.current_index {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "index exceeds incremental index",
            ));
        }
        self.merkle_tree.check_inclusion(witness, leaf_index)
    }

    pub fn get_root(&self) -> E::Fr {
        return self.merkle_tree.get_root();
    }
}

pub struct MerkleTree<E>
where
    E: Engine,
{
    pub hasher: Hasher<E>,
    pub depth: usize,
    zero: Vec<E::Fr>,
    nodes: HashMap<(usize, usize), E::Fr>,
}

impl<E> MerkleTree<E>
where
    E: Engine,
{
    pub fn empty(hasher: Hasher<E>, depth: usize) -> Self {
        let mut zero: Vec<E::Fr> = Vec::with_capacity(depth + 1);
        zero.push(E::Fr::from_str("0").unwrap());
        for i in 0..depth {
            zero.push(hasher.hash([zero[i]; 2].to_vec()));
        }
        zero.reverse();
        MerkleTree {
            hasher: hasher,
            zero: zero.clone(),
            depth: depth,
            nodes: HashMap::new(),
        }
    }

    pub fn set_size(&self) -> usize {
        1 << self.depth
    }

    pub fn update(&mut self, index: usize, leaf: E::Fr) -> io::Result<()> {
        if index >= self.set_size() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "index exceeds set size",
            ));
        }
        self.nodes.insert((self.depth, index), leaf);
        self.recalculate_from(index);
        Ok(())
    }

    pub fn check_inclusion(&self, witness: Vec<(E::Fr, bool)>, index: usize) -> io::Result<bool> {
        if index >= self.set_size() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "index exceeds set size",
            ));
        }
        let mut acc = self.get_node(self.depth, index);

        for w in witness.into_iter() {
            if w.1 {
                acc = self.hasher.hash(vec![acc, w.0]);
            } else {
                acc = self.hasher.hash(vec![w.0, acc]);
            }
        }
        Ok(acc.eq(&self.get_root()))
    }

    pub fn get_root(&self) -> E::Fr {
        return self.get_node(0, 0);
    }

    pub fn get_witness(&self, index: usize) -> io::Result<Vec<(E::Fr, bool)>> {
        if index >= self.set_size() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "index exceeds set size",
            ));
        }
        let mut witness = Vec::<(E::Fr, bool)>::with_capacity(self.depth);
        let mut i = index;
        let mut depth = self.depth;
        loop {
            i ^= 1;
            witness.push((self.get_node(depth, i), (i & 1 == 1)));
            i >>= 1;
            depth -= 1;
            if depth == 0 {
                break;
            }
        }
        assert_eq!(i, 0);
        Ok(witness)
    }

    fn get_node(&self, depth: usize, index: usize) -> E::Fr {
        let node = *self
            .nodes
            .get(&(depth, index))
            .unwrap_or_else(|| &self.zero[depth]);
        node
    }

    fn get_leaf(&self, index: usize) -> E::Fr {
        self.get_node(self.depth, index)
    }

    fn hash_couple(&mut self, depth: usize, index: usize) -> E::Fr {
        let b = index & !1;
        self.hasher
            .hash([self.get_node(depth, b), self.get_node(depth, b + 1)].to_vec())
    }

    fn recalculate_from(&mut self, index: usize) {
        let mut i = index;
        let mut depth = self.depth;
        loop {
            let h = self.hash_couple(depth, i);
            i >>= 1;
            depth -= 1;
            self.nodes.insert((depth, i), h);
            if depth == 0 {
                break;
            }
        }
        assert_eq!(depth, 0);
        assert_eq!(i, 0);
    }
}

#[test]
fn test_merkle_set() {
    let data: Vec<Fr> = (0..8)
        .map(|s| Fr::from_str(&format!("{}", s)).unwrap())
        .collect();
    use sapling_crypto::bellman::pairing::bn256::{Bn256, Fr, FrRepr};
    let params = PoseidonParams::<Bn256>::new(8, 55, 3, None, None, None);
    let hasher = Hasher::new(params);
    let mut set = MerkleTree::empty(hasher.clone(), 3);
    let leaf_index = 6;
    let leaf = hasher.hash(vec![data[0]]);
    set.update(leaf_index, leaf).unwrap();
    let witness = set.get_witness(leaf_index).unwrap();
    assert!(set.check_inclusion(witness, leaf_index).unwrap());
}
