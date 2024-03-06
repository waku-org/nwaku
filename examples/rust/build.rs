
fn main() {
    println!("cargo:rustc-link-arg=-lwaku");
    println!("cargo:rustc-link-arg=-L../../build/");
}
