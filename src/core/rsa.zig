//! RSA for Zed's native-app sign-in (`crates/rpc/src/auth.rs`): a fresh key pair per
//! sign-in, the public key sent as base64url(PKCS#1 DER), and the access token returned
//! encrypted with RSA-OAEP-SHA256 (falling back to PKCS#1 v1.5, as Zed does).
//!
//! Built on `std.crypto.ff`. Decryption uses the constant-time `powWithEncodedExponent`.
//! Prime search uses Miller-Rabin with the variable-time public exponentiation; the key
//! is short-lived and generated locally, so that is an accepted trade-off.
const std = @import("std");
const ff = std.crypto.ff;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const public_exponent: u32 = 65537;

pub fn KeyPair(comptime bits: comptime_int) type {
    comptime std.debug.assert(bits % 16 == 0);
    return struct {
        const Self = @This();
        pub const modulus_bytes = bits / 8;
        const half_bytes = modulus_bytes / 2;
        const Wide = ff.Uint(bits + 64);
        const Half = ff.Modulus(bits / 2);
        const Full = ff.Modulus(bits);

        /// Big-endian modulus n and private exponent d.
        n: [modulus_bytes]u8,
        d: [modulus_bytes]u8,

        pub fn generate(io: std.Io) !Self {
            while (true) {
                const p = try prime(io);
                const q = try prime(io);
                if (std.mem.eql(u8, &p, &q)) continue;
                return fromPrimes(&p, &q) catch |err| switch (err) {
                    error.NotInvertible => continue,
                    else => err,
                };
            }
        }

        fn wide(bytes: []const u8) !Wide {
            var buf: [Wide.encoded_bytes]u8 = @splat(0);
            @memcpy(buf[buf.len - bytes.len ..], bytes);
            return Wide.fromBytes(&buf, .big);
        }
        fn fromPrimes(p_bytes: []const u8, q_bytes: []const u8) !Self {
            const one = try Wide.fromPrimitive(u8, 1);
            var p = try wide(p_bytes);
            var q = try wide(q_bytes);
            var n: Wide = .zero;
            if (n.mulAddWithOverflow(p, q) != 0) return error.Overflow;
            _ = p.subWithOverflow(one);
            _ = q.subWithOverflow(one);
            var phi: Wide = .zero;
            if (phi.mulAddWithOverflow(p, q) != 0) return error.Overflow;
            // d = (1 + k*phi) / e with k = -phi^-1 mod e; e is prime so phi mod e != 0
            // means phi is invertible.
            var reduced = phi;
            const r = try reduced.divRemPublic(public_exponent);
            if (r == 0) return error.NotInvertible;
            const r_inv = smallInverse(r, public_exponent);
            const k: u64 = (public_exponent - r_inv) % public_exponent;
            var d: Wide = one;
            if (d.mulAddWithOverflow(phi, try Wide.fromPrimitive(u64, k)) != 0) return error.Overflow;
            const rem = try d.divRemPublic(public_exponent);
            if (rem != 0) return error.KeyDerivation;
            var self: Self = undefined;
            var buf: [Wide.encoded_bytes]u8 = undefined;
            try n.toBytes(&buf, .big);
            if (buf[buf.len - modulus_bytes] & 0x80 == 0) return error.NotInvertible; // modulus too short; retry
            @memcpy(&self.n, buf[buf.len - modulus_bytes ..]);
            try d.toBytes(&buf, .big);
            @memcpy(&self.d, buf[buf.len - modulus_bytes ..]);
            return self;
        }

        fn smallInverse(a: u64, m: u64) u64 {
            var t: i128 = 0;
            var new_t: i128 = 1;
            var r: i128 = m;
            var new_r: i128 = a;
            while (new_r != 0) {
                const quotient = @divTrunc(r, new_r);
                const t_next = t - quotient * new_t;
                t = new_t;
                new_t = t_next;
                const r_next = r - quotient * new_r;
                r = new_r;
                new_r = r_next;
            }
            return @intCast(@mod(t, @as(i128, m)));
        }

        const small_primes = blk: {
            var list: [300]u16 = undefined;
            var count: usize = 0;
            var candidate: u16 = 3;
            @setEvalBranchQuota(100_000);
            while (count < list.len) : (candidate += 2) {
                var is_prime = true;
                var f: u16 = 3;
                while (f * f <= candidate) : (f += 2) if (candidate % f == 0) {
                    is_prime = false;
                    break;
                };
                if (is_prime) {
                    list[count] = candidate;
                    count += 1;
                }
            }
            break :blk list;
        };

        fn prime(io: std.Io) ![half_bytes]u8 {
            var bytes: [half_bytes]u8 = undefined;
            while (true) {
                try io.randomSecure(&bytes);
                bytes[0] |= 0xc0; // top two bits: p*q has exactly `bits` bits
                bytes[half_bytes - 1] |= 1;
                if (try probablePrime(io, &bytes)) return bytes;
            }
        }

        fn probablePrime(io: std.Io, bytes: []const u8) !bool {
            const U = ff.Uint(bits / 2);
            const candidate = try U.fromBytes(bytes, .big);
            for (small_primes) |sp| {
                var copy = candidate;
                if (try copy.divRemPublic(sp) == 0) return false;
            }
            const m = try Half.fromBytes(bytes, .big);
            const one = m.one();
            var minus_one_int = candidate;
            _ = minus_one_int.subWithOverflow(try U.fromPrimitive(u8, 1));
            const minus_one = try Half.Fe.fromBytes(m, blk: {
                var b: [half_bytes]u8 = undefined;
                try minus_one_int.toBytes(&b, .big);
                break :blk &b;
            }, .big);
            var d_int = minus_one_int;
            const s = d_int.trailingZeroBitsPublic();
            d_int.shiftRightPublic(s);
            var d: [half_bytes]u8 = undefined;
            try d_int.toBytes(&d, .big);
            var round: usize = 0;
            witness: while (round < 12) : (round += 1) {
                var a_bytes: [half_bytes]u8 = undefined;
                try io.randomSecure(&a_bytes);
                a_bytes[0] &= 0x3f; // below the candidate
                a_bytes[half_bytes - 1] |= 2;
                const a = try Half.Fe.fromBytes(m, &a_bytes, .big);
                var x = try m.powWithEncodedPublicExponent(a, &d, .big);
                if (x.eql(one) or x.eql(minus_one)) continue;
                var i: usize = 1;
                while (i < s) : (i += 1) {
                    x = m.sq(x);
                    if (x.eql(minus_one)) continue :witness;
                    if (x.eql(one)) return false;
                }
                return false;
            }
            return true;
        }

        /// PKCS#1 `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }`.
        pub fn publicKeyDer(self: *const Self, out: []u8) ![]const u8 {
            var body: [modulus_bytes + 32]u8 = undefined;
            var bw: std.Io.Writer = .fixed(&body);
            try derInteger(&bw, &self.n);
            var e_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &e_bytes, public_exponent, .big);
            try derInteger(&bw, &e_bytes);
            var w: std.Io.Writer = .fixed(out);
            try w.writeByte(0x30);
            try derLength(&w, bw.buffered().len);
            try w.writeAll(bw.buffered());
            return w.buffered();
        }

        /// RSADP followed by OAEP-SHA256 decoding (empty label), or PKCS#1 v1.5 on
        /// failure, like Zed's `PrivateKey::decrypt_string`.
        pub fn decrypt(self: *const Self, ciphertext: []const u8, out: []u8) ![]const u8 {
            if (ciphertext.len != modulus_bytes) return error.InvalidCiphertext;
            const m = try Full.fromBytes(&self.n, .big);
            const c = try Full.Fe.fromBytes(m, ciphertext, .big);
            const plain = try m.powWithEncodedExponent(c, &self.d, .big);
            var em: [modulus_bytes]u8 = undefined;
            try plain.toBytes(&em, .big);
            return oaepDecode(&em, out) catch pkcs1v15Decode(&em, out);
        }

        /// RSAEP with OAEP-SHA256 (for tests and round trips).
        pub fn encrypt(self: *const Self, io: std.Io, message: []const u8, out: *[modulus_bytes]u8) !void {
            const h = Sha256.digest_length;
            if (message.len > modulus_bytes - 2 * h - 2) return error.MessageTooLong;
            var em: [modulus_bytes]u8 = @splat(0);
            const seed = em[1..][0..h];
            const db = em[1 + h ..];
            Sha256.hash("", db[0..h], .{});
            db[db.len - message.len - 1] = 1;
            @memcpy(db[db.len - message.len ..], message);
            try io.randomSecure(seed);
            mgf1Xor(db, seed);
            mgf1Xor(seed, db);
            const m = try Full.fromBytes(&self.n, .big);
            const x = try Full.Fe.fromBytes(m, &em, .big);
            var e_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &e_bytes, public_exponent, .big);
            const y = try m.powWithEncodedPublicExponent(x, &e_bytes, .big);
            try y.toBytes(out, .big);
        }
    };
}

fn derLength(w: *std.Io.Writer, len: usize) !void {
    if (len < 0x80) return w.writeByte(@intCast(len));
    var tmp: [8]u8 = undefined;
    std.mem.writeInt(u64, &tmp, len, .big);
    var start: usize = 0;
    while (tmp[start] == 0) start += 1;
    try w.writeByte(0x80 | @as(u8, @intCast(8 - start)));
    try w.writeAll(tmp[start..]);
}
fn derInteger(w: *std.Io.Writer, big_endian: []const u8) !void {
    var start: usize = 0;
    while (start + 1 < big_endian.len and big_endian[start] == 0) start += 1;
    const value = big_endian[start..];
    const pad = value[0] & 0x80 != 0;
    try w.writeByte(0x02);
    try derLength(w, value.len + @intFromBool(pad));
    if (pad) try w.writeByte(0);
    try w.writeAll(value);
}

/// XORs MGF1-SHA256(seed) into `target`.
fn mgf1Xor(target: []u8, seed: []const u8) void {
    var counter: u32 = 0;
    var done: usize = 0;
    while (done < target.len) : (counter += 1) {
        var h = Sha256.init(.{});
        h.update(seed);
        var c: [4]u8 = undefined;
        std.mem.writeInt(u32, &c, counter, .big);
        h.update(&c);
        var block: [Sha256.digest_length]u8 = undefined;
        h.final(&block);
        const n = @min(block.len, target.len - done);
        for (target[done..][0..n], block[0..n]) |*t, b| t.* ^= b;
        done += n;
    }
}

fn oaepDecode(em: []u8, out: []u8) ![]const u8 {
    const h = Sha256.digest_length;
    if (em.len < 2 * h + 2 or em[0] != 0) return error.DecryptionFailed;
    const seed = em[1..][0..h];
    const db = em[1 + h ..];
    mgf1Xor(seed, db);
    mgf1Xor(db, seed);
    var label_hash: [h]u8 = undefined;
    Sha256.hash("", &label_hash, .{});
    if (!std.crypto.timing_safe.eql([h]u8, label_hash, db[0..h].*)) return error.DecryptionFailed;
    var i: usize = h;
    while (i < db.len and db[i] == 0) i += 1;
    if (i == db.len or db[i] != 1) return error.DecryptionFailed;
    const message = db[i + 1 ..];
    if (message.len > out.len) return error.NoSpaceLeft;
    @memcpy(out[0..message.len], message);
    return out[0..message.len];
}
fn pkcs1v15Decode(em: []const u8, out: []u8) ![]const u8 {
    if (em.len < 11 or em[0] != 0 or em[1] != 2) return error.DecryptionFailed;
    const sep = std.mem.indexOfScalarPos(u8, em, 2, 0) orelse return error.DecryptionFailed;
    if (sep < 10) return error.DecryptionFailed;
    const message = em[sep + 1 ..];
    if (message.len > out.len) return error.NoSpaceLeft;
    @memcpy(out[0..message.len], message);
    return out[0..message.len];
}

test "OAEP round trip and PKCS#1 DER public key" {
    const io = std.testing.io;
    const Pair = KeyPair(1024);
    const pair = try Pair.generate(io);
    var ct: [Pair.modulus_bytes]u8 = undefined;
    try pair.encrypt(io, "zed-access-token", &ct);
    var out: [Pair.modulus_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("zed-access-token", try pair.decrypt(&ct, &out));
    var der: [Pair.modulus_bytes + 64]u8 = undefined;
    const encoded = try pair.publicKeyDer(&der);
    try std.testing.expectEqual(@as(u8, 0x30), encoded[0]);
    try std.testing.expectEqual(@as(u8, 0x02), encoded[3]);
    // Tail is INTEGER 65537.
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x03, 0x01, 0x00, 0x01 }, encoded[encoded.len - 5 ..]);
}
