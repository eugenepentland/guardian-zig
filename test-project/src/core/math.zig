// Core math module — boundary rule: must NOT import from utils/
const helpers = @import("../utils/helpers.zig");

pub fn add(a: i32, b: i32) i32 {
    _ = helpers;
    return a + b;
}

pub fn multiply(a: i32, b: i32) i32 {
    return a * b;
}

pub fn zero() i32 {
    return 0;
}
