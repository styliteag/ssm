use static_files::resource_dir;

fn main() -> std::io::Result<()> {
    println!("cargo:rerun-if-changed=migrations");
    println!("cargo:rerun-if-changed=static");
    println!("cargo:rerun-if-changed=templates");
    resource_dir("./static").build()
}
