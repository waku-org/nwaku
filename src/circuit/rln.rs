use crate::circuit::polynomial::allocate_add_with_coeff;
use crate::circuit::poseidon::PoseidonCircuit;
use crate::poseidon::{Poseidon as PoseidonHasher, PoseidonParams};
use sapling_crypto::bellman::pairing::ff::{Field, PrimeField, PrimeFieldRepr};
use sapling_crypto::bellman::pairing::Engine;
use sapling_crypto::bellman::{Circuit, ConstraintSystem, SynthesisError, Variable};
use sapling_crypto::circuit::{boolean, ecc, num, Assignment};
use sapling_crypto::jubjub::{JubjubEngine, JubjubParams, PrimeOrder};

use std::io::{self, Read, Write};

// Rate Limit Nullifier

#[derive(Clone)]
pub struct RLNInputs<E>
where
    E: Engine,
{
    // Public inputs

    // share, (x, y),
    // where x should be hash of the signal
    // and y is the evaluation
    pub share_x: Option<E::Fr>,
    pub share_y: Option<E::Fr>,

    // epoch is the external nullifier
    // we derive the line equation and the nullifier from epoch
    pub epoch: Option<E::Fr>,

    // nullifier
    pub nullifier: Option<E::Fr>,

    // root is the current state of membership set
    pub root: Option<E::Fr>,

    // Private inputs

    // id_key must be a preimage of a leaf in membership tree.
    // id_key also together with epoch will be used to construct
    // a secret line equation together with the epoch
    pub id_key: Option<E::Fr>,

    // authentication path of the member
    pub auth_path: Vec<Option<(E::Fr, bool)>>,
}

impl<E> RLNInputs<E>
where
    E: Engine,
{
    pub fn public_inputs(&self) -> Vec<E::Fr> {
        vec![
            self.root.unwrap(),
            self.epoch.unwrap(),
            self.share_x.unwrap(),
            self.share_y.unwrap(),
            self.nullifier.unwrap(),
        ]
    }

    pub fn merkle_depth(&self) -> usize {
        self.auth_path.len()
    }

    pub fn empty(merkle_depth: usize) -> RLNInputs<E> {
        RLNInputs::<E> {
            share_x: None,
            share_y: None,
            epoch: None,
            nullifier: None,
            root: None,
            id_key: None,
            auth_path: vec![None; merkle_depth],
        }
    }

    pub fn read<R: Read>(mut reader: R) -> io::Result<RLNInputs<E>> {
        let mut buf = <E::Fr as PrimeField>::Repr::default();

        buf.read_le(&mut reader)?;
        let share_x =
            E::Fr::from_repr(buf).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;

            
        buf.read_le(&mut reader)?;
        let share_y =
            E::Fr::from_repr(buf).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        buf.read_le(&mut reader)?;
        let epoch =
            E::Fr::from_repr(buf).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        buf.read_le(&mut reader)?;
        let nullifier =
            E::Fr::from_repr(buf).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        buf.read_le(&mut reader)?;
        let root =
            E::Fr::from_repr(buf).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        buf.read_le(&mut reader)?;
        let id_key =
            E::Fr::from_repr(buf).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        let auth_path = Self::decode_auth_path(&mut reader)?;
        Ok(RLNInputs {
            share_x: Some(share_x),
            share_y: Some(share_y),
            epoch: Some(epoch),
            nullifier: Some(nullifier),
            root: Some(root),
            id_key: Some(id_key),
            auth_path,
        })
    }

    pub fn write<W: Write>(&self, mut writer: W) -> io::Result<()> {
        self.share_x
            .unwrap()
            .into_repr()
            .write_le(&mut writer)
            .unwrap();
        self.share_y
            .unwrap()
            .into_repr()
            .write_le(&mut writer)
            .unwrap();
        self.epoch
            .unwrap()
            .into_repr()
            .write_le(&mut writer)
            .unwrap();
        self.nullifier
            .unwrap()
            .into_repr()
            .write_le(&mut writer)
            .unwrap();
        self.root
            .unwrap()
            .into_repr()
            .write_le(&mut writer)
            .unwrap();
        self.id_key
            .unwrap()
            .into_repr()
            .write_le(&mut writer)
            .unwrap();
        Self::encode_auth_path(&mut writer, self.auth_path.clone()).unwrap();
        Ok(())
    }

    pub fn read_public_inputs<R: Read>(mut reader: R) -> io::Result<Vec<E::Fr>> {
        let mut buf = <E::Fr as PrimeField>::Repr::default();
        buf.read_le(&mut reader)?;
        let root =
            E::Fr::from_repr(buf).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        buf.read_le(&mut reader)?;
        let epoch =
            E::Fr::from_repr(buf).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        buf.read_le(&mut reader)?;
        let share_x =
            E::Fr::from_repr(buf).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        buf.read_le(&mut reader)?;
        let share_y =
            E::Fr::from_repr(buf).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        buf.read_le(&mut reader)?;
        let nullifier =
            E::Fr::from_repr(buf).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        Ok(vec![root, epoch, share_x, share_y, nullifier])
    }

    pub fn write_public_inputs<W: Write>(&self, mut writer: W) -> io::Result<()> {
        self.root.unwrap().into_repr().write_le(&mut writer)?;
        self.epoch.unwrap().into_repr().write_le(&mut writer)?;
        self.share_x.unwrap().into_repr().write_le(&mut writer)?;
        self.share_y.unwrap().into_repr().write_le(&mut writer)?;
        self.nullifier.unwrap().into_repr().write_le(&mut writer)?;
        Ok(())
    }

    pub fn encode_auth_path<W: Write>(
        mut writer: W,
        auth_path: Vec<Option<(E::Fr, bool)>>,
    ) -> io::Result<()> {
        let path_len = auth_path.len() as u8;
        writer.write(&[path_len])?;
        for el in auth_path.iter() {
            let c = el.unwrap();
            if c.1 {
                writer.write(&[1])?;
            } else {
                writer.write(&[0])?;
            }
            c.0.into_repr().write_le(&mut writer).unwrap();
        }
        Ok(())
    }

    pub fn decode_auth_path<R: Read>(mut reader: R) -> io::Result<Vec<Option<(E::Fr, bool)>>> {
        let mut byte_buf = vec![0u8; 1];
        let mut el_buf = <E::Fr as PrimeField>::Repr::default();
        let mut auth_path: Vec<Option<(E::Fr, bool)>> = vec![];
        reader.read_exact(&mut byte_buf)?;
        let path_len = byte_buf[0];
        if path_len < 2 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid path length",
            ));
        }
        for _ in 0..path_len {
            reader.read_exact(&mut byte_buf)?;
            let path_dir = match byte_buf[0] {
                0u8 => false,
                1u8 => true,
                _ => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "invalid path direction",
                    ))
                }
            };
            el_buf.read_le(&mut reader)?;
            let node = E::Fr::from_repr(el_buf)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
            auth_path.push(Some((node, path_dir)));
        }
        Ok(auth_path)
    }
}

#[derive(Clone)]
pub struct RLNCircuit<E>
where
    E: Engine,
{
    pub inputs: RLNInputs<E>,
    pub hasher: PoseidonCircuit<E>,
}

impl<E> Circuit<E> for RLNCircuit<E>
where
    E: Engine,
{
    fn synthesize<CS: ConstraintSystem<E>>(self, cs: &mut CS) -> Result<(), SynthesisError> {
        // 1. Part
        // Membership constraints
        // root == merkle_proof(auth_path, preimage_of_leaf)

        let root = num::AllocatedNum::alloc(cs.namespace(|| "root"), || {
            let value = self.inputs.root.clone();
            Ok(*value.get()?)
        })?;
        root.inputize(cs.namespace(|| "root is public"))?;

        let preimage = num::AllocatedNum::alloc(cs.namespace(|| "preimage"), || {
            let value = self.inputs.id_key;
            Ok(*value.get()?)
        })?;

        // identity is a leaf of membership tree

        let identity = self
            .hasher
            .alloc(cs.namespace(|| "identity"), vec![preimage.clone()])?;

        // accumulator up to the root

        let mut acc = identity.clone();

        // ascend the tree

        let auth_path_witness = self.inputs.auth_path.clone();
        for (i, e) in auth_path_witness.into_iter().enumerate() {
            let cs = &mut cs.namespace(|| format!("auth path {}", i));
            let position = boolean::Boolean::from(boolean::AllocatedBit::alloc(
                cs.namespace(|| "position bit"),
                e.map(|e| e.1),
            )?);
            let path_element =
                num::AllocatedNum::alloc(cs.namespace(|| "path element"), || Ok(e.get()?.0))?;

            let (xr, xl) = num::AllocatedNum::conditionally_reverse(
                cs.namespace(|| "conditional reversal of preimage"),
                &acc,
                &path_element,
                &position,
            )?;

            acc = self
                .hasher
                .alloc(cs.namespace(|| "hash couple"), vec![xl, xr])?;
        }

        // see if it is a member

        cs.enforce(
            || "enforce membership",
            |lc| lc + acc.get_variable(),
            |lc| lc + CS::one(),
            |lc| lc + root.get_variable(),
        );

        // 2. Part
        // Line Equation Constaints
        // a_1 = hash(a_0, epoch)
        // share_y == a_0 + a_1 * share_x

        let epoch = num::AllocatedNum::alloc(cs.namespace(|| "epoch"), || {
            let value = self.inputs.epoch.clone();
            Ok(*value.get()?)
        })?;
        epoch.inputize(cs.namespace(|| "epoch is public"))?;

        let a_0 = preimage.clone();

        // a_1 == h(a_0, epoch)

        let a_1 = self
            .hasher
            .alloc(cs.namespace(|| "a_1"), vec![a_0.clone(), epoch])?;

        let share_x = num::AllocatedNum::alloc(cs.namespace(|| "share x"), || {
            let value = self.inputs.share_x.clone();
            Ok(*value.get()?)
        })?;
        share_x.inputize(cs.namespace(|| "share x is public"))?;

        // constaint the evaluation the line equation

        let eval = allocate_add_with_coeff(cs.namespace(|| "eval"), &a_1, &share_x, &a_0)?;

        let share_y = num::AllocatedNum::alloc(cs.namespace(|| "share y"), || {
            let value = self.inputs.share_y.clone();
            Ok(*value.get()?)
        })?;
        share_y.inputize(cs.namespace(|| "share y is public"))?;

        // see if share satisfies the line equation

        cs.enforce(
            || "enforce lookup",
            |lc| lc + share_y.get_variable(),
            |lc| lc + CS::one(),
            |lc| lc + eval.get_variable(),
        );

        // 3. Part
        // Nullifier constraints

        // hashing secret twice with epoch ingredient
        // a_1 == hash(a_0, epoch) is already constrained

        // nullifier == hash(a_1)

        let nullifier_calculated = self
            .hasher
            .alloc(cs.namespace(|| "calculated nullifier"), vec![a_1.clone()])?;

        let nullifier = num::AllocatedNum::alloc(cs.namespace(|| "nullifier"), || {
            let value = self.inputs.nullifier.clone();
            Ok(*value.get()?)
        })?;
        nullifier.inputize(cs.namespace(|| "nullifier is public"))?;

        // check if correct nullifier supplied

        cs.enforce(
            || "enforce nullifier",
            |lc| lc + nullifier_calculated.get_variable(),
            |lc| lc + CS::one(),
            |lc| lc + nullifier.get_variable(),
        );

        Ok(())
    }
}

#[cfg(test)]
mod test {

    use super::RLNInputs;
    use crate::circuit::bench;
    use crate::poseidon::PoseidonParams;
    use sapling_crypto::bellman::pairing::bls12_381::Bls12;
    use sapling_crypto::bellman::pairing::bn256::Bn256;
    use sapling_crypto::bellman::pairing::Engine;

    struct TestSuite<E: Engine> {
        merkle_depth: usize,
        poseidon_parameters: PoseidonParams<E>,
    }

    fn cases<E: Engine>() -> Vec<TestSuite<E>> {
        vec![
            TestSuite {
                merkle_depth: 3,
                poseidon_parameters: PoseidonParams::new(8, 55, 3, None, None, None),
            },
            TestSuite {
                merkle_depth: 24,
                poseidon_parameters: PoseidonParams::new(8, 55, 3, None, None, None),
            },
            TestSuite {
                merkle_depth: 32,
                poseidon_parameters: PoseidonParams::new(8, 55, 3, None, None, None),
            },
            TestSuite {
                merkle_depth: 16,
                poseidon_parameters: PoseidonParams::new(8, 33, 3, None, None, None),
            },
            TestSuite {
                merkle_depth: 24,
                poseidon_parameters: PoseidonParams::new(8, 33, 3, None, None, None),
            },
            TestSuite {
                merkle_depth: 32,
                poseidon_parameters: PoseidonParams::new(8, 33, 3, None, None, None),
            },
        ]
    }

    #[test]
    fn test_rln_bn() {
        use sapling_crypto::bellman::pairing::bn256::Bn256;
        let cases = cases::<Bn256>();
        for case in cases.iter() {
            let rln_test = bench::RLNTest::<Bn256>::new(
                case.merkle_depth,
                Some(case.poseidon_parameters.clone()),
            );
            let num_constraints = rln_test.synthesize();
            let result = rln_test.run_prover_bench();
            println!(
                "bn256, t: {}, rf: {}, rp: {}, merkle depth: {}",
                case.poseidon_parameters.width(),
                case.poseidon_parameters.full_round_half_len() * 2,
                case.poseidon_parameters.partial_round_len(),
                case.merkle_depth,
            );
            println!("number of constatins:\t{}", num_constraints);
            println!("prover key size:\t{}", result.prover_key_size);
            println!("prover time:\t{}", result.prover_time);
        }
    }

    #[test]
    fn test_input_serialization() {
        use sapling_crypto::bellman::pairing::bn256::{Bn256, Fr};
        use sapling_crypto::bellman::pairing::ff::{Field, PrimeField, PrimeFieldRepr};
        let share_x = Fr::from_str("1").unwrap();
        let share_y = Fr::from_str("2").unwrap();
        let epoch = Fr::from_str("3").unwrap();
        let nullifier = Fr::from_str("4").unwrap();
        let root = Fr::from_str("5").unwrap();
        let id_key = Fr::from_str("6").unwrap();
        let auth_path = vec![
            Some((Fr::from_str("20").unwrap(), false)),
            Some((Fr::from_str("21").unwrap(), true)),
            Some((Fr::from_str("22").unwrap(), true)),
            Some((Fr::from_str("23").unwrap(), false)),
        ];
        let input0 = RLNInputs::<Bn256> {
            share_x: Some(share_x),
            share_y: Some(share_y),
            epoch: Some(epoch),
            nullifier: Some(nullifier),
            root: Some(root),
            id_key: Some(id_key),
            auth_path,
        };
        let mut raw_inputs: Vec<u8> = Vec::new();
        input0.write(&mut raw_inputs).unwrap();
        let mut reader = raw_inputs.as_slice();
        let input1 = RLNInputs::<Bn256>::read(&mut reader).unwrap();
        assert_eq!(input0.share_x, input1.share_x);
        assert_eq!(input0.share_y, input1.share_y);
        assert_eq!(input0.epoch, input1.epoch);
        assert_eq!(input0.nullifier, input1.nullifier);
        assert_eq!(input0.root, input1.root);
        assert_eq!(input0.id_key, input1.id_key);
        assert_eq!(input0.auth_path, input1.auth_path);
    }
}
