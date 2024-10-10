
fn main() {
    println!("cargo:rustc-link-arg=-lwaku");
    println!("cargo:rustc-link-arg=-L../../build/");
    println!("cargo:rustc-link-lib=ws2_32");
    println!("cargo:rustc-link-lib=crypt32");
    println!("cargo:rustc-link-lib=userenv");
    println!("cargo:rustc-link-lib=ntdll");
    println!("cargo:rustc-link-lib=kernel32");
    println!("cargo:rustc-link-lib=user32");
    println!("cargo:rustc-link-lib=advapi32");
}
