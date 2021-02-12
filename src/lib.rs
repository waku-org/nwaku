#![allow(dead_code)]
#![allow(unused_imports)]

pub mod circuit;
pub mod merkle;
pub mod poseidon;
pub mod public;
mod utils;

#[cfg(not(target_arch = "wasm32"))]
pub mod ffi;

#[cfg(target_arch = "wasm32")]
mod wasm;
