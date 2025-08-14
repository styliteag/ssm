use std::fs;

fn main() -> std::io::Result<()> {
    // Propagate version from VERSION file into compile-time environment variable
    if let Ok(ver) = fs::read_to_string("../VERSION") {
        println!("cargo:rustc-env=APP_VERSION={}", ver.trim());
        // Re-run build script if VERSION changes
        println!("cargo:rerun-if-changed=../VERSION");
    }
    println!("cargo:rerun-if-changed=migrations");
    Ok(())
}
