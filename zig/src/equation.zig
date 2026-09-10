//! equation — the Equation Writer (HP 50g equivalent).
//!
//! Lets an AI partner (or a human) "throw" an equation as written, without
//! thinking about RPN math or operation order. `evalEquation` parses an
//! algebraic expression and pushes the result onto the stack:
//!
//!     evalEquation("det([[1,2],[3,4]])")   → -2
//!     evalEquation("sin(0.1) + cos(0.2)")  → exact decimal
//!     evalEquation("(1+2)*3^2")            → 27
//!
//! Grammar (standard precedence, tightest first):
//!     postfix  := primary ('!')*            factorial
//!     power    := postfix ('^' factor)?     right-associative
//!     factor   := ('-'|'+') factor | power  unary sign
//!     term     := factor (('*'|'/') factor)*
//!     expr     := term (('+'|'-') term)*
//!     primary  := number | ident | '(' expr ')' | '[' array ']' | func '(' args ')'
//!
//! An array literal is `[e1, e2, …]`; a matrix is an array of arrays
//! (`[[1,2],[3,4]]`), matching the DB48X-grade nested-array model. Identifiers
//! resolve to named variables (STO/RCL) unless they name a function or the
//! constants `pi`/`e`.
//!
//! The evaluator is pure: it builds `?*Vartype` values and only touches the
//! stack at the end (via `helpers.recallResult`), so it composes cleanly with
//! the MCP layer. Arithmetic reuses `helpers.genericAdd/Sub/Mul/Div` (which
//! already dispatch matrix×matrix to the linear-algebra engine); unary and
//! power functions reuse `helpers.mapUnary`/`mapBinary` with scalar mappables
//! defined here.

const std = @import("std");
const phloat = @import("phloat.zig");
const vartype = @import("vartype.zig");
const globals = @import("globals.zig");
const helpers = @import("helpers.zig");
const linalg = @import("linalg.zig");
const variables = @import("variables.zig");

const Err = globals.Err;
const Vartype = vartype.Vartype;

// ---------------------------------------------------------------------------
// Function table
// ---------------------------------------------------------------------------

/// The operations the Equation Writer knows. Unary ops take one argument,
/// binary ops take two.
const Op = enum {
    add, sub, mul, div,
    sin, cos, tan, asin, acos, atan,
    sinh, cosh, tanh, asinh, acosh, atanh,
    ln, log, exp, sqrt, sq, abs, sign, ip, fp, fact, deg, rad,
    det, trans, inv,
    pow, mod, dot, cross,
};

const Func = struct { name: []const u8, arity: u8, op: Op };

const funcs = [_]Func{
    .{ .name = "sin", .arity = 1, .op = .sin },
    .{ .name = "cos", .arity = 1, .op = .cos },
    .{ .name = "tan", .arity = 1, .op = .tan },
    .{ .name = "asin", .arity = 1, .op = .asin },
    .{ .name = "acos", .arity = 1, .op = .acos },
    .{ .name = "atan", .arity = 1, .op = .atan },
    .{ .name = "sinh", .arity = 1, .op = .sinh },
    .{ .name = "cosh", .arity = 1, .op = .cosh },
    .{ .name = "tanh", .arity = 1, .op = .tanh },
    .{ .name = "asinh", .arity = 1, .op = .asinh },
    .{ .name = "acosh", .arity = 1, .op = .acosh },
    .{ .name = "atanh", .arity = 1, .op = .atanh },
    .{ .name = "ln", .arity = 1, .op = .ln },
    .{ .name = "log", .arity = 1, .op = .log },
    .{ .name = "exp", .arity = 1, .op = .exp },
    .{ .name = "sqrt", .arity = 1, .op = .sqrt },
    .{ .name = "sq", .arity = 1, .op = .sq },
    .{ .name = "abs", .arity = 1, .op = .abs },
    .{ .name = "sign", .arity = 1, .op = .sign },
    .{ .name = "ip", .arity = 1, .op = .ip },
    .{ .name = "fp", .arity = 1, .op = .fp },
    .{ .name = "fact", .arity = 1, .op = .fact },
    .{ .name = "deg", .arity = 1, .op = .deg },
    .{ .name = "rad", .arity = 1, .op = .rad },
    .{ .name = "det", .arity = 1, .op = .det },
    .{ .name = "trans", .arity = 1, .op = .trans },
    .{ .name = "inv", .arity = 1, .op = .inv },
    .{ .name = "pow", .arity = 2, .op = .pow },
    .{ .name = "mod", .arity = 2, .op = .mod },
    .{ .name = "dot", .arity = 2, .op = .dot },
    .{ .name = "cross", .arity = 2, .op = .cross },
};

fn lookupFunc(name: []const u8) ?Func {
    for (funcs) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

const Parser = struct {
    src: []const u8,
    pos: usize = 0,

    fn peek(self: *const Parser) u8 {
        if (self.pos >= self.src.len) return 0;
        return self.src[self.pos];
    }
    fn peekAt(self: *const Parser, off: usize) u8 {
        if (self.pos + off >= self.src.len) return 0;
        return self.src[self.pos + off];
    }
    fn advance(self: *Parser) void {
        if (self.pos < self.src.len) self.pos += 1;
    }
    fn skipWs(self: *Parser) void {
        while (self.pos < self.src.len and isSpace(self.src[self.pos])) self.pos += 1;
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}
fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

// ---------------------------------------------------------------------------
// Recursive-descent parse (evaluates as it parses, into `out`)
// ---------------------------------------------------------------------------

fn parseExpr(p: *Parser, out: *?*Vartype) Err {
    var e = parseTerm(p, out);
    if (e != .none) return e;
    while (true) {
        p.skipWs();
        const c = p.peek();
        if (c == '+') {
            p.advance();
            var rhs: ?*Vartype = null;
            e = parseTerm(p, &rhs);
            if (e != .none) {
                vartype.freeOpt(rhs);
                vartype.freeOpt(out.*);
                out.* = null;
                return e;
            }
            e = applyBinaryOp(.add, out.*.?, rhs.?, out);
            if (e != .none) return e;
        } else if (c == '-') {
            p.advance();
            var rhs: ?*Vartype = null;
            e = parseTerm(p, &rhs);
            if (e != .none) {
                vartype.freeOpt(rhs);
                vartype.freeOpt(out.*);
                out.* = null;
                return e;
            }
            e = applyBinaryOp(.sub, out.*.?, rhs.?, out);
            if (e != .none) return e;
        } else break;
    }
    return .none;
}

fn parseTerm(p: *Parser, out: *?*Vartype) Err {
    var e = parseFactor(p, out);
    if (e != .none) return e;
    while (true) {
        p.skipWs();
        const c = p.peek();
        if (c == '*') {
            p.advance();
            var rhs: ?*Vartype = null;
            e = parseFactor(p, &rhs);
            if (e != .none) {
                vartype.freeOpt(rhs);
                vartype.freeOpt(out.*);
                out.* = null;
                return e;
            }
            e = applyBinaryOp(.mul, out.*.?, rhs.?, out);
            if (e != .none) return e;
        } else if (c == '/') {
            p.advance();
            var rhs: ?*Vartype = null;
            e = parseFactor(p, &rhs);
            if (e != .none) {
                vartype.freeOpt(rhs);
                vartype.freeOpt(out.*);
                out.* = null;
                return e;
            }
            e = applyBinaryOp(.div, out.*.?, rhs.?, out);
            if (e != .none) return e;
        } else break;
    }
    return .none;
}

fn parseFactor(p: *Parser, out: *?*Vartype) Err {
    p.skipWs();
    const c = p.peek();
    if (c == '-') {
        p.advance();
        const e = parseFactor(p, out);
        if (e != .none) return e;
        negateInPlace(out.*.?);
        return .none;
    }
    if (c == '+') {
        p.advance();
        return parseFactor(p, out);
    }
    return parsePower(p, out);
}

fn parsePower(p: *Parser, out: *?*Vartype) Err {
    var e = parsePostfix(p, out);
    if (e != .none) return e;
    p.skipWs();
    if (p.peek() == '^') {
        p.advance();
        var rhs: ?*Vartype = null;
        e = parseFactor(p, &rhs); // right-assoc, so the exponent may be signed
        if (e != .none) {
            vartype.freeOpt(rhs);
            vartype.freeOpt(out.*);
            return e;
        }
        return applyBinaryOp(.pow, out.*.?, rhs.?, out);
    }
    return .none;
}

fn parsePostfix(p: *Parser, out: *?*Vartype) Err {
    var e = parsePrimary(p, out);
    if (e != .none) return e;
    p.skipWs();
    while (p.peek() == '!') {
        p.advance();
        e = applyUnary(.fact, out.*.?, out);
        if (e != .none) return e;
        p.skipWs();
    }
    return .none;
}

fn parsePrimary(p: *Parser, out: *?*Vartype) Err {
    p.skipWs();
    const c = p.peek();
    if (isDigit(c) or c == '.') return parseNumber(p, out);
    if (c == '(') {
        p.advance();
        const e = parseExpr(p, out);
        if (e != .none) return e;
        p.skipWs();
        if (p.peek() != ')') {
            vartype.freeOpt(out.*);
            out.* = null;
            return .syntax_error;
        }
        p.advance();
        return .none;
    }
    if (c == '[') return parseArray(p, out);
    if (isIdentStart(c)) return parseIdent(p, out);
    return .syntax_error;
}

fn parseNumber(p: *Parser, out: *?*Vartype) Err {
    const start = p.pos;
    while (isDigit(p.peek())) p.advance();
    if (p.peek() == '.') {
        p.advance();
        while (isDigit(p.peek())) p.advance();
    }
    const c = p.peek();
    if (c == 'e' or c == 'E') {
        const n1 = p.peekAt(1);
        const n2 = p.peekAt(2);
        if (isDigit(n1) or ((n1 == '+' or n1 == '-') and isDigit(n2))) {
            p.advance();
            if (p.peek() == '+' or p.peek() == '-') p.advance();
            while (isDigit(p.peek())) p.advance();
        }
    }
    out.* = vartype.newReal(phloat.fromString(p.src[start..p.pos])) orelse return .insufficient_memory;
    return .none;
}

fn parseIdent(p: *Parser, out: *?*Vartype) Err {
    const start = p.pos;
    while (isIdentChar(p.peek())) p.advance();
    const name = p.src[start..p.pos];
    p.skipWs();
    if (p.peek() == '(') return callFunction(p, name, out);

    if (std.mem.eql(u8, name, "pi")) {
        out.* = vartype.newReal(phloat.PI) orelse return .insufficient_memory;
        return .none;
    }
    if (std.mem.eql(u8, name, "e")) {
        out.* = vartype.newReal(phloat.E) orelse return .insufficient_memory;
        return .none;
    }
    const v = variables.recallVar(name) orelse return .nonexistent;
    out.* = vartype.dup(v) orelse return .insufficient_memory;
    return .none;
}

fn callFunction(p: *Parser, name: []const u8, out: *?*Vartype) Err {
    const f = lookupFunc(name) orelse return .syntax_error;
    p.advance(); // consume '('
    p.skipWs();
    if (p.peek() == ')') return .syntax_error; // no zero-arg functions

    var a: ?*Vartype = null;
    var b: ?*Vartype = null;

    var e = parseExpr(p, &a);
    if (e != .none) {
        vartype.freeOpt(a);
        return e;
    }
    if (f.arity == 2) {
        p.skipWs();
        if (p.peek() != ',') {
            vartype.freeOpt(a);
            return .syntax_error;
        }
        p.advance();
        e = parseExpr(p, &b);
        if (e != .none) {
            vartype.freeOpt(a);
            vartype.freeOpt(b);
            return e;
        }
    }
    p.skipWs();
    if (p.peek() != ')') {
        vartype.freeOpt(a);
        vartype.freeOpt(b);
        return .syntax_error;
    }
    p.advance();

    // Ownership of a/b transfers to the apply function, which frees them.
    if (f.arity == 2) {
        return applyBinaryOp(f.op, a.?, b.?, out);
    }
    return applyUnary(f.op, a.?, out);
}

/// Parse an array literal `[e1, e2, …]`. Each element is an expression; a
/// matrix is an array whose elements are themselves arrays.
fn parseArray(p: *Parser, out: *?*Vartype) Err {
    p.advance(); // consume '['
    p.skipWs();
    if (p.peek() == ']') {
        p.advance();
        out.* = vartype.newArray(0) orelse return .insufficient_memory;
        return .none;
    }

    const alloc = std.heap.c_allocator;
    var elems: []?*Vartype = &.{};
    var count: usize = 0;
    defer {
        for (elems[0..count]) |it| vartype.freeOpt(it);
        if (elems.len > 0) alloc.free(elems);
    }

    while (true) {
        var elem: ?*Vartype = null;
        const e = parseExpr(p, &elem);
        if (e != .none) {
            vartype.freeOpt(elem);
            return e;
        }
        if (count == elems.len) {
            const new_len = if (elems.len == 0) @as(usize, 4) else elems.len * 2;
            const ne = alloc.realloc(elems, new_len) catch {
                vartype.freeOpt(elem);
                return .insufficient_memory;
            };
            elems = ne;
        }
        elems[count] = elem;
        count += 1;
        p.skipWs();
        if (p.peek() == ',') {
            p.advance();
            continue;
        }
        if (p.peek() == ']') {
            p.advance();
            break;
        }
        return .syntax_error;
    }

    const a = vartype.newArray(@intCast(count)) orelse return .insufficient_memory;
    for (elems[0..count], 0..) |it, i| a.array.data[i] = it;
    count = 0; // elements now owned by `a`; the defer frees only the buffer
    out.* = a;
    return .none;
}

// ---------------------------------------------------------------------------
// Operation application (owned operands in, fresh result out)
// ---------------------------------------------------------------------------

/// Apply a unary op: `src` is consumed (freed), `out` receives the result.
fn applyUnary(op: Op, src: *Vartype, out: *?*Vartype) Err {
    var res: ?*Vartype = null;
    const e = switch (op) {
        .det => linalg.linalgDet(src, &res),
        .inv => if (vartype.matrixInfo(src) != null)
            linalg.linalgInv(src, &res)
        else
            helpers.mapUnary(src, &res, invR, invC),
        .trans => transpose(src, &res),
        .abs => absUnary(src, &res),
        else => blk: {
            const m = unaryMappable(op);
            break :blk helpers.mapUnary(src, &res, m.r, m.c);
        },
    };
    vartype.free(src);
    if (e != .none) {
        out.* = null;
        return e;
    }
    out.* = res;
    return .none;
}

/// Apply a binary op: `left`/`right` are consumed, `out` receives the result.
fn applyBinaryOp(op: Op, left: *Vartype, right: *Vartype, out: *?*Vartype) Err {
    var res: ?*Vartype = null;
    const e = switch (op) {
        // genericAdd/Sub/Mul/Div compute `py OP px`, so pass (right, left).
        .add => helpers.genericAdd(right, left, &res),
        .sub => helpers.genericSub(right, left, &res),
        .mul => helpers.genericMul(right, left, &res),
        .div => helpers.genericDiv(right, left, &res),
        // pow/mod mappables compute `x OP y` in natural order, so pass (left, right).
        .pow => helpers.mapBinary(left, right, &res, powRR, powRC, powCR, powCC),
        .mod => helpers.mapBinary(left, right, &res, modRR, modRC, modCR, modCC),
        .dot => dotProduct(left, right, &res),
        .cross => crossProduct(left, right, &res),
        else => .internal_error,
    };
    vartype.free(left);
    vartype.free(right);
    if (e != .none) {
        out.* = null;
        return e;
    }
    out.* = res;
    return .none;
}

// ---------------------------------------------------------------------------
// Unary mappable table
// ---------------------------------------------------------------------------

const Mappable = struct { r: helpers.MappableR, c: helpers.MappableC };

fn unaryMappable(op: Op) Mappable {
    return switch (op) {
        .sin => .{ .r = sinR, .c = sinC },
        .cos => .{ .r = cosR, .c = cosC },
        .tan => .{ .r = tanR, .c = tanC },
        .asin => .{ .r = asinR, .c = notComplex },
        .acos => .{ .r = acosR, .c = notComplex },
        .atan => .{ .r = atanR, .c = notComplex },
        .sinh => .{ .r = sinhR, .c = sinhC },
        .cosh => .{ .r = coshR, .c = coshC },
        .tanh => .{ .r = tanhR, .c = tanhC },
        .asinh => .{ .r = asinhR, .c = notComplex },
        .acosh => .{ .r = acoshR, .c = notComplex },
        .atanh => .{ .r = atanhR, .c = notComplex },
        .ln => .{ .r = lnR, .c = lnC },
        .log => .{ .r = logR, .c = logC },
        .exp => .{ .r = expR, .c = expC },
        .sqrt => .{ .r = sqrtR, .c = sqrtC },
        .sq => .{ .r = sqR, .c = sqC },
        .sign => .{ .r = signR, .c = notComplex },
        .ip => .{ .r = ipR, .c = notComplex },
        .fp => .{ .r = fpR, .c = notComplex },
        .fact => .{ .r = factR, .c = notComplex },
        .deg => .{ .r = degR, .c = notComplex },
        .rad => .{ .r = radR, .c = notComplex },
        else => .{ .r = notReal, .c = notComplex },
    };
}

// ---------------------------------------------------------------------------
// Angle helpers
// ---------------------------------------------------------------------------

fn toRad(x: phloat.Phloat) phloat.Phloat {
    if (globals.flags.rad) return x;
    if (globals.flags.grad) return phloat.mul(x, phloat.div(phloat.PI, phloat.fromInt(200)));
    return helpers.degToRad(x);
}
fn fromRad(x: phloat.Phloat) phloat.Phloat {
    if (globals.flags.rad) return x;
    if (globals.flags.grad) return phloat.mul(x, phloat.div(phloat.fromInt(200), phloat.PI));
    return helpers.radToDeg(x);
}

// ---------------------------------------------------------------------------
// Real mappables
// ---------------------------------------------------------------------------

fn sinR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = phloat.sin(toRad(x));
    return .none;
}
fn cosR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = phloat.cos(toRad(x));
    return .none;
}
fn tanR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = phloat.tan(toRad(x));
    return .none;
}
fn asinR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    if (phloat.lt(x, phloat.fromInt(-1)) or phloat.gt(x, phloat.fromInt(1))) return .invalid_data;
    out.* = fromRad(phloat.asin(x));
    return .none;
}
fn acosR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    if (phloat.lt(x, phloat.fromInt(-1)) or phloat.gt(x, phloat.fromInt(1))) return .invalid_data;
    out.* = fromRad(phloat.acos(x));
    return .none;
}
fn atanR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = fromRad(phloat.atan(x));
    return .none;
}
fn sinhR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = phloat.sinh(x);
    return .none;
}
fn coshR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = phloat.cosh(x);
    return .none;
}
fn tanhR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = phloat.tanh(x);
    return .none;
}
fn asinhR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = phloat.asinh(x);
    return .none;
}
fn acoshR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    if (phloat.lt(x, phloat.fromInt(1))) return .invalid_data;
    out.* = phloat.acosh(x);
    return .none;
}
fn atanhR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    if (phloat.le(x, phloat.fromInt(-1)) or phloat.ge(x, phloat.fromInt(1))) return .invalid_data;
    out.* = phloat.atanh(x);
    return .none;
}
fn lnR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    if (phloat.le(x, phloat.fromInt(0))) return .invalid_data;
    out.* = phloat.log(x);
    return .none;
}
fn logR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    if (phloat.le(x, phloat.fromInt(0))) return .invalid_data;
    out.* = phloat.log10(x);
    return .none;
}
fn expR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = phloat.exp(x);
    return .none;
}
fn sqrtR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    if (phloat.lt(x, phloat.fromInt(0))) return .invalid_data;
    out.* = phloat.sqrt(x);
    return .none;
}
fn sqR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = phloat.mul(x, x);
    return .none;
}
fn absR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = phloat.abs(x);
    return .none;
}
fn invR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    if (phloat.isZero(x)) return .divide_by_0;
    out.* = phloat.div(phloat.fromInt(1), x);
    return .none;
}
fn signR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = if (phloat.lt(x, phloat.fromInt(0))) phloat.fromInt(-1) else phloat.fromInt(1);
    return .none;
}
fn ipR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = if (phloat.lt(x, phloat.fromInt(0))) phloat.neg(phloat.floor(phloat.neg(x))) else phloat.floor(x);
    return .none;
}
fn fpR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = if (phloat.lt(x, phloat.fromInt(0))) phloat.add(x, phloat.floor(phloat.neg(x))) else phloat.sub(x, phloat.floor(x));
    return .none;
}
fn factR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    if (phloat.lt(x, phloat.fromInt(0)) or !phloat.isInteger(x)) return .invalid_data;
    var f = phloat.fromInt(1);
    var xr = x;
    while (phloat.gt(xr, phloat.fromInt(1))) {
        f = phloat.mul(f, xr);
        xr = phloat.sub(xr, phloat.fromInt(1));
        if (phloat.isInf(f)) return .out_of_range;
    }
    out.* = f;
    return .none;
}
fn degR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = helpers.radToDeg(x);
    return .none;
}
fn radR(x: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = helpers.degToRad(x);
    return .none;
}
fn notReal(x: phloat.Phloat, out: *phloat.Phloat) Err {
    _ = x;
    _ = out;
    return .internal_error;
}

// ---------------------------------------------------------------------------
// Complex mappables
// ---------------------------------------------------------------------------

fn sinC(xre: phloat.Phloat, xim: phloat.Phloat, ore: *phloat.Phloat, oim: *phloat.Phloat) Err {
    ore.* = phloat.mul(phloat.sin(xre), phloat.cosh(xim));
    oim.* = phloat.mul(phloat.cos(xre), phloat.sinh(xim));
    return .none;
}
fn cosC(xre: phloat.Phloat, xim: phloat.Phloat, ore: *phloat.Phloat, oim: *phloat.Phloat) Err {
    ore.* = phloat.mul(phloat.cos(xre), phloat.cosh(xim));
    oim.* = phloat.neg(phloat.mul(phloat.sin(xre), phloat.sinh(xim)));
    return .none;
}
fn tanC(xre: phloat.Phloat, xim: phloat.Phloat, ore: *phloat.Phloat, oim: *phloat.Phloat) Err {
    var sre: phloat.Phloat = undefined;
    var sim: phloat.Phloat = undefined;
    var cre: phloat.Phloat = undefined;
    var cim: phloat.Phloat = undefined;
    _ = sinC(xre, xim, &sre, &sim);
    _ = cosC(xre, xim, &cre, &cim);
    return complexDiv(sre, sim, cre, cim, ore, oim);
}
fn sinhC(xre: phloat.Phloat, xim: phloat.Phloat, ore: *phloat.Phloat, oim: *phloat.Phloat) Err {
    ore.* = phloat.mul(phloat.sinh(xre), phloat.cos(xim));
    oim.* = phloat.mul(phloat.cosh(xre), phloat.sin(xim));
    return .none;
}
fn coshC(xre: phloat.Phloat, xim: phloat.Phloat, ore: *phloat.Phloat, oim: *phloat.Phloat) Err {
    ore.* = phloat.mul(phloat.cosh(xre), phloat.cos(xim));
    oim.* = phloat.mul(phloat.sinh(xre), phloat.sin(xim));
    return .none;
}
fn tanhC(xre: phloat.Phloat, xim: phloat.Phloat, ore: *phloat.Phloat, oim: *phloat.Phloat) Err {
    var sre: phloat.Phloat = undefined;
    var sim: phloat.Phloat = undefined;
    var cre: phloat.Phloat = undefined;
    var cim: phloat.Phloat = undefined;
    _ = sinhC(xre, xim, &sre, &sim);
    _ = coshC(xre, xim, &cre, &cim);
    return complexDiv(sre, sim, cre, cim, ore, oim);
}
fn lnC(xre: phloat.Phloat, xim: phloat.Phloat, ore: *phloat.Phloat, oim: *phloat.Phloat) Err {
    const mag = phloat.hypot(xre, xim);
    if (phloat.isZero(mag)) return .invalid_data;
    ore.* = phloat.log(mag);
    oim.* = phloat.atan2(xim, xre);
    return .none;
}
fn logC(xre: phloat.Phloat, xim: phloat.Phloat, ore: *phloat.Phloat, oim: *phloat.Phloat) Err {
    var lre: phloat.Phloat = undefined;
    var lim: phloat.Phloat = undefined;
    const e = lnC(xre, xim, &lre, &lim);
    if (e != .none) return e;
    ore.* = phloat.div(lre, phloat.LN10);
    oim.* = phloat.div(lim, phloat.LN10);
    return .none;
}
fn expC(xre: phloat.Phloat, xim: phloat.Phloat, ore: *phloat.Phloat, oim: *phloat.Phloat) Err {
    const m = phloat.exp(xre);
    ore.* = phloat.mul(m, phloat.cos(xim));
    oim.* = phloat.mul(m, phloat.sin(xim));
    return .none;
}
fn sqrtC(xre: phloat.Phloat, xim: phloat.Phloat, ore: *phloat.Phloat, oim: *phloat.Phloat) Err {
    const r = phloat.hypot(xre, xim);
    ore.* = phloat.sqrt(phloat.div(phloat.add(r, xre), phloat.fromInt(2)));
    const im_part = phloat.sqrt(phloat.div(phloat.sub(r, xre), phloat.fromInt(2)));
    oim.* = if (phloat.lt(xim, phloat.fromInt(0))) phloat.neg(im_part) else im_part;
    return .none;
}
fn sqC(xre: phloat.Phloat, xim: phloat.Phloat, ore: *phloat.Phloat, oim: *phloat.Phloat) Err {
    ore.* = phloat.sub(phloat.mul(xre, xre), phloat.mul(xim, xim));
    oim.* = phloat.mul(phloat.mul(phloat.fromInt(2), xre), xim);
    return .none;
}
fn absC(xre: phloat.Phloat, xim: phloat.Phloat, ore: *phloat.Phloat, oim: *phloat.Phloat) Err {
    ore.* = phloat.hypot(xre, xim);
    oim.* = phloat.fromInt(0);
    return .none;
}
fn invC(xre: phloat.Phloat, xim: phloat.Phloat, ore: *phloat.Phloat, oim: *phloat.Phloat) Err {
    const denom = phloat.add(phloat.mul(xre, xre), phloat.mul(xim, xim));
    if (phloat.isZero(denom)) return .divide_by_0;
    ore.* = phloat.div(xre, denom);
    oim.* = phloat.neg(phloat.div(xim, denom));
    return .none;
}
fn notComplex(xre: phloat.Phloat, xim: phloat.Phloat, ore: *phloat.Phloat, oim: *phloat.Phloat) Err {
    _ = xre;
    _ = xim;
    _ = ore;
    _ = oim;
    return .invalid_type;
}

/// Complex division (a+bi)/(c+di).
fn complexDiv(are: phloat.Phloat, aim: phloat.Phloat, bre: phloat.Phloat, bim: phloat.Phloat, ore: *phloat.Phloat, oim: *phloat.Phloat) Err {
    const denom = phloat.add(phloat.mul(bre, bre), phloat.mul(bim, bim));
    if (phloat.isZero(denom)) return .divide_by_0;
    ore.* = phloat.div(phloat.add(phloat.mul(are, bre), phloat.mul(aim, bim)), denom);
    oim.* = phloat.div(phloat.sub(phloat.mul(aim, bre), phloat.mul(are, bim)), denom);
    return .none;
}

// ---------------------------------------------------------------------------
// Power mappables (natural order: x OP y)
// ---------------------------------------------------------------------------

fn powRR(x: phloat.Phloat, y: phloat.Phloat, z: *phloat.Phloat) Err {
    const r = phloat.pow(x, y);
    if (phloat.isNaN(r)) return .invalid_data;
    z.* = r;
    return .none;
}
fn powRC(x: phloat.Phloat, yre: phloat.Phloat, yim: phloat.Phloat, zre: *phloat.Phloat, zim: *phloat.Phloat) Err {
    return powComplex(x, phloat.fromInt(0), yre, yim, zre, zim);
}
fn powCR(xre: phloat.Phloat, xim: phloat.Phloat, y: phloat.Phloat, zre: *phloat.Phloat, zim: *phloat.Phloat) Err {
    return powComplex(xre, xim, y, phloat.fromInt(0), zre, zim);
}
fn powCC(xre: phloat.Phloat, xim: phloat.Phloat, yre: phloat.Phloat, yim: phloat.Phloat, zre: *phloat.Phloat, zim: *phloat.Phloat) Err {
    return powComplex(xre, xim, yre, yim, zre, zim);
}

/// (xre+xim·i)^(yre+yim·i) = exp((yre+yim·i)·ln(xre+xim·i)).
fn powComplex(xre: phloat.Phloat, xim: phloat.Phloat, yre: phloat.Phloat, yim: phloat.Phloat, zre: *phloat.Phloat, zim: *phloat.Phloat) Err {
    var lre: phloat.Phloat = undefined;
    var lim: phloat.Phloat = undefined;
    const e = lnC(xre, xim, &lre, &lim);
    if (e != .none) return e;
    const wre = phloat.sub(phloat.mul(yre, lre), phloat.mul(yim, lim));
    const wim = phloat.add(phloat.mul(yre, lim), phloat.mul(yim, lre));
    return expC(wre, wim, zre, zim);
}

// ---------------------------------------------------------------------------
// Mod mappables (real-only)
// ---------------------------------------------------------------------------

fn modRR(x: phloat.Phloat, y: phloat.Phloat, z: *phloat.Phloat) Err {
    // x mod y, with the HP-42S sign adjustment.
    if (phloat.isZero(y)) {
        z.* = x;
    } else if (phloat.isZero(x)) {
        z.* = phloat.fromInt(0);
    } else {
        var r = phloat.fmod(x, y);
        if (!phloat.isZero(r) and ((phloat.gt(y, phloat.fromInt(0)) and phloat.lt(x, phloat.fromInt(0))) or (phloat.lt(y, phloat.fromInt(0)) and phloat.gt(x, phloat.fromInt(0)))))
            r = phloat.add(r, y);
        z.* = r;
    }
    return .none;
}
fn modRC(x: phloat.Phloat, yre: phloat.Phloat, yim: phloat.Phloat, zre: *phloat.Phloat, zim: *phloat.Phloat) Err {
    _ = x;
    _ = yre;
    _ = yim;
    _ = zre;
    _ = zim;
    return .invalid_type;
}
fn modCR(xre: phloat.Phloat, xim: phloat.Phloat, y: phloat.Phloat, zre: *phloat.Phloat, zim: *phloat.Phloat) Err {
    _ = xre;
    _ = xim;
    _ = y;
    _ = zre;
    _ = zim;
    return .invalid_type;
}
fn modCC(xre: phloat.Phloat, xim: phloat.Phloat, yre: phloat.Phloat, yim: phloat.Phloat, zre: *phloat.Phloat, zim: *phloat.Phloat) Err {
    _ = xre;
    _ = xim;
    _ = yre;
    _ = yim;
    _ = zre;
    _ = zim;
    return .invalid_type;
}

// ---------------------------------------------------------------------------
// abs / transpose / dot / cross
// ---------------------------------------------------------------------------

fn absUnary(src: *const Vartype, out: *?*Vartype) Err {
    switch (src.*) {
        .real => |x| {
            out.* = vartype.newReal(phloat.abs(x)) orelse return .insufficient_memory;
            return .none;
        },
        .complex => |c| {
            out.* = vartype.newReal(phloat.hypot(c.re, c.im)) orelse return .insufficient_memory;
            return .none;
        },
        .array => return helpers.mapUnary(src, out, absR, absC),
        else => return .invalid_type,
    }
}

fn transpose(src: *const Vartype, out: *?*Vartype) Err {
    const info = vartype.matrixInfo(src) orelse return .invalid_type;
    const rows = info.rows;
    const columns = info.columns;
    const sa = src.array;
    const dst = vartype.newArray(columns) orelse return .insufficient_memory;
    errdefer vartype.free(dst);
    var j: i32 = 0;
    while (j < columns) : (j += 1) {
        const row = vartype.newArray(rows) orelse return .insufficient_memory;
        dst.array.data[@intCast(j)] = row;
        var i: i32 = 0;
        while (i < rows) : (i += 1) {
            const elem = sa.data[@intCast(i)].?.array.data[@intCast(j)].?;
            row.array.data[@intCast(i)] = vartype.dup(elem) orelse return .insufficient_memory;
        }
    }
    out.* = dst;
    return .none;
}

fn containsComplex(v: *const Vartype) bool {
    return switch (v.*) {
        .complex => true,
        .array => |a| {
            for (a.data) |item| {
                if (item) |p| {
                    if (containsComplex(p)) return true;
                }
            }
            return false;
        },
        else => false,
    };
}

fn dotAccum(a: *const Vartype, b: *const Vartype, re: *phloat.Phloat, im: *phloat.Phloat) Err {
    switch (a.*) {
        .real => |av| switch (b.*) {
            .real => |bv| re.* = phloat.add(re.*, phloat.mul(av, bv)),
            .complex => |c| {
                re.* = phloat.add(re.*, phloat.mul(av, c.re));
                im.* = phloat.add(im.*, phloat.mul(av, c.im));
            },
            else => return .invalid_type,
        },
        .complex => |c| switch (b.*) {
            .real => |bv| {
                re.* = phloat.add(re.*, phloat.mul(c.re, bv));
                im.* = phloat.add(im.*, phloat.mul(c.im, bv));
            },
            .complex => |c2| {
                re.* = phloat.add(re.*, phloat.sub(phloat.mul(c.re, c2.re), phloat.mul(c.im, c2.im)));
                im.* = phloat.add(im.*, phloat.add(phloat.mul(c.re, c2.im), phloat.mul(c2.re, c.im)));
            },
            else => return .invalid_type,
        },
        .array => |aa| switch (b.*) {
            .array => |ba| {
                if (aa.data.len != ba.data.len) return .dimension_error;
                for (aa.data, 0..) |item, i| {
                    const p1 = item orelse return .invalid_type;
                    const p2 = ba.data[i] orelse return .invalid_type;
                    const e = dotAccum(p1, p2, re, im);
                    if (e != .none) return e;
                }
            },
            else => return .invalid_type,
        },
        else => return .invalid_type,
    }
    return .none;
}

fn dotProduct(a: *const Vartype, b: *const Vartype, out: *?*Vartype) Err {
    if (a.* == .string or b.* == .string) return .alpha_data_is_invalid;
    if (a.* == .complex and b.* == .complex) {
        const ac = a.complex;
        const bc = b.complex;
        const d = phloat.add(phloat.mul(ac.re, bc.re), phloat.mul(ac.im, bc.im));
        out.* = vartype.newReal(d) orelse return .insufficient_memory;
        return .none;
    }
    if (a.* != .array or b.* != .array) return .invalid_type;
    if (vartype.containsStrings(a) or vartype.containsStrings(b)) return .alpha_data_is_invalid;
    var re = phloat.fromInt(0);
    var im = phloat.fromInt(0);
    const e = dotAccum(a, b, &re, &im);
    if (e != .none) return e;
    const v = if (containsComplex(a) or containsComplex(b))
        vartype.newComplex(re, im)
    else
        vartype.newReal(re);
    out.* = v orelse return .insufficient_memory;
    return .none;
}

fn realVectorLen(v: *const Vartype) ?i32 {
    const a = switch (v.*) {
        .array => |a| a,
        else => return null,
    };
    for (a.data) |item| {
        const p = item orelse return null;
        if (p.* != .real) return null;
    }
    return @intCast(a.data.len);
}

fn realVectorElem(v: *const Vartype, i: i32) phloat.Phloat {
    return v.array.data[@intCast(i)].?.real;
}

fn crossProduct(a: *const Vartype, b: *const Vartype, out: *?*Vartype) Err {
    if (a.* == .string or b.* == .string) return .alpha_data_is_invalid;
    switch (a.*) {
        .complex => |ar| switch (b.*) {
            .complex => |al| {
                const d = phloat.sub(phloat.mul(al.re, ar.im), phloat.mul(al.im, ar.re));
                out.* = vartype.newReal(d) orelse return .insufficient_memory;
                return .none;
            },
            else => return .invalid_type,
        },
        .array => switch (b.*) {
            .array => {
                const ls = realVectorLen(a) orelse return .invalid_type;
                const rs = realVectorLen(b) orelse return .invalid_type;
                if (ls > 3 or rs > 3) return .dimension_error;
                var xl = phloat.fromInt(0);
                var yl = phloat.fromInt(0);
                var zl = phloat.fromInt(0);
                var xr = phloat.fromInt(0);
                var yr = phloat.fromInt(0);
                var zr = phloat.fromInt(0);
                if (ls >= 1) xl = realVectorElem(a, 0);
                if (ls >= 2) yl = realVectorElem(a, 1);
                if (ls >= 3) zl = realVectorElem(a, 2);
                if (rs >= 1) xr = realVectorElem(b, 0);
                if (rs >= 2) yr = realVectorElem(b, 1);
                if (rs >= 3) zr = realVectorElem(b, 2);
                const res = vartype.newArray(3) orelse return .insufficient_memory;
                errdefer vartype.free(res);
                res.array.data[0] = vartype.newReal(phloat.sub(phloat.mul(yl, zr), phloat.mul(zl, yr))) orelse return .insufficient_memory;
                res.array.data[1] = vartype.newReal(phloat.sub(phloat.mul(zl, xr), phloat.mul(xl, zr))) orelse return .insufficient_memory;
                res.array.data[2] = vartype.newReal(phloat.sub(phloat.mul(xl, yr), phloat.mul(yl, xr))) orelse return .insufficient_memory;
                out.* = res;
                return .none;
            },
            else => return .invalid_type,
        },
        else => return .invalid_type,
    }
}

// ---------------------------------------------------------------------------
// Negation (in place)
// ---------------------------------------------------------------------------

fn negateInPlace(v: *Vartype) void {
    switch (v.*) {
        .real => |*r| r.* = phloat.neg(r.*),
        .complex => |*c| {
            c.re = phloat.neg(c.re);
            c.im = phloat.neg(c.im);
        },
        .array => |*a| {
            for (a.data) |item| {
                if (item) |p| negateInPlace(p);
            }
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Parse and evaluate an algebraic expression, pushing the result onto the
/// stack. Returns `.syntax_error` on a malformed expression, `.nonexistent`
/// on an unknown variable, and the usual arithmetic errors otherwise.
pub fn evalEquation(expr: []const u8) Err {
    var p = Parser{ .src = expr };
    var result: ?*Vartype = null;
    p.skipWs();
    if (p.pos >= p.src.len) return .syntax_error;
    const e = parseExpr(&p, &result);
    if (e != .none) {
        vartype.freeOpt(result);
        return e;
    }
    p.skipWs();
    if (p.pos != p.src.len) {
        vartype.freeOpt(result);
        return .syntax_error;
    }
    return helpers.recallResult(result.?);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn top() *Vartype {
    return globals.stack[helpers.xIndex()].?;
}

fn expectPhloat(expected: f64, p: phloat.Phloat) !void {
    try std.testing.expectApproxEqAbs(expected, phloat.toDouble(p), 1e-20);
}

fn expectReal(expected: f64) !void {
    try std.testing.expectEqual(vartype.Type.real, std.meta.activeTag(top().*));
    try expectPhloat(expected, top().real);
}

fn matElem(m: *const Vartype, i: i32, j: i32) phloat.Phloat {
    return m.array.data[@intCast(i)].?.array.data[@intCast(j)].?.real;
}

test "arithmetic and precedence" {
    globals.init();
    defer globals.deinit();
    defer variables.deinit();

    try std.testing.expectEqual(Err.none, evalEquation("1+2"));
    try expectReal(3);

    try std.testing.expectEqual(Err.none, evalEquation("(1+2)*3"));
    try expectReal(9);

    try std.testing.expectEqual(Err.none, evalEquation("2^10"));
    try expectReal(1024);

    try std.testing.expectEqual(Err.none, evalEquation("-2^2"));
    try expectReal(-4);

    try std.testing.expectEqual(Err.none, evalEquation("2^-2"));
    try expectReal(0.25);

    try std.testing.expectEqual(Err.none, evalEquation("2^3^2"));
    try expectReal(512);

    try std.testing.expectEqual(Err.none, evalEquation("1/3"));
    try expectPhloat(1.0 / 3.0, top().real);

    try std.testing.expectEqual(Err.none, evalEquation("0.1+0.2"));
    try expectPhloat(0.3, top().real);
}

test "functions and constants" {
    globals.init();
    defer globals.deinit();
    defer variables.deinit();

    try std.testing.expectEqual(Err.none, evalEquation("sqrt(16)"));
    try expectReal(4);

    try std.testing.expectEqual(Err.none, evalEquation("sin(0)"));
    try expectReal(0);

    try std.testing.expectEqual(Err.none, evalEquation("abs(-3)"));
    try expectReal(3);

    try std.testing.expectEqual(Err.none, evalEquation("5!"));
    try expectReal(120);

    try std.testing.expectEqual(Err.none, evalEquation("inv(4)"));
    try expectReal(0.25);

    try std.testing.expectEqual(Err.none, evalEquation("pi"));
    try expectPhloat(3.141592653589793, top().real);

    try std.testing.expectEqual(Err.none, evalEquation("ln(e)"));
    try expectReal(1);

    try std.testing.expectEqual(Err.none, evalEquation("pow(2, 8)"));
    try expectReal(256);

    try std.testing.expectEqual(Err.none, evalEquation("mod(7, 3)"));
    try expectReal(1);
}

test "array and matrix literals" {
    globals.init();
    defer globals.deinit();
    defer variables.deinit();

    try std.testing.expectEqual(Err.none, evalEquation("[1,2,3]"));
    try std.testing.expectEqual(vartype.Type.array, std.meta.activeTag(top().*));
    try std.testing.expectEqual(@as(usize, 3), top().array.data.len);
    try expectPhloat(2, top().array.data[1].?.real);

    try std.testing.expectEqual(Err.none, evalEquation("det([[1,2],[3,4]])"));
    try expectReal(-2);

    try std.testing.expectEqual(Err.none, evalEquation("inv([[2,0],[0,4]])"));
    try expectPhloat(0.5, matElem(top(), 0, 0));
    try expectPhloat(0.25, matElem(top(), 1, 1));

    try std.testing.expectEqual(Err.none, evalEquation("trans([[1,2],[3,4]])"));
    try expectPhloat(1, matElem(top(), 0, 0));
    try expectPhloat(3, matElem(top(), 0, 1));
    try expectPhloat(2, matElem(top(), 1, 0));
    try expectPhloat(4, matElem(top(), 1, 1));

    try std.testing.expectEqual(Err.none, evalEquation("dot([1,2,3],[4,5,6])"));
    try expectReal(32);

    try std.testing.expectEqual(Err.none, evalEquation("cross([1,0,0],[0,1,0])"));
    try expectPhloat(0, top().array.data[0].?.real);
    try expectPhloat(0, top().array.data[1].?.real);
    try expectPhloat(1, top().array.data[2].?.real);
}

test "variables and errors" {
    globals.init();
    defer globals.deinit();
    defer variables.deinit();

    // STO "M1" = 42, then eval "M1 * 2".
    const v = vartype.newReal(phloat.fromInt(42)) orelse return error.OOM;
    try std.testing.expectEqual(Err.none, variables.storeVar("M1", v));
    try std.testing.expectEqual(Err.none, evalEquation("M1*2"));
    try expectReal(84);

    // Unknown variable → Nonexistent.
    try std.testing.expectEqual(Err.nonexistent, evalEquation("NOPE+1"));

    // Malformed → Syntax Error.
    try std.testing.expectEqual(Err.syntax_error, evalEquation("1+"));
    try std.testing.expectEqual(Err.syntax_error, evalEquation("(1+2"));
    try std.testing.expectEqual(Err.syntax_error, evalEquation(""));
}

test "error paths free operands exactly once" {
    globals.init();
    defer globals.deinit();
    defer variables.deinit();

    // Binary-op error (applyBinaryOp frees both operands, then errors).
    try std.testing.expectEqual(Err.divide_by_0, evalEquation("1/0"));
    try std.testing.expectEqual(Err.divide_by_0, evalEquation("1/(2-2)"));

    // Unary-op error (applyUnary frees the operand, then errors).
    try std.testing.expectEqual(Err.invalid_data, evalEquation("sqrt(-1)"));
    try std.testing.expectEqual(Err.invalid_data, evalEquation("(-3)!"));
    try std.testing.expectEqual(Err.divide_by_0, evalEquation("inv(0)"));

    // The stack must still be usable after the errors.
    try std.testing.expectEqual(Err.none, evalEquation("1+2"));
    try expectReal(3);
}
