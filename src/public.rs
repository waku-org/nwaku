use crate::circuit::rln::{RLNCircuit, RLNInputs};
use crate::merkle::MerkleTree;
use crate::poseidon::{Poseidon as PoseidonHasher, PoseidonParams};
use crate::utils::{read_fr, read_uncompressed_proof, write_uncompressed_proof};
use crate::{circuit::poseidon::PoseidonCircuit, merkle::IncrementalMerkleTree};
use bellman::groth16::generate_random_parameters;
use bellman::groth16::{create_proof, prepare_verifying_key, verify_proof};
use bellman::groth16::{create_random_proof, Parameters, Proof};
use bellman::pairing::ff::{Field, PrimeField, PrimeFieldRepr};
use bellman::pairing::{CurveAffine, EncodedPoint, Engine};
use bellman::{Circuit, ConstraintSystem, SynthesisError};
use rand::{Rand, SeedableRng, XorShiftRng};
use std::{
    io::{self, Error, ErrorKind, Read, Write},
    ptr::null,
};
// Rate Limit Nullifier

#[derive(Clone)]
pub struct RLNSignal<E>
where
    E: Engine,
{
    pub epoch: E::Fr,
    pub hash: E::Fr,
}

impl<E> RLNSignal<E>
where
    E: Engine,
{
    pub fn read<R: Read>(mut reader: R) -> io::Result<RLNSignal<E>> {
        let mut buf = <E::Fr as PrimeField>::Repr::default();

        buf.read_le(&mut reader)?;
        let hash =
            E::Fr::from_repr(buf).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        buf.read_le(&mut reader)?;
        let epoch =
            E::Fr::from_repr(buf).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;

        Ok(RLNSignal { epoch, hash })
    }

    pub fn write<W: Write>(&self, mut writer: W) -> io::Result<()> {
        self.epoch.into_repr().write_le(&mut writer).unwrap();
        self.hash.into_repr().write_le(&mut writer).unwrap();
        Ok(())
    }
}

pub struct RLN<E>
where
    E: Engine,
{
    circuit_parameters: Parameters<E>,
    poseidon_params: PoseidonParams<E>,
    tree: IncrementalMerkleTree<E>,
}

impl<E> RLN<E>
where
    E: Engine,
{
    fn default_poseidon_params() -> PoseidonParams<E> {
        PoseidonParams::<E>::new(8, 55, 3, None, None, None)
    }

    fn new_circuit(merkle_depth: usize, poseidon_params: PoseidonParams<E>) -> Parameters<E> {
        let mut rng = XorShiftRng::from_seed([0x3dbe6258, 0x8d313d76, 0x3237db17, 0xe5bc0654]);
        let inputs = RLNInputs::<E>::empty(merkle_depth);
        let circuit = RLNCircuit::<E> {
            inputs,
            hasher: PoseidonCircuit::new(poseidon_params.clone()),
        };
        generate_random_parameters(circuit, &mut rng).unwrap()
    }

    fn new_with_params(
        merkle_depth: usize,
        circuit_parameters: Parameters<E>,
        poseidon_params: PoseidonParams<E>,
    ) -> RLN<E> {
        let hasher = PoseidonHasher::new(poseidon_params.clone());
        let tree = IncrementalMerkleTree::empty(hasher, merkle_depth);
        RLN {
            circuit_parameters,
            poseidon_params,
            tree,
        }
    }

    pub fn new(merkle_depth: usize, poseidon_params: Option<PoseidonParams<E>>) -> RLN<E> {
        let poseidon_params = match poseidon_params {
            Some(params) => params,
            None => Self::default_poseidon_params(),
        };
        let circuit_parameters = Self::new_circuit(merkle_depth, poseidon_params.clone());
        Self::new_with_params(merkle_depth, circuit_parameters, poseidon_params)
    }

    pub fn new_with_raw_params<R: Read>(
        merkle_depth: usize,
        raw_circuit_parameters: R,
        poseidon_params: Option<PoseidonParams<E>>,
    ) -> io::Result<RLN<E>> {
        let circuit_parameters = Parameters::<E>::read(raw_circuit_parameters, true)?;
        let poseidon_params = match poseidon_params {
            Some(params) => params,
            None => Self::default_poseidon_params(),
        };
        Ok(Self::new_with_params(
            merkle_depth,
            circuit_parameters,
            poseidon_params,
        ))
    }

    //// inserts new member with given public key
    /// * `public_key_data` is a 32 scalar field element in 32 bytes
    pub fn update_next_member<R: Read>(&mut self, public_key_data: R) -> io::Result<()> {
        let mut buf = <E::Fr as PrimeField>::Repr::default();
        buf.read_le(public_key_data)?;
        let leaf =
            E::Fr::from_repr(buf).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        self.tree.update_next(leaf)?;
        Ok(())
    }

    //// deletes member with given index
    pub fn delete_member(&mut self, index: usize) -> io::Result<()> {
        self.tree.delete(index)?;
        Ok(())
    }

    /// hashes scalar field elements
    /// * expect numbers of scalar field element in 32 bytes in `input_data`
    /// * expect `result_data` is a scalar field element in 32 bytes
    /// * `n` is number of scalar field elemends stored in `input`
    pub fn hash<R: Read, W: Write>(
        &self,
        input_data: R,
        n: usize,
        mut result_data: W,
    ) -> io::Result<()> {
        let hasher = self.hasher();
        let input: Vec<E::Fr> = read_fr::<R, E>(input_data, n)?;
        let result = hasher.hash(input);
        result.into_repr().write_le(&mut result_data)?;
        Ok(())
    }

    /// given public inputs and autharization data generates public inputs and proof
    /// * expect `input`  serialized as |epoch<32>|signal_hash<32>|
    /// * expect `id_key_data` is a scalar field element in 32 bytes
    /// * `output_data` is proof data serialized as |proof<416>|root<32>|epoch<32>|share_x<32>|share_y<32>|nullifier<32>|
    pub fn generate_proof<R: Read, W: Write>(
        &self,
        input_data: R,
        id_key_data: R,
        member_index: usize,
        mut output_data: W,
    ) -> io::Result<()> {
        use rand::chacha::ChaChaRng;
        use rand::SeedableRng;
        let mut rng = ChaChaRng::new_unseeded();
        let signal = RLNSignal::<E>::read(input_data)?;
        // prepare inputs

        let hasher = self.hasher();
        let share_x = signal.hash.clone();

        let id_key: E::Fr = read_fr::<R, E>(id_key_data, 1)?[0];

        // line equation
        let a_0 = id_key.clone();
        let a_1: E::Fr = hasher.hash(vec![a_0, signal.epoch]);
        // evaluate line equation
        let mut share_y = a_1.clone();
        share_y.mul_assign(&share_x);
        share_y.add_assign(&a_0);
        let nullifier = hasher.hash(vec![a_1]);

        let root = self.tree.get_root();
        // TODO: check id key here
        let auth_path = self.tree.get_witness(member_index)?;

        let inputs = RLNInputs::<E> {
            share_x: Some(share_x),
            share_y: Some(share_y),
            epoch: Some(signal.epoch),
            nullifier: Some(nullifier),
            root: Some(root),
            id_key: Some(id_key),
            auth_path: auth_path.into_iter().map(|w| Some(w)).collect(),
        };

        let circuit = RLNCircuit {
            inputs: inputs.clone(),
            hasher: PoseidonCircuit::new(self.poseidon_params.clone()),
        };

        // TOOD: handle create proof error
        let proof = create_random_proof(circuit, &self.circuit_parameters, &mut rng).unwrap();
        write_uncompressed_proof(proof.clone(), &mut output_data)?;
        root.into_repr().write_le(&mut output_data)?;
        signal.epoch.into_repr().write_le(&mut output_data)?;
        share_x.into_repr().write_le(&mut output_data)?;
        share_y.into_repr().write_le(&mut output_data)?;
        nullifier.into_repr().write_le(&mut output_data)?;

        Ok(())
    }

    /// given proof and public data verifies the signal
    /// * expect `proof_data` is serialized as:
    /// |proof<416>|root<32>|epoch<32>|share_x<32>|share_y<32>|nullifier<32>|
    pub fn verify<R: Read>(&self, mut proof_data: R) -> io::Result<bool> {
        let proof = read_uncompressed_proof(&mut proof_data)?;
        let public_inputs = RLNInputs::<E>::read_public_inputs(&mut proof_data)?;
        // TODO: root must be checked here
        let verifing_key = prepare_verifying_key(&self.circuit_parameters.vk);
        let success = verify_proof(&verifing_key, &proof, &public_inputs).unwrap();
        Ok(success)
    }

    /// generates public private key pair
    /// * `key_pair_data` is seralized as |secret<32>|public<32>|
    pub fn key_gen<W: Write>(&self, mut key_pair_data: W) -> io::Result<()> {
        let mut rng = XorShiftRng::from_seed([0x3dbe6258, 0x8d313d76, 0x3237db17, 0xe5bc0654]);
        let hasher = self.hasher();
        let secret = E::Fr::rand(&mut rng);
        let public: E::Fr = hasher.hash(vec![secret.clone()]);
        secret.into_repr().write_le(&mut key_pair_data)?;
        public.into_repr().write_le(&mut key_pair_data)?;
        Ok(())
    }

    pub fn export_verifier_key<W: Write>(&self, w: W) -> io::Result<()> {
        self.circuit_parameters.vk.write(w)
    }

    pub fn export_circuit_parameters<W: Write>(&self, w: W) -> io::Result<()> {
        self.circuit_parameters.write(w)
    }

    pub fn hasher(&self) -> PoseidonHasher<E> {
        PoseidonHasher::new(self.poseidon_params.clone())
    }

    pub fn poseidon_params(&self) -> PoseidonParams<E> {
        self.poseidon_params.clone()
    }
}
