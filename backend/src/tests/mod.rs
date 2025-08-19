/// Modern Test Framework
/// 
/// Clean, minimal testing setup that actually works.

// Core test utilities - keep these minimal
pub mod test_utils;
pub mod safety;

// Modern test framework - build incrementally  
pub mod test_app;

// Mock SSH - only if we need it
pub mod mock_ssh;

// Test modules - add one at a time
pub mod basic_tests;