//! globals — the emulator's global state.
//!
//! Zig port of Free42's `common/core_globals.h`: the RPN stack, LASTx, the
//! flags, the error codes, and the mode/entry state. This is the shared
//! mutable state every command reads and writes.

const std = @import("std");
const phloat = @import("phloat.zig");
const vartype = @import("vartype.zig");

// ---------------------------------------------------------------------------
// Error codes (matches ERR_* in core_globals.h)
// ---------------------------------------------------------------------------

pub const Err = enum(i32) {
    none = 0,
    alpha_data_is_invalid = 1,
    out_of_range = 2,
    divide_by_0 = 3,
    invalid_type = 4,
    invalid_data = 5,
    nonexistent = 6,
    dimension_error = 7,
    too_few_arguments = 8,
    size_error = 9,
    stack_depth_error = 10,
    restricted_operation = 11,
    yes = 12,
    no = 13,
    stop = 14,
    label_not_found = 15,
    no_real_variables = 16,
    no_complex_variables = 17,
    no_matrix_variables = 18,
    no_menu_variables = 19,
    stat_math_error = 20,
    invalid_forecast_model = 21,
    singular_matrix = 22,
    solve_solve = 23,
    integ_integ = 24,
    run = 25,
    interrupted = 26,
    printing_is_disabled = 27,
    interruptible = 28,
    no_variables = 29,
    insufficient_memory = 30,
    not_yet_implemented = 31,
    internal_error = 32,
    suspicious_off = 33,
    rtn_stack_full = 34,
    number_too_large = 35,
    number_too_small = 36,
    big_stack_disabled = 37,
    invalid_context = 38,
    name_too_long = 39,
};

/// Human-readable text for each error (subset of Free42's `errors[]`).
pub fn errText(e: Err) []const u8 {
    return switch (e) {
        .none => "",
        .alpha_data_is_invalid => "Alpha Data Is Invalid",
        .out_of_range => "Out of Range",
        .divide_by_0 => "Divide by 0",
        .invalid_type => "Invalid Type",
        .invalid_data => "Invalid Data",
        .nonexistent => "Nonexistent",
        .dimension_error => "Dimension Error",
        .too_few_arguments => "Too Few Arguments",
        .size_error => "Size Error",
        .stack_depth_error => "Stack Depth Error",
        .restricted_operation => "Restricted Operation",
        .yes => "Yes",
        .no => "No",
        .stop => "Stop",
        .label_not_found => "Label Not Found",
        .no_real_variables => "No Real Variables",
        .no_complex_variables => "No Complex Variables",
        .no_matrix_variables => "No Matrix Variables",
        .no_menu_variables => "No Menu Variables",
        .stat_math_error => "Stat Math Error",
        .invalid_forecast_model => "Invalid Forecast Model",
        .singular_matrix => "Singular Matrix",
        .solve_solve => "Solve(Solve)",
        .integ_integ => "∫(∫)",
        .run => "Run",
        .interrupted => "Interrupted",
        .printing_is_disabled => "Printing Is Disabled",
        .interruptible => "Interruptible",
        .no_variables => "No Variables",
        .insufficient_memory => "Insufficient Memory",
        .not_yet_implemented => "Not Yet Implemented",
        .internal_error => "Internal Error",
        .suspicious_off => "Suspicious OFF",
        .rtn_stack_full => "RTN Stack Full",
        .number_too_large => "Number Too Large",
        .number_too_small => "Number Too Small",
        .big_stack_disabled => "Big Stack Disabled",
        .invalid_context => "Invalid Context",
        .name_too_long => "Name Too Long",
    };
}

// ---------------------------------------------------------------------------
// The RPN stack
// ---------------------------------------------------------------------------

/// Stack register indices (matches REG_T/REG_Z/REG_Y/REG_X).
pub const REG_T: i32 = 0;
pub const REG_Z: i32 = 1;
pub const REG_Y: i32 = 2;
pub const REG_X: i32 = 3;

/// The stack: a dynamically-sized array of nullable vartype pointers.
/// In 4-level mode it holds exactly [T, Z, Y, X]; in big-stack mode it grows.
pub var stack: []?*vartype.Vartype = &.{};
/// Index of the X register (3 in 4-level mode; -1 for an empty big stack).
pub var sp: i32 = REG_X;
/// Allocated capacity of `stack`.
pub var stack_capacity: i32 = 0;
/// The LASTx register.
pub var lastx: ?*vartype.Vartype = null;

// ---------------------------------------------------------------------------
// Flags (matches flags_struct in core_globals.h)
// ---------------------------------------------------------------------------

pub const Flags = struct {
    // The subset of the 100 HP-42S flags the ported commands touch. The rest
    // are added as their commands land.
    stack_lift_disable: bool = false,
    big_stack: bool = false,
    range_error_ignore: bool = false,
    error_ignore: bool = false,
    decimal_point: bool = true, // true = dot, false = comma
    thousands_separators: bool = false,
    fix_or_all: bool = true,
    eng_or_all: bool = true,
    digits_bit3: bool = false,
    digits_bit2: bool = false,
    digits_bit1: bool = false,
    digits_bit0: bool = false,
    grad: bool = false,
    rad: bool = false,
    polar: bool = false,
    real_result_only: bool = false,
    audio_enable: bool = false,
    message: bool = false,
    two_line_message: bool = false,
    trace_print: bool = false,
    printer_exists: bool = false,
    prgm_mode: bool = false,
    local_label: bool = false,
    all_sigma: bool = false,
    log_fit_invalid: bool = false,
    exp_fit_invalid: bool = false,
    pwr_fit_invalid: bool = false,
};

pub var flags: Flags = .{};

// ---------------------------------------------------------------------------
// Core settings (matches core_settings_struct in core_main.h)
// ---------------------------------------------------------------------------

/// User-configurable core settings. The two matrix flags gate the HP-42S
/// compatible "fudge" behaviors in the linear-algebra engine:
///   - `matrix_singularmatrix`: when true, a zero pivot is an error; when
///     false (default), a tiny value is substituted so the computation
///     continues (HP-42S compatible).
///   - `matrix_outofrange`: when true, an infinite matrix result is an error;
///     when false (default), it is clamped to ±huge.
pub const Settings = struct {
    matrix_singularmatrix: bool = false,
    matrix_outofrange: bool = false,
};

pub var settings: Settings = .{};

// ---------------------------------------------------------------------------
// Mode / entry state
// ---------------------------------------------------------------------------

/// Set when the next number entry should not lift the stack (after CLX, ENTER,
/// STO, etc.).
pub var mode_disable_stack_lift: bool = false;
/// Non-zero while a number is being entered digit-by-digit.
pub var mode_number_entry: bool = false;
/// The number currently being entered (or last completed entry).
pub var entered_number: phloat.Phloat = undefined;
/// The exponent sign/state during EEX entry (not used in this slice).
pub var mode_shift: bool = false;

// ---------------------------------------------------------------------------
// Initialization
// ---------------------------------------------------------------------------

/// Reset the core to a freshly powered-on HP-42S: 4-level stack of zeros,
/// LASTx = 0, default flags.
pub fn init() void {
    phloat.init();
    resetStack();
}

/// Reset just the stack (used by CLST and hard reset).
pub fn resetStack() void {
    deinit();
    stack = std.heap.c_allocator.alloc(?*vartype.Vartype, 4) catch unreachable;
    stack_capacity = 4;
    sp = REG_X;
    for (stack) |*slot| {
        slot.* = vartype.newReal(phloat.fromInt(0)) orelse unreachable;
    }
    lastx = vartype.newReal(phloat.fromInt(0)) orelse unreachable;
    flags = .{};
    // The first number entry after power-on replaces X rather than lifting.
    mode_disable_stack_lift = true;
    mode_number_entry = false;
}

/// Free all heap state and reset the globals to their empty defaults. Safe to
/// call repeatedly; leaves `stack` empty and `lastx` null so a later `init()`
/// starts clean.
pub fn deinit() void {
    for (stack) |slot| vartype.freeOpt(slot);
    if (stack.len > 0) std.heap.c_allocator.free(stack);
    stack = &.{};
    stack_capacity = 0;
    sp = REG_X;
    if (lastx) |lx| vartype.free(lx);
    lastx = null;
}

// ---------------------------------------------------------------------------
// Stack helpers
// ---------------------------------------------------------------------------

/// Grow the stack to hold at least `n` more elements (big-stack mode only).
/// Returns false on allocation failure.
pub fn ensureStackCapacity(n: i32) bool {
    if (!flags.big_stack) return true;
    if (stack_capacity > sp + n) return true;
    const new_capacity: usize = @intCast(stack_capacity + n + 16);
    const new_stack = std.heap.c_allocator.realloc(stack, new_capacity) catch return false;
    stack = new_stack;
    stack_capacity = @intCast(new_capacity);
    return true;
}

/// Shrink the stack to fit (big-stack mode only).
pub fn shrinkStack() void {
    const new_capacity: usize = @intCast(@max(sp + 1, 4));
    if (std.heap.c_allocator.realloc(stack, new_capacity)) |new_stack| {
        stack = new_stack;
        stack_capacity = @intCast(new_capacity);
    } else |_| {}
}

/// The current display digit count (0..11) from the four digit flags.
pub fn displayDigits() u8 {
    var d: u8 = 0;
    if (flags.digits_bit3) d += 8;
    if (flags.digits_bit2) d += 4;
    if (flags.digits_bit1) d += 2;
    if (flags.digits_bit0) d += 1;
    return d;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "init sets up a 4-level stack of zeros" {
    init();
    defer deinit();
    try std.testing.expectEqual(@as(i32, REG_X), sp);
    try std.testing.expectEqual(@as(usize, 4), stack.len);
    for (stack) |slot| {
        try std.testing.expectEqualStrings("0", phloat.toString(slot.?.real));
    }
    try std.testing.expectEqualStrings("0", phloat.toString(lastx.?.real));
}
