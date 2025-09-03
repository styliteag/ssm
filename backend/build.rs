use std::process::Command;
use std::path::Path;

fn main() {
    // Print build information
    // Print current package version for debugging
    println!("cargo:warning=Building SSM version {}", env!("CARGO_PKG_VERSION"));

    // Perform build-time checks
    println!("cargo:warning=Running pre-build checks...");

    check_curl_availability();

    println!("cargo:warning=Pre-build checks completed successfully");
}
/// Check if curl is available for utoipa-swagger-ui downloads
fn check_curl_availability() {
    match Command::new("curl").arg("--version").output() {
        Ok(output) if output.status.success() => {
            println!("cargo:warning=curl found, utoipa-swagger-ui should build successfully");
        }
        _ => {
            println!("cargo:warning=curl not found! utoipa-swagger-ui may fail to download assets");
            println!("cargo:warning=Consider installing curl or using a different Swagger UI solution");
        }
    }
}