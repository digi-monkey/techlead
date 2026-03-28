//! Characterization Tests Root Module
//!
//! This module imports all characterization tests that document the current
//! CLI behavior. These tests serve as a baseline for refactoring, ensuring
//! that behavior remains consistent across changes.

const std = @import("std");

// Import all characterization test modules
// Note: These tests document observed behavior rather than asserting correctness

// Tests for init command behavior
pub const init_tests = @import("init_test.zig");

// Tests for run command behavior
pub const run_tests = @import("run_test.zig");

// Characterization test metadata
pub const characterization_info = .{
    .version = "2.0.0",
    .purpose = "Document current CLI behavior for refactoring baseline",
    .commands_characterized = &[_][]const u8{
        "init",
        "run",
        "--help",
    },
    .generated_date = "2025-03-14",
};

// Test to verify test module loads correctly
test "characterization: test module loads" {
    // This test verifies the characterization test infrastructure is working
    const info = characterization_info;
    std.debug.assert(info.version.len > 0);
    std.debug.assert(info.commands_characterized.len > 0);
}
