use std::process::Command;
use std::path::Path;
use std::fs;

fn main() {
    // Print build information
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=CARGO_PKG_VERSION");

    // Create assets directory for custom downloads if needed
    let out_dir = std::env::var("OUT_DIR").unwrap();
    let assets_dir = Path::new(&out_dir).join("assets");
    fs::create_dir_all(&assets_dir).unwrap();

    // Verify curl is available for utoipa-swagger-ui
    let _curl_available = match Command::new("curl").arg("--version").output() {
        Ok(output) if output.status.success() => {
            println!("cargo:warning=curl found, utoipa-swagger-ui should build successfully");
            true
        }
        _ => {
            println!("cargo:warning=curl not found! utoipa-swagger-ui may fail to download assets");
            println!("cargo:warning=Consider installing curl or using a different Swagger UI solution");
            false
        }
    };

    // Print current package version for debugging
    println!("cargo:warning=Building SSM version {}", env!("CARGO_PKG_VERSION"));

    // If you want to take control of Swagger UI downloads in the future, uncomment this:
    /*
    if !curl_available {
        download_swagger_ui_fallback(&assets_dir);
    }
    */
}

#[allow(dead_code)]
fn download_swagger_ui_fallback(_assets_dir: &Path) {
    // Fallback download using reqwest if available
    println!("cargo:warning=Attempting fallback download of Swagger UI...");

    // This would require adding reqwest as a build dependency
    // For now, just warn the user
    println!("cargo:warning=Fallback download not implemented yet");
    println!("cargo:warning=Consider adding reqwest as a build dependency for offline builds");
}
