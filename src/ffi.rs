use crate::{circuit::rln, public::RLN};
use bellman::pairing::bn256::Bn256;
use std::slice;

/// Buffer struct is taken from
/// https://github.com/celo-org/celo-threshold-bls-rs/blob/master/crates/threshold-bls-ffi/src/ffi.rs

#[repr(C)]
#[derive(Clone, Debug, PartialEq)]
pub struct Buffer {
    pub ptr: *const u8,
    pub len: usize,
}

impl From<&[u8]> for Buffer {
    fn from(src: &[u8]) -> Self {
        Self {
            ptr: &src[0] as *const u8,
            len: src.len(),
        }
    }
}

impl<'a> From<&Buffer> for &'a [u8] {
    fn from(src: &Buffer) -> &'a [u8] {
        unsafe { slice::from_raw_parts(src.ptr, src.len) }
    }
}
#[repr(C)]
#[derive(Clone, Debug, PartialEq)]
pub struct Auth {
    secret_buffer: *const Buffer,
    pub index: usize,
}

impl Auth {
    fn get_secret(&self) -> &[u8] {
        let secret_data = <&[u8]>::from(unsafe { &*self.secret_buffer });
        secret_data
    }
}

#[no_mangle]
pub extern "C" fn new_circuit_from_params(
    merkle_depth: usize,
    parameters_buffer: *const Buffer,
    ctx: *mut *mut RLN<Bn256>,
) -> bool {
    let buffer = <&[u8]>::from(unsafe { &*parameters_buffer });
    let rln = match RLN::<Bn256>::new_with_raw_params(merkle_depth, buffer, None) {
        Ok(rln) => rln,
        Err(_) => return false,
    };
    unsafe { *ctx = Box::into_raw(Box::new(rln)) };
    true
}

#[no_mangle]
pub extern "C" fn update_next_member(ctx: *mut RLN<Bn256>, input_buffer: *const Buffer) -> bool {
    let rln = unsafe { &mut *ctx };
    let input_data = <&[u8]>::from(unsafe { &*input_buffer });
    match rln.update_next_member(input_data) {
        Ok(_) => true,
        Err(_) => false,
    }
}

#[no_mangle]
pub extern "C" fn delete_member(ctx: *mut RLN<Bn256>, index: usize) -> bool {
    let rln = unsafe { &mut *ctx };
    match rln.delete_member(index) {
        Ok(_) => true,
        Err(_) => false,
    }
}

#[no_mangle]
pub extern "C" fn generate_proof(
    ctx: *const RLN<Bn256>,
    input_buffer: *const Buffer,
    auth: *const Auth,
    output_buffer: *mut Buffer,
) -> bool {
    let rln = unsafe { &*ctx };
    let auth = unsafe { &*auth };
    let input_data = <&[u8]>::from(unsafe { &*input_buffer });
    let mut output_data: Vec<u8> = Vec::new();

    match rln.generate_proof(input_data, auth.get_secret(), auth.index, &mut output_data) {
        Ok(proof_data) => proof_data,
        Err(_) => return false,
    };
    unsafe { *output_buffer = Buffer::from(&output_data[..]) };
    std::mem::forget(output_data);
    true
}

#[no_mangle]
pub extern "C" fn verify(
    ctx: *const RLN<Bn256>,
    proof_buffer: *mut Buffer,
    result_ptr: *mut u32,
) -> bool {
    let rln = unsafe { &*ctx };
    let proof_data = <&[u8]>::from(unsafe { &*proof_buffer });
    if match rln.verify(proof_data) {
        Ok(verified) => verified,
        Err(_) => return false,
    } {
        unsafe { *result_ptr = 0 };
    } else {
        unsafe { *result_ptr = 1 };
    };
    true
}

#[no_mangle]
pub extern "C" fn hash(
    ctx: *const RLN<Bn256>,
    inputs_buffer: *const Buffer,
    input_len: usize,
    output_buffer: *mut Buffer,
) -> bool {
    let rln = unsafe { &*ctx };
    let input_data = <&[u8]>::from(unsafe { &*inputs_buffer });
    let mut output_data: Vec<u8> = Vec::new();
    match rln.hash(input_data, input_len, &mut output_data) {
        Ok(output_data) => output_data,
        Err(_) => return false,
    };
    unsafe { *output_buffer = Buffer::from(&output_data[..]) };
    std::mem::forget(output_data);
    true
}

#[no_mangle]
pub extern "C" fn key_gen(ctx: *const RLN<Bn256>, keypair_buffer: *mut Buffer) -> bool {
    let rln = unsafe { &*ctx };
    let mut output_data: Vec<u8> = Vec::new();
    match rln.key_gen(&mut output_data) {
        Ok(_) => (),
        Err(_) => return false,
    }
    unsafe { *keypair_buffer = Buffer::from(&output_data[..]) };
    std::mem::forget(output_data);
    true
}

use sapling_crypto::bellman::pairing::ff::{Field, PrimeField, PrimeFieldRepr};
use sapling_crypto::bellman::pairing::Engine;
use std::io::{self, Read, Write};

#[cfg(test)]
mod tests {
    use crate::{circuit::bench, public::RLNSignal};
    use crate::{poseidon::PoseidonParams, public};
    use bellman::pairing::bn256::{Bn256, Fr};
    use rand::{Rand, SeedableRng, XorShiftRng};

    use super::*;
    use std::mem::MaybeUninit;

    fn merkle_depth() -> usize {
        3usize
    }

    fn index() -> usize {
        2usize
    }

    fn rln_test() -> bench::RLNTest<Bn256> {
        let merkle_depth = merkle_depth();
        let poseidon_params = PoseidonParams::<Bn256>::new(8, 55, 3, None, None, None);
        let rln_test = bench::RLNTest::<Bn256>::new(merkle_depth, Some(poseidon_params));
        rln_test
    }

    fn rln_pointer(circuit_parameters: Vec<u8>) -> MaybeUninit<*mut RLN<Bn256>> {
        // restore this new curcuit with bindings
        let merkle_depth = merkle_depth();
        let circuit_parameters_buffer = &Buffer::from(circuit_parameters.as_ref());
        let mut rln_pointer = MaybeUninit::<*mut RLN<Bn256>>::uninit();
        let success = new_circuit_from_params(
            merkle_depth,
            circuit_parameters_buffer,
            rln_pointer.as_mut_ptr(),
        );
        assert!(success, "cannot init rln instance");

        rln_pointer
    }

    #[test]
    fn test_proof_ffi() {
        let mut rng = XorShiftRng::from_seed([0x3dbe6258, 0x8d313d76, 0x3237db17, 0xe5bc0654]);

        // setup new rln instance
        let rln_test = rln_test();
        let mut circuit_parameters: Vec<u8> = Vec::new();
        rln_test
            .export_circuit_parameters(&mut circuit_parameters)
            .unwrap();
        let rln_pointer = rln_pointer(circuit_parameters);
        let rln_pointer = unsafe { &mut *rln_pointer.assume_init() };
        let index = index();

        // generate new key pair
        let mut keypair_buffer = MaybeUninit::<Buffer>::uninit();
        let success = key_gen(rln_pointer, keypair_buffer.as_mut_ptr());
        assert!(success, "key generation failed");
        let keypair_buffer = unsafe { keypair_buffer.assume_init() };
        let mut keypair_data = <&[u8]>::from(&keypair_buffer);

        // read keypair
        let mut buf = <Fr as PrimeField>::Repr::default();
        buf.read_le(&mut keypair_data).unwrap();
        let id_key = Fr::from_repr(buf).unwrap();
        buf.read_le(&mut keypair_data).unwrap();
        let public_key = Fr::from_repr(buf).unwrap();

        // insert members
        for i in 0..index + 1 {
            let new_member: Fr;
            if i == index {
                new_member = public_key;
            } else {
                new_member = Fr::rand(&mut rng);
            }
            let mut input_data: Vec<u8> = Vec::new();
            new_member.into_repr().write_le(&mut input_data).unwrap();
            let input_buffer = &Buffer::from(input_data.as_ref());

            let success = update_next_member(rln_pointer, input_buffer);
            assert!(success, "update with new pubkey failed");
        }

        let mut gen_proof_and_verify = |rln_pointer: *const RLN<Bn256>| {
            // create signal
            let epoch = Fr::rand(&mut rng);
            let signal_hash = Fr::rand(&mut rng);
            let inputs = RLNSignal::<Bn256> {
                epoch: epoch,
                hash: signal_hash,
            };

            // serialize signal
            let mut inputs_data: Vec<u8> = Vec::new();
            inputs.write(&mut inputs_data).unwrap();
            let inputs_buffer = &Buffer::from(inputs_data.as_ref());

            // construct auth object
            let mut secret_data: Vec<u8> = Vec::new();
            id_key.into_repr().write_le(&mut secret_data).unwrap();
            let secret_buffer = &Buffer::from(secret_data.as_ref());
            let auth = &Auth {
                secret_buffer,
                index,
            } as *const Auth;

            // generate proof
            let mut proof_buffer = MaybeUninit::<Buffer>::uninit();
            let success =
                generate_proof(rln_pointer, inputs_buffer, auth, proof_buffer.as_mut_ptr());
            assert!(success, "proof generation failed");
            let mut proof_buffer = unsafe { proof_buffer.assume_init() };

            // verify proof
            let mut result = 0u32;
            let result_ptr = &mut result as *mut u32;
            let success = verify(rln_pointer, &mut proof_buffer, result_ptr);
            assert!(success, "verification failed");
            assert_eq!(0, result);
        };

        gen_proof_and_verify(rln_pointer);

        // delete 0th member
        let success = delete_member(rln_pointer, 0);
        assert!(success, "deletion failed");

        // gen proof & verify once more
        gen_proof_and_verify(rln_pointer);
    }

    #[test]
    fn test_hash_ffi() {
        let rln_test = rln_test();
        let mut circuit_parameters: Vec<u8> = Vec::new();
        rln_test
            .export_circuit_parameters(&mut circuit_parameters)
            .unwrap();
        let hasher = rln_test.hasher();
        let rln_pointer = rln_pointer(circuit_parameters);
        let rln_pointer = unsafe { &*rln_pointer.assume_init() };
        let mut input_data: Vec<u8> = Vec::new();

        let inputs: Vec<Fr> = ["1", "2"]
            .iter()
            .map(|e| Fr::from_str(e).unwrap())
            .collect();
        inputs.iter().for_each(|e| {
            e.into_repr().write_le(&mut input_data).unwrap();
        });
        let input_buffer = &Buffer::from(input_data.as_ref());

        let input_len: usize = 2;

        let expected = hasher.hash(inputs);
        let mut expected_data: Vec<u8> = Vec::new();
        expected.into_repr().write_le(&mut expected_data).unwrap();

        let mut result_buffer = MaybeUninit::<Buffer>::uninit();

        let success = hash(
            rln_pointer,
            input_buffer,
            input_len,
            result_buffer.as_mut_ptr(),
        );

        assert!(success, "hash ffi call failed");

        let result_buffer = unsafe { result_buffer.assume_init() };
        let result_data = <&[u8]>::from(&result_buffer);
        assert_eq!(expected_data.as_slice(), result_data);
    }

    #[test]
    fn test_keygen_ffi() {
        let rln_test = rln_test();

        let mut circuit_parameters: Vec<u8> = Vec::new();
        rln_test
            .export_circuit_parameters(&mut circuit_parameters)
            .unwrap();
        let hasher = rln_test.hasher();

        let rln_pointer = rln_pointer(circuit_parameters);
        let rln_pointer = unsafe { &*rln_pointer.assume_init() };

        let mut keypair_buffer = MaybeUninit::<Buffer>::uninit();

        let success = key_gen(rln_pointer, keypair_buffer.as_mut_ptr());
        assert!(success, "proof generation failed");

        let keypair_buffer = unsafe { keypair_buffer.assume_init() };
        let mut keypair_data = <&[u8]>::from(&keypair_buffer);

        let mut buf = <Fr as PrimeField>::Repr::default();
        buf.read_le(&mut keypair_data).unwrap();
        let secret = Fr::from_repr(buf).unwrap();
        buf.read_le(&mut keypair_data).unwrap();
        let public = Fr::from_repr(buf).unwrap();
        let expected_public: Fr = hasher.hash(vec![secret]);

        assert_eq!(public, expected_public);
    }

    #[test]
    #[ignore]
    fn test_parameters_from_file() {
        use hex;
        use std::fs;
        let data = fs::read("./parameters.key").expect("Unable to read file");
        let merkle_depth = merkle_depth();
        let circuit_parameters_buffer = &Buffer::from(data.as_ref());
        let mut rln_pointer = MaybeUninit::<*mut RLN<Bn256>>::uninit();
        let success = new_circuit_from_params(
            merkle_depth,
            circuit_parameters_buffer,
            rln_pointer.as_mut_ptr(),
        );
        assert!(success, "creating failed");
    }
}
