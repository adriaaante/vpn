"""Чистый Python AES-256-GCM (только шифрование) — для connect-page.sh.

Без внешних зависимостей: на сервере может не быть python3-cryptography, а
ставить её ради одного шифрования блоба не хочется. Расшифровка — в браузере
(SJCL, scripts/assets/sjcl.js); совместимость проверена тестом рядом
(aesgcm_test.py, гоняет roundtrip против SJCL через node, если node есть).

Использование:
    from aesgcm import encrypt_blob
    blob = encrypt_blob(pin, plaintext_bytes)   # dict для JSON в страницу
"""

import hashlib
import json
import os

# --- AES-256, только шифрование блока ---

_SBOX = [
    0x63, 0x7C, 0x77, 0x7B, 0xF2, 0x6B, 0x6F, 0xC5, 0x30, 0x01, 0x67, 0x2B, 0xFE, 0xD7, 0xAB, 0x76,
    0xCA, 0x82, 0xC9, 0x7D, 0xFA, 0x59, 0x47, 0xF0, 0xAD, 0xD4, 0xA2, 0xAF, 0x9C, 0xA4, 0x72, 0xC0,
    0xB7, 0xFD, 0x93, 0x26, 0x36, 0x3F, 0xF7, 0xCC, 0x34, 0xA5, 0xE5, 0xF1, 0x71, 0xD8, 0x31, 0x15,
    0x04, 0xC7, 0x23, 0xC3, 0x18, 0x96, 0x05, 0x9A, 0x07, 0x12, 0x80, 0xE2, 0xEB, 0x27, 0xB2, 0x75,
    0x09, 0x83, 0x2C, 0x1A, 0x1B, 0x6E, 0x5A, 0xA0, 0x52, 0x3B, 0xD6, 0xB3, 0x29, 0xE3, 0x2F, 0x84,
    0x53, 0xD1, 0x00, 0xED, 0x20, 0xFC, 0xB1, 0x5B, 0x6A, 0xCB, 0xBE, 0x39, 0x4A, 0x4C, 0x58, 0xCF,
    0xD0, 0xEF, 0xAA, 0xFB, 0x43, 0x4D, 0x33, 0x85, 0x45, 0xF9, 0x02, 0x7F, 0x50, 0x3C, 0x9F, 0xA8,
    0x51, 0xA3, 0x40, 0x8F, 0x92, 0x9D, 0x38, 0xF5, 0xBC, 0xB6, 0xDA, 0x21, 0x10, 0xFF, 0xF3, 0xD2,
    0xCD, 0x0C, 0x13, 0xEC, 0x5F, 0x97, 0x44, 0x17, 0xC4, 0xA7, 0x7E, 0x3D, 0x64, 0x5D, 0x19, 0x73,
    0x60, 0x81, 0x4F, 0xDC, 0x22, 0x2A, 0x90, 0x88, 0x46, 0xEE, 0xB8, 0x14, 0xDE, 0x5E, 0x0B, 0xDB,
    0xE0, 0x32, 0x3A, 0x0A, 0x49, 0x06, 0x24, 0x5C, 0xC2, 0xD3, 0xAC, 0x62, 0x91, 0x95, 0xE4, 0x79,
    0xE7, 0xC8, 0x37, 0x6D, 0x8D, 0xD5, 0x4E, 0xA9, 0x6C, 0x56, 0xF4, 0xEA, 0x65, 0x7A, 0xAE, 0x08,
    0xBA, 0x78, 0x25, 0x2E, 0x1C, 0xA6, 0xB4, 0xC6, 0xE8, 0xDD, 0x74, 0x1F, 0x4B, 0xBD, 0x8B, 0x8A,
    0x70, 0x3E, 0xB5, 0x66, 0x48, 0x03, 0xF6, 0x0E, 0x61, 0x35, 0x57, 0xB9, 0x86, 0xC1, 0x1D, 0x9E,
    0xE1, 0xF8, 0x98, 0x11, 0x69, 0xD9, 0x8E, 0x94, 0x9B, 0x1E, 0x87, 0xE9, 0xCE, 0x55, 0x28, 0xDF,
    0x8C, 0xA1, 0x89, 0x0D, 0xBF, 0xE6, 0x42, 0x68, 0x41, 0x99, 0x2D, 0x0F, 0xB0, 0x54, 0xBB, 0x16,
]

_RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36, 0x6C, 0xD8, 0xAB, 0x4D]


def _xtime(a):
    a <<= 1
    if a & 0x100:
        a ^= 0x11B
    return a & 0xFF


def _expand_key(key):
    # AES-256: 8 слов ключа -> 60 слов (15 раундовых ключей)
    w = [list(key[i:i + 4]) for i in range(0, 32, 4)]
    for i in range(8, 60):
        t = list(w[i - 1])
        if i % 8 == 0:
            t = t[1:] + t[:1]
            t = [_SBOX[b] for b in t]
            t[0] ^= _RCON[i // 8 - 1]
        elif i % 8 == 4:
            t = [_SBOX[b] for b in t]
        w.append([w[i - 8][j] ^ t[j] for j in range(4)])
    return [sum(w[4 * r:4 * r + 4], []) for r in range(15)]


def _encrypt_block(rk, block):
    s = list(block)

    def add_rk(st, k):
        return [st[i] ^ k[i] for i in range(16)]

    def sub_shift(st):
        # SubBytes + ShiftRows на состоянии в порядке байтов (столбцы подряд)
        t = [_SBOX[b] for b in st]
        return [
            t[0], t[5], t[10], t[15],
            t[4], t[9], t[14], t[3],
            t[8], t[13], t[2], t[7],
            t[12], t[1], t[6], t[11],
        ]

    def mix(st):
        out = []
        for c in range(4):
            a = st[4 * c:4 * c + 4]
            out += [
                _xtime(a[0]) ^ _xtime(a[1]) ^ a[1] ^ a[2] ^ a[3],
                a[0] ^ _xtime(a[1]) ^ _xtime(a[2]) ^ a[2] ^ a[3],
                a[0] ^ a[1] ^ _xtime(a[2]) ^ _xtime(a[3]) ^ a[3],
                _xtime(a[0]) ^ a[0] ^ a[1] ^ a[2] ^ _xtime(a[3]),
            ]
        return out

    s = add_rk(s, rk[0])
    for rnd in range(1, 14):
        s = mix(sub_shift(s))
        s = add_rk(s, rk[rnd])
    s = sub_shift(s)
    s = add_rk(s, rk[14])
    return bytes(s)


# --- GCM ---

def _ghash_mult(x, y):
    # умножение в GF(2^128), битовый порядок как в NIST SP 800-38D
    r = 0
    v = y
    for i in range(127, -1, -1):
        if (x >> i) & 1:
            r ^= v
        if v & 1:
            v = (v >> 1) ^ (0xE1 << 120)
        else:
            v >>= 1
    return r


def _ghash(h, data):
    y = 0
    for i in range(0, len(data), 16):
        block = data[i:i + 16].ljust(16, b"\0")
        y = _ghash_mult(y ^ int.from_bytes(block, "big"), h)
    return y


def aes_gcm_encrypt(key, iv, plaintext, aad=b""):
    """AES-256-GCM: возвращает ciphertext||tag (tag 16 байт). iv — 12 байт."""
    assert len(key) == 32 and len(iv) == 12
    rk = _expand_key(key)
    h = int.from_bytes(_encrypt_block(rk, b"\0" * 16), "big")
    j0 = iv + b"\x00\x00\x00\x01"

    ct = bytearray()
    counter = int.from_bytes(j0, "big")
    for i in range(0, len(plaintext), 16):
        counter += 1
        ks = _encrypt_block(rk, counter.to_bytes(16, "big"))
        chunk = plaintext[i:i + 16]
        ct += bytes(a ^ b for a, b in zip(chunk, ks))

    lens = (len(aad) * 8).to_bytes(8, "big") + (len(ct) * 8).to_bytes(8, "big")
    s = _ghash(h, aad.ljust((len(aad) + 15) // 16 * 16, b"\0") + bytes(ct).ljust((len(ct) + 15) // 16 * 16, b"\0") + lens) if (aad or ct) else _ghash(h, lens)
    tag_ks = _encrypt_block(rk, j0)
    tag = bytes(a ^ b for a, b in zip(s.to_bytes(16, "big"), tag_ks))
    return bytes(ct) + tag


PBKDF2_ITERATIONS = 150000


def encrypt_blob(pin, plaintext):
    """PIN -> PBKDF2-SHA256 -> AES-256-GCM. Возвращает dict для JSON."""
    import base64
    salt = os.urandom(16)
    iv = os.urandom(12)
    key = hashlib.pbkdf2_hmac("sha256", pin.encode(), salt, PBKDF2_ITERATIONS, 32)
    ct = aes_gcm_encrypt(key, iv, plaintext)
    return {
        "salt": base64.b64encode(salt).decode(),
        "iv": base64.b64encode(iv).decode(),
        "ct": base64.b64encode(ct).decode(),
        "iter": PBKDF2_ITERATIONS,
    }


if __name__ == "__main__":
    # NIST-вектор AES-256 (FIPS-197 C.3): проверка блочного шифра
    key = bytes(range(32))
    pt = bytes.fromhex("00112233445566778899aabbccddeeff")
    expect = "8ea2b7ca516745bfeafc49904b496089"
    got = _encrypt_block(_expand_key(key), pt).hex()
    assert got == expect, f"AES self-test FAILED: {got}"
    # NIST GCM вектор (256-бит ключ, пустой aad): из SP 800-38D test case 13/14
    key = b"\0" * 32
    iv = b"\0" * 12
    out = aes_gcm_encrypt(key, iv, b"")
    assert out.hex() == "530f8afbc74536b9a963b4f1c4cb738b", f"GCM tag FAILED: {out.hex()}"
    out2 = aes_gcm_encrypt(key, iv, b"\0" * 16)
    assert out2.hex() == "cea7403d4d606b6e074ec5d3baf39d18" + "d0d1c8a799996bf0265b98b5d48ab919", f"GCM ct FAILED: {out2.hex()}"
    print("aesgcm.py: self-test OK")
