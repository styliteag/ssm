/// Test Safety Module
/// 
/// Minimal safety checks for testing

use std::sync::Once;

static INIT: Once = Once::new();

/// Initialize test mode - minimal implementation
pub fn init_test_mode() {
    // For now, just ensure we're in test mode
    #[cfg(not(test))]
    panic!("Test utilities can only be used during testing");
    
    // Initialize logger once for all tests
    INIT.call_once(|| {
        // Set default log level if RUST_LOG is not set
        if std::env::var("RUST_LOG").is_err() {
            let args: Vec<String> = std::env::args().collect();
            
            let log_level = if args.iter().any(|arg| arg == "--nocapture") {
                "info"   // If user wants to see output, show info logs
            } else {
                "warn"   // Otherwise, minimal logging  
            };
            
            std::env::set_var("RUST_LOG", log_level);
        }
        
        // Only initialize if no logger is already set up
        if env_logger::try_init().is_err() {
            // Logger already initialized, that's fine
        }
    });
}