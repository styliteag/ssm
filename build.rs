use static_files::resource_dir;

fn main() -> std::io::Result<()> {
    println!("cargo:rerun-if-changed=migrations");
    resource_dir("./static").build()
}
