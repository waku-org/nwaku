use blake2::{Blake2s, Digest};

use sapling_crypto::bellman::pairing::ff::{Field, PrimeField, PrimeFieldRepr};
use sapling_crypto::bellman::pairing::Engine;

#[derive(Clone)]
pub struct PoseidonParams<E: Engine> {
    rf: usize,
    rp: usize,
    t: usize,
    round_constants: Vec<E::Fr>,
    mds_matrix: Vec<E::Fr>,
}

#[derive(Clone)]
pub struct Poseidon<E: Engine> {
    params: PoseidonParams<E>,
}

impl<E: Engine> PoseidonParams<E> {
    pub fn new(
        rf: usize,
        rp: usize,
        t: usize,
        round_constants: Option<Vec<E::Fr>>,
        mds_matrix: Option<Vec<E::Fr>>,
        seed: Option<Vec<u8>>,
    ) -> PoseidonParams<E> {
        let seed = match seed {
            Some(seed) => seed,
            None => b"".to_vec(),
        };

        let _round_constants = match round_constants {
            Some(round_constants) => round_constants,
            None => PoseidonParams::<E>::generate_constants(b"drlnhdsc", seed.clone(), rf + rp),
        };
        assert_eq!(rf + rp, _round_constants.len());

        let _mds_matrix = match mds_matrix {
            Some(mds_matrix) => mds_matrix,
            None => PoseidonParams::<E>::generate_mds_matrix(b"drlnhdsm", seed.clone(), t),
        };
        PoseidonParams {
            rf,
            rp,
            t,
            round_constants: _round_constants,
            mds_matrix: _mds_matrix,
        }
    }

    pub fn width(&self) -> usize {
        return self.t;
    }

    pub fn partial_round_len(&self) -> usize {
        return self.rp;
    }

    pub fn full_round_half_len(&self) -> usize {
        return self.rf / 2;
    }

    pub fn total_rounds(&self) -> usize {
        return self.rf + self.rp;
    }

    pub fn round_constant(&self, round: usize) -> E::Fr {
        return self.round_constants[round];
    }

    pub fn mds_matrix_row(&self, i: usize) -> Vec<E::Fr> {
        let w = self.width();
        self.mds_matrix[i * w..(i + 1) * w].to_vec()
    }

    pub fn mds_matrix(&self) -> Vec<E::Fr> {
        self.mds_matrix.clone()
    }

    pub fn generate_mds_matrix(persona: &[u8; 8], seed: Vec<u8>, t: usize) -> Vec<E::Fr> {
        let v: Vec<E::Fr> = PoseidonParams::<E>::generate_constants(persona, seed, t * 2);
        let mut matrix: Vec<E::Fr> = Vec::with_capacity(t * t);
        for i in 0..t {
            for j in 0..t {
                let mut tmp = v[i];
                tmp.add_assign(&v[t + j]);
                let entry = tmp.inverse().unwrap();
                matrix.insert((i * t) + j, entry);
            }
        }
        matrix
    }

    pub fn generate_constants(persona: &[u8; 8], seed: Vec<u8>, len: usize) -> Vec<E::Fr> {
        let mut constants: Vec<E::Fr> = Vec::new();
        let mut source = seed.clone();
        loop {
            let mut hasher = Blake2s::new();
            hasher.input(persona);
            hasher.input(source);
            source = hasher.result().to_vec();
            let mut candidate_repr = <E::Fr as PrimeField>::Repr::default();
            candidate_repr.read_le(&source[..]).unwrap();
            if let Ok(candidate) = E::Fr::from_repr(candidate_repr) {
                constants.push(candidate);
                if constants.len() == len {
                    break;
                }
            }
        }
        constants
    }
}

impl<E: Engine> Poseidon<E> {
    pub fn new(params: PoseidonParams<E>) -> Poseidon<E> {
        Poseidon { params }
    }

    pub fn hash(&self, inputs: Vec<E::Fr>) -> E::Fr {
        let mut state = inputs.clone();
        state.resize(self.t(), E::Fr::zero());
        let mut round_counter: usize = 0;
        loop {
            self.round(&mut state, round_counter);
            round_counter += 1;
            if round_counter == self.params.total_rounds() {
                break;
            }
        }
        state[0]
    }

    fn t(&self) -> usize {
        self.params.t
    }

    fn round(&self, state: &mut Vec<E::Fr>, round: usize) {
        let a1 = self.params.full_round_half_len();
        let a2 = a1 + self.params.partial_round_len();
        let a3 = self.params.total_rounds();
        if round < a1 {
            self.full_round(state, round);
        } else if round >= a1 && round < a2 {
            self.partial_round(state, round);
        } else if round >= a2 && round < a3 {
            if round == a3 - 1 {
                self.full_round_last(state);
            } else {
                self.full_round(state, round);
            }
        } else {
            panic!("should not be here")
        }
    }

    fn full_round(&self, state: &mut Vec<E::Fr>, round: usize) {
        self.add_round_constants(state, round);
        self.apply_quintic_sbox(state, true);
        self.mul_mds_matrix(state);
    }

    fn full_round_last(&self, state: &mut Vec<E::Fr>) {
        let last_round = self.params.total_rounds() - 1;
        self.add_round_constants(state, last_round);
        self.apply_quintic_sbox(state, true);
    }

    fn partial_round(&self, state: &mut Vec<E::Fr>, round: usize) {
        self.add_round_constants(state, round);
        self.apply_quintic_sbox(state, false);
        self.mul_mds_matrix(state);
    }

    fn add_round_constants(&self, state: &mut Vec<E::Fr>, round: usize) {
        for (_, b) in state.iter_mut().enumerate() {
            let c = self.params.round_constants[round];
            b.add_assign(&c);
        }
    }

    fn apply_quintic_sbox(&self, state: &mut Vec<E::Fr>, full: bool) {
        for s in state.iter_mut() {
            let mut b = s.clone();
            b.square();
            b.square();
            s.mul_assign(&b);
            if !full {
                break;
            }
        }
    }

    fn mul_mds_matrix(&self, state: &mut Vec<E::Fr>) {
        let w = self.params.t;
        let mut new_state = vec![E::Fr::zero(); w];
        for (i, ns) in new_state.iter_mut().enumerate() {
            for (j, s) in state.iter().enumerate() {
                let mut tmp = s.clone();
                tmp.mul_assign(&self.params.mds_matrix[i * w + j]);
                ns.add_assign(&tmp);
            }
        }
        for (i, ns) in new_state.iter_mut().enumerate() {
            state[i].clone_from(ns);
        }
    }
}

#[test]
fn test_poseidon_hash() {
    use sapling_crypto::bellman::pairing::bn256;
    use sapling_crypto::bellman::pairing::bn256::{Bn256, Fr};
    let params = PoseidonParams::<Bn256>::new(8, 55, 3, None, None, None);
    let hasher = Poseidon::<Bn256>::new(params);
    let input1: Vec<Fr> = ["0"].iter().map(|e| Fr::from_str(e).unwrap()).collect();
    let r1: Fr = hasher.hash(input1.to_vec());
    let input2: Vec<Fr> = ["0", "0"]
        .iter()
        .map(|e| Fr::from_str(e).unwrap())
        .collect();
    let r2: Fr = hasher.hash(input2.to_vec());
    // println!("{:?}", r1);
    assert_eq!(r1, r2, "just to see if internal state resets");
}
