// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2020 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const Sha512 = std.crypto.hash.sha2.Sha512;

/// Ed25519 (EdDSA) signatures.
pub const Ed25519 = struct {
    /// The underlying elliptic curve.
    pub const Curve = @import("edwards25519.zig").Edwards25519;
    /// Length (in bytes) of a seed required to create a key pair.
    pub const seed_length = 32;
    /// Length (in bytes) of a compressed key pair.
    pub const keypair_length = 64;
    /// Length (in bytes) of a compressed public key.
    pub const public_length = 32;
    /// Length (in bytes) of a signature.
    pub const signature_length = 64;
    /// Length (in bytes) of optional random bytes, for non-deterministic signatures.
    pub const noise_length = 32;

    /// Derive a key pair from a secret seed.
    ///
    /// As in RFC 8032, an Ed25519 public key is generated by hashing
    /// the secret key using the SHA-512 function, and interpreting the
    /// bit-swapped, clamped lower-half of the output as the secret scalar.
    ///
    /// For this reason, an EdDSA secret key is commonly called a seed,
    /// from which the actual secret is derived.
    pub fn createKeyPair(seed: [seed_length]u8) ![keypair_length]u8 {
        var az: [Sha512.digest_length]u8 = undefined;
        var h = Sha512.init(.{});
        h.update(&seed);
        h.final(&az);
        const p = try Curve.basePoint.clampedMul(az[0..32].*);
        var keypair: [keypair_length]u8 = undefined;
        mem.copy(u8, &keypair, &seed);
        mem.copy(u8, keypair[seed_length..], &p.toBytes());
        return keypair;
    }

    /// Return the public key for a given key pair.
    pub fn publicKey(key_pair: [keypair_length]u8) [public_length]u8 {
        var public_key: [public_length]u8 = undefined;
        mem.copy(u8, public_key[0..], key_pair[seed_length..]);
        return public_key;
    }

    /// Sign a message using a key pair, and optional random noise.
    /// Having noise creates non-standard, non-deterministic signatures,
    /// but has been proven to increase resilience against fault attacks.
    pub fn sign(msg: []const u8, key_pair: [keypair_length]u8, noise: ?[noise_length]u8) ![signature_length]u8 {
        const public_key = key_pair[32..];
        var az: [Sha512.digest_length]u8 = undefined;
        var h = Sha512.init(.{});
        h.update(key_pair[0..seed_length]);
        h.final(&az);

        h = Sha512.init(.{});
        if (noise) |*z| {
            h.update(z);
        }
        h.update(az[32..]);
        h.update(msg);
        var nonce64: [64]u8 = undefined;
        h.final(&nonce64);
        const nonce = Curve.scalar.reduce64(nonce64);
        const r = try Curve.basePoint.mul(nonce);

        var sig: [signature_length]u8 = undefined;
        mem.copy(u8, sig[0..32], &r.toBytes());
        mem.copy(u8, sig[32..], public_key);
        h = Sha512.init(.{});
        h.update(&sig);
        h.update(msg);
        var hram64: [Sha512.digest_length]u8 = undefined;
        h.final(&hram64);
        const hram = Curve.scalar.reduce64(hram64);

        var x = az[0..32];
        Curve.scalar.clamp(x);
        const s = Curve.scalar.mulAdd(hram, x.*, nonce);
        mem.copy(u8, sig[32..], s[0..]);
        return sig;
    }

    /// Verify an Ed25519 signature given a message and a public key.
    /// Returns error.InvalidSignature is the signature verification failed.
    pub fn verify(sig: [signature_length]u8, msg: []const u8, public_key: [public_length]u8) !void {
        const r = sig[0..32];
        const s = sig[32..64];
        try Curve.scalar.rejectNonCanonical(s.*);
        try Curve.rejectNonCanonical(public_key);
        const a = try Curve.fromBytes(public_key);
        try a.rejectIdentity();
        try Curve.rejectNonCanonical(r.*);
        const expected_r = try Curve.fromBytes(r.*);

        var h = Sha512.init(.{});
        h.update(r);
        h.update(&public_key);
        h.update(msg);
        var hram64: [Sha512.digest_length]u8 = undefined;
        h.final(&hram64);
        const hram = Curve.scalar.reduce64(hram64);

        const ah = try a.neg().mul(hram);
        const sb_ah = (try Curve.basePoint.mul(s.*)).add(ah);
        if (expected_r.sub(sb_ah).clearCofactor().rejectIdentity()) |_| {
            return error.InvalidSignature;
        } else |_| {}
    }

    /// A (signature, message, public_key) tuple for batch verification
    pub const BatchElement = struct {
        sig: [signature_length]u8,
        msg: []const u8,
        public_key: [public_length]u8,
    };

    /// Verify several signatures in a single operation, much faster than verifying signatures one-by-one
    pub fn verifyBatch(comptime count: usize, signature_batch: [count]BatchElement) !void {
        var r_batch: [count][32]u8 = undefined;
        var s_batch: [count][32]u8 = undefined;
        var a_batch: [count]Curve = undefined;
        var expected_r_batch: [count]Curve = undefined;

        for (signature_batch) |signature, i| {
            const r = signature.sig[0..32];
            const s = signature.sig[32..64];
            try Curve.scalar.rejectNonCanonical(s.*);
            try Curve.rejectNonCanonical(signature.public_key);
            const a = try Curve.fromBytes(signature.public_key);
            try a.rejectIdentity();
            try Curve.rejectNonCanonical(r.*);
            const expected_r = try Curve.fromBytes(r.*);
            expected_r_batch[i] = expected_r;
            r_batch[i] = r.*;
            s_batch[i] = s.*;
            a_batch[i] = a;
        }

        var hram_batch: [count]Curve.scalar.CompressedScalar = undefined;
        for (signature_batch) |signature, i| {
            var h = Sha512.init(.{});
            h.update(&r_batch[i]);
            h.update(&signature.public_key);
            h.update(signature.msg);
            var hram64: [Sha512.digest_length]u8 = undefined;
            h.final(&hram64);
            hram_batch[i] = Curve.scalar.reduce64(hram64);
        }

        var z_batch: [count]Curve.scalar.CompressedScalar = undefined;
        for (z_batch) |*z| {
            try std.crypto.randomBytes(z[0..16]);
            mem.set(u8, z[16..], 0);
        }

        var zs_sum = Curve.scalar.zero;
        for (z_batch) |z, i| {
            const zs = Curve.scalar.mul(z, s_batch[i]);
            zs_sum = Curve.scalar.add(zs_sum, zs);
        }
        zs_sum = Curve.scalar.mul8(zs_sum);

        var zr = Curve.neutralElement;
        for (z_batch) |z, i| {
            zr = zr.add(try expected_r_batch[i].mul(z));
        }
        zr = zr.clearCofactor();

        var zah = Curve.neutralElement;
        for (z_batch) |z, i| {
            const zh = Curve.scalar.mul(z, hram_batch[i]);
            zah = zah.add(try a_batch[i].mul(zh));
        }
        zah = zah.clearCofactor();

        const zsb = try Curve.basePoint.mul(zs_sum);
        if (zr.add(zah).sub(zsb).rejectIdentity()) |_| {
            return error.InvalidSignature;
        } else |_| {}
    }
};

test "ed25519 key pair creation" {
    var seed: [32]u8 = undefined;
    try fmt.hexToBytes(seed[0..], "8052030376d47112be7f73ed7a019293dd12ad910b654455798b4667d73de166");
    const key_pair = try Ed25519.createKeyPair(seed);
    var buf: [256]u8 = undefined;
    std.testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "{X}", .{key_pair}), "8052030376D47112BE7F73ED7A019293DD12AD910B654455798B4667D73DE1662D6F7455D97B4A3A10D7293909D1A4F2058CB9A370E43FA8154BB280DB839083");

    const public_key = Ed25519.publicKey(key_pair);
    std.testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "{X}", .{public_key}), "2D6F7455D97B4A3A10D7293909D1A4F2058CB9A370E43FA8154BB280DB839083");
}

test "ed25519 signature" {
    var seed: [32]u8 = undefined;
    try fmt.hexToBytes(seed[0..], "8052030376d47112be7f73ed7a019293dd12ad910b654455798b4667d73de166");
    const key_pair = try Ed25519.createKeyPair(seed);

    const sig = try Ed25519.sign("test", key_pair, null);
    var buf: [128]u8 = undefined;
    std.testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "{X}", .{sig}), "10A442B4A80CC4225B154F43BEF28D2472CA80221951262EB8E0DF9091575E2687CC486E77263C3418C757522D54F84B0359236ABBBD4ACD20DC297FDCA66808");
    const public_key = Ed25519.publicKey(key_pair);
    try Ed25519.verify(sig, "test", public_key);
    std.testing.expectError(error.InvalidSignature, Ed25519.verify(sig, "TEST", public_key));
}

test "ed25519 batch verification" {
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var seed: [32]u8 = undefined;
        try std.crypto.randomBytes(&seed);
        const key_pair = try Ed25519.createKeyPair(seed);
        var msg1: [32]u8 = undefined;
        var msg2: [32]u8 = undefined;
        try std.crypto.randomBytes(&msg1);
        try std.crypto.randomBytes(&msg2);
        const sig1 = try Ed25519.sign(&msg1, key_pair, null);
        const sig2 = try Ed25519.sign(&msg2, key_pair, null);
        const public_key = Ed25519.publicKey(key_pair);
        var signature_batch = [_]Ed25519.BatchElement{
            Ed25519.BatchElement{
                .sig = sig1,
                .msg = &msg1,
                .public_key = public_key,
            },
            Ed25519.BatchElement{
                .sig = sig2,
                .msg = &msg2,
                .public_key = public_key,
            },
        };
        try Ed25519.verifyBatch(2, signature_batch);

        signature_batch[1].sig = sig1;
        std.testing.expectError(error.InvalidSignature, Ed25519.verifyBatch(signature_batch.len, signature_batch));
    }
}

test "ed25519 test vectors" {
    const Vec = struct {
        msg_hex: *const [64:0]u8,
        public_key_hex: *const [64:0]u8,
        sig_hex: *const [128:0]u8,
        expected: ?anyerror,
    };

    const entries = [_]Vec{
        Vec{
            .msg_hex = "8c93255d71dcab10e8f379c26200f3c7bd5f09d9bc3068d3ef4edeb4853022b6",
            .public_key_hex = "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fa",
            .sig_hex = "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a0000000000000000000000000000000000000000000000000000000000000000",
            .expected = error.WeakPublicKey, // 0
        },
        Vec{
            .msg_hex = "9bd9f44f4dcc75bd531b56b2cd280b0bb38fc1cd6d1230e14861d861de092e79",
            .public_key_hex = "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fa",
            .sig_hex = "f7badec5b8abeaf699583992219b7b223f1df3fbbea919844e3f7c554a43dd43a5bb704786be79fc476f91d3f3f89b03984d8068dcf1bb7dfc6637b45450ac04",
            .expected = error.WeakPublicKey, // 1
        },
        Vec{
            .msg_hex = "aebf3f2601a0c8c5d39cc7d8911642f740b78168218da8471772b35f9d35b9ab",
            .public_key_hex = "f7badec5b8abeaf699583992219b7b223f1df3fbbea919844e3f7c554a43dd43",
            .sig_hex = "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fa8c4bd45aecaca5b24fb97bc10ac27ac8751a7dfe1baff8b953ec9f5833ca260e",
            .expected = null, // 2 - small order R is acceptable
        },
        Vec{
            .msg_hex = "9bd9f44f4dcc75bd531b56b2cd280b0bb38fc1cd6d1230e14861d861de092e79",
            .public_key_hex = "cdb267ce40c5cd45306fa5d2f29731459387dbf9eb933b7bd5aed9a765b88d4d",
            .sig_hex = "9046a64750444938de19f227bb80485e92b83fdb4b6506c160484c016cc1852f87909e14428a7a1d62e9f22f3d3ad7802db02eb2e688b6c52fcd6648a98bd009",
            .expected = null, // 3 - mixed orders
        },
        Vec{
            .msg_hex = "e47d62c63f830dc7a6851a0b1f33ae4bb2f507fb6cffec4011eaccd55b53f56c",
            .public_key_hex = "cdb267ce40c5cd45306fa5d2f29731459387dbf9eb933b7bd5aed9a765b88d4d",
            .sig_hex = "160a1cb0dc9c0258cd0a7d23e94d8fa878bcb1925f2c64246b2dee1796bed5125ec6bc982a269b723e0668e540911a9a6a58921d6925e434ab10aa7940551a09",
            .expected = null, // 4 - cofactored verification
        },
        Vec{
            .msg_hex = "e47d62c63f830dc7a6851a0b1f33ae4bb2f507fb6cffec4011eaccd55b53f56c",
            .public_key_hex = "cdb267ce40c5cd45306fa5d2f29731459387dbf9eb933b7bd5aed9a765b88d4d",
            .sig_hex = "21122a84e0b5fca4052f5b1235c80a537878b38f3142356b2c2384ebad4668b7e40bc836dac0f71076f9abe3a53f9c03c1ceeeddb658d0030494ace586687405",
            .expected = null, // 5 - cofactored verification
        },
        Vec{
            .msg_hex = "85e241a07d148b41e47d62c63f830dc7a6851a0b1f33ae4bb2f507fb6cffec40",
            .public_key_hex = "442aad9f089ad9e14647b1ef9099a1ff4798d78589e66f28eca69c11f582a623",
            .sig_hex = "e96f66be976d82e60150baecff9906684aebb1ef181f67a7189ac78ea23b6c0e547f7690a0e2ddcd04d87dbc3490dc19b3b3052f7ff0538cb68afb369ba3a514",
            .expected = error.NonCanonical, // 6 - S > L
        },
        Vec{
            .msg_hex = "85e241a07d148b41e47d62c63f830dc7a6851a0b1f33ae4bb2f507fb6cffec40",
            .public_key_hex = "442aad9f089ad9e14647b1ef9099a1ff4798d78589e66f28eca69c11f582a623",
            .sig_hex = "8ce5b96c8f26d0ab6c47958c9e68b937104cd36e13c33566acd2fe8d38aa19427e71f98a4734e74f2f13f06f97c20d58cc3f54b8bd0d272f42b695dd7e89a8c2",
            .expected = error.NonCanonical, // 7 - S >> L
        },
        Vec{
            .msg_hex = "9bedc267423725d473888631ebf45988bad3db83851ee85c85e241a07d148b41",
            .public_key_hex = "f7badec5b8abeaf699583992219b7b223f1df3fbbea919844e3f7c554a43dd43",
            .sig_hex = "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff03be9678ac102edcd92b0210bb34d7428d12ffc5df5f37e359941266a4e35f0f",
            .expected = error.InvalidSignature, // 8 - non-canonical R
        },
        Vec{
            .msg_hex = "9bedc267423725d473888631ebf45988bad3db83851ee85c85e241a07d148b41",
            .public_key_hex = "f7badec5b8abeaf699583992219b7b223f1df3fbbea919844e3f7c554a43dd43",
            .sig_hex = "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffca8c5b64cd208982aa38d4936621a4775aa233aa0505711d8fdcfdaa943d4908",
            .expected = null, // 9 - non-canonical R
        },
        Vec{
            .msg_hex = "e96b7021eb39c1a163b6da4e3093dcd3f21387da4cc4572be588fafae23c155b",
            .public_key_hex = "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            .sig_hex = "a9d55260f765261eb9b84e106f665e00b867287a761990d7135963ee0a7d59dca5bb704786be79fc476f91d3f3f89b03984d8068dcf1bb7dfc6637b45450ac04",
            .expected = error.IdentityElement, // 10 - small-order A
        },
        Vec{
            .msg_hex = "39a591f5321bbe07fd5a23dc2f39d025d74526615746727ceefd6e82ae65c06f",
            .public_key_hex = "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            .sig_hex = "a9d55260f765261eb9b84e106f665e00b867287a761990d7135963ee0a7d59dca5bb704786be79fc476f91d3f3f89b03984d8068dcf1bb7dfc6637b45450ac04",
            .expected = error.IdentityElement, // 11 - small-order A
        },
    };
    for (entries) |entry, i| {
        var msg: [entry.msg_hex.len / 2]u8 = undefined;
        try fmt.hexToBytes(&msg, entry.msg_hex);
        var public_key: [32]u8 = undefined;
        try fmt.hexToBytes(&public_key, entry.public_key_hex);
        var sig: [64]u8 = undefined;
        try fmt.hexToBytes(&sig, entry.sig_hex);
        if (entry.expected) |error_type| {
            std.testing.expectError(error_type, Ed25519.verify(sig, &msg, public_key));
        } else {
            try Ed25519.verify(sig, &msg, public_key);
        }
    }
}
