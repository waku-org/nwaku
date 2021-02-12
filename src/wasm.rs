use crate::public::RLN;

use std::io::{self, Error, ErrorKind, Read, Write};
use wasm_bindgen::prelude::*;

use js_sys::Array;
use sapling_crypto::bellman::pairing::bn256::{Bn256, Fr};

pub fn set_panic_hook() {
    // When the `console_error_panic_hook` feature is enabled, we can call the
    // `set_panic_hook` function at least once during initialization, and then
    // we will get better error messages if our code ever panics.
    //
    // For more details see
    // https://github.com/rustwasm/console_error_panic_hook#readme
    // #[cfg(feature = "console_error_panic_hook")]
    console_error_panic_hook::set_once();
}

#[wasm_bindgen]
pub struct RLNWasm {
    api: RLN<Bn256>,
}

#[wasm_bindgen]
impl RLNWasm {
    #[wasm_bindgen]
    pub fn new(merkle_depth: usize) -> RLNWasm {
        set_panic_hook();
        RLNWasm {
            api: RLN::<Bn256>::new(merkle_depth, None),
        }
    }

    #[wasm_bindgen]
    pub fn new_with_raw_params(
        merkle_depth: usize,
        raw_circuit_parameters: &[u8],
    ) -> Result<RLNWasm, JsValue> {
        set_panic_hook();
        let api = match RLN::new_with_raw_params(merkle_depth, raw_circuit_parameters, None) {
            Ok(api) => api,
            Err(e) => return Err(e.to_string().into()),
        };
        Ok(RLNWasm { api })
    }

    #[wasm_bindgen]
    pub fn generate_proof(&self, input: &[u8]) -> Result<Vec<u8>, JsValue> {
        let proof = match self.api.generate_proof(input) {
            Ok(proof) => proof,
            Err(e) => return Err(e.to_string().into()),
        };
        Ok(proof)
    }

    #[wasm_bindgen]
    pub fn verify(
        &self,
        uncompresed_proof: &[u8],
        raw_public_inputs: &[u8],
    ) -> Result<bool, JsValue> {
        let success = match self.api.verify(uncompresed_proof, raw_public_inputs) {
            Ok(success) => success,
            Err(e) => return Err(e.to_string().into()),
        };
        Ok(success)
    }

    #[wasm_bindgen]
    pub fn export_verifier_key(&self) -> Result<Vec<u8>, JsValue> {
        let mut output: Vec<u8> = Vec::new();
        match self.api.export_verifier_key(&mut output) {
            Ok(_) => (),
            Err(e) => return Err(e.to_string().into()),
        };
        Ok(output)
    }

    #[wasm_bindgen]
    pub fn export_circuit_parameters(&self) -> Result<Vec<u8>, JsValue> {
        let mut output: Vec<u8> = Vec::new();
        match self.api.export_circuit_parameters(&mut output) {
            Ok(_) => (),
            Err(e) => return Err(e.to_string().into()),
        };
        Ok(output)
    }
}

#[cfg(test)]
mod test {

    use crate::circuit::bench;
    use wasm_bindgen_test::*;

    use crate::circuit::poseidon::PoseidonCircuit;
    use crate::circuit::rln::{RLNCircuit, RLNInputs};
    use crate::merkle::MerkleTree;
    use crate::poseidon::{Poseidon as PoseidonHasher, PoseidonParams};
    use bellman::groth16::{generate_random_parameters, Parameters, Proof};
    use bellman::pairing::bn256::{Bn256, Fr};
    use bellman::pairing::ff::{Field, PrimeField, PrimeFieldRepr};
    use rand::{Rand, SeedableRng, XorShiftRng};

    #[wasm_bindgen_test]
    fn test_rln_wasm() {
        let merkle_depth = 3usize;
        let poseidon_params = PoseidonParams::<Bn256>::new(8, 55, 3, None, None, None);
        let rln_test = bench::RLNTest::<Bn256>::new(merkle_depth, Some(poseidon_params));

        let rln_wasm = super::RLNWasm::new(merkle_depth);

        let mut raw_inputs: Vec<u8> = Vec::new();
        let inputs = rln_test.valid_inputs();
        inputs.write(&mut raw_inputs);

        // let now = Instant::now();
        let proof = rln_wasm.generate_proof(raw_inputs.as_slice()).unwrap();
        // let prover_time = now.elapsed().as_millis() as f64 / 1000.0;

        let mut raw_public_inputs: Vec<u8> = Vec::new();
        inputs.write_public_inputs(&mut raw_public_inputs);

        assert_eq!(
            rln_wasm
                .verify(proof.as_slice(), raw_public_inputs.as_slice())
                .unwrap(),
            true
        );
    }
}
