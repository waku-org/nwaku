#[cfg(not(target_arch = "wasm32"))]
fn main() {
    use sapling_crypto::bellman::pairing::bn256::Bn256;
    let merkle_depth = 32usize;
    test_keys::export::<Bn256>(merkle_depth);
}

#[cfg(target_arch = "wasm32")]
fn main() {
    panic!("should not be run in wasm");
}

#[cfg(not(target_arch = "wasm32"))]
mod test_keys {
    use sapling_crypto::bellman::pairing::Engine;
    pub fn export<E: Engine>(merkle_depth: usize) {
        use rand::{SeedableRng, XorShiftRng};
        use rln::circuit::poseidon::PoseidonCircuit;
        use rln::circuit::rln::{RLNCircuit, RLNInputs};
        use rln::poseidon::PoseidonParams;
        use sapling_crypto::bellman::groth16::generate_random_parameters;
        use std::fs::File;

        let poseidon_params = PoseidonParams::<E>::new(8, 55, 3, None, None, None);
        let mut rng = XorShiftRng::from_seed([0x3dbe6258, 0x8d313d76, 0x3237db17, 0xe5bc0654]);
        let hasher = PoseidonCircuit::new(poseidon_params.clone());
        let circuit = RLNCircuit::<E> {
            inputs: RLNInputs::<E>::empty(merkle_depth),
            hasher: hasher.clone(),
        };
        let parameters = generate_random_parameters(circuit, &mut rng).unwrap();
        let mut file_vk = File::create("verifier.key").unwrap();
        let vk = parameters.vk.clone();
        vk.write(&mut file_vk).unwrap();
        let mut file_paramaters = File::create("parameters.key").unwrap();
        parameters.write(&mut file_paramaters).unwrap();
    }
}
