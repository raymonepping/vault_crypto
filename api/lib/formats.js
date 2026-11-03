// lib/formats.js — the three formats of the FF1 room and their checksums.
//
// FPE keeps a value's shape (length, alphabet, the parts the template leaves
// alone) but not its check digits: an encoded card number is 16 digits that
// usually fail Luhn. The room reports both facts separately and never
// pretends a checksum survived.

export const KINDS = {
  card: {
    label: "Card number",
    transformation: "ccn-legacy",
    shape: /^\d{4}-?\d{4}-?\d{4}-?\d{4}$|^\d{13,19}$/,
  },
  iban: {
    label: "Dutch IBAN",
    transformation: "iban-ff1",
    shape: /^NL\d{2}[A-Z]{4}\d{10}$/,
  },
  bsn: { label: "BSN", transformation: "bsn-ff1", shape: /^\d{9}$/ },
};

const digits = (s) => String(s).replace(/\D/g, "");

// Luhn (ISO/IEC 7812): card numbers.
export function luhn(value) {
  const d = digits(value);
  if (d.length < 12) return false;
  let sum = 0;
  for (let i = 0; i < d.length; i++) {
    let n = Number(d[d.length - 1 - i]);
    if (i % 2 === 1) {
      n *= 2;
      if (n > 9) n -= 9;
    }
    sum += n;
  }
  return sum % 10 === 0;
}

// ISO 13616 mod-97: move the first four characters to the end, letters to
// numbers (A=10 … Z=35), the remainder must be 1.
export function ibanMod97(value) {
  const s = String(value).replace(/\s/g, "").toUpperCase();
  if (!/^[A-Z]{2}\d{2}[A-Z0-9]{10,30}$/.test(s)) return false;
  const moved = s.slice(4) + s.slice(0, 4);
  let rem = 0;
  for (const ch of moved) {
    const v = /[A-Z]/.test(ch) ? String(ch.charCodeAt(0) - 55) : ch;
    for (const c of v) rem = (rem * 10 + Number(c)) % 97;
  }
  return rem === 1;
}

// Check digits for an IBAN body: country + "00" + BBAN → kk.
export function ibanCheckDigits(country, bban) {
  const moved = `${bban}${country}00`;
  let rem = 0;
  for (const ch of moved.toUpperCase()) {
    const v = /[A-Z]/.test(ch) ? String(ch.charCodeAt(0) - 55) : ch;
    for (const c of v) rem = (rem * 10 + Number(c)) % 97;
  }
  return String(98 - rem).padStart(2, "0");
}

// BSN "elfproef": 9·d1 + 8·d2 + … + 2·d8 − 1·d9 ≡ 0 (mod 11).
export function bsnElfproef(value) {
  const d = digits(value);
  if (d.length !== 9) return false;
  let sum = 0;
  for (let i = 0; i < 8; i++) sum += (9 - i) * Number(d[i]);
  sum -= Number(d[8]);
  return sum % 11 === 0 && Number(d) !== 0;
}

const CHECKS = { card: luhn, iban: ibanMod97, bsn: bsnElfproef };
export const CHECK_NAMES = { card: "Luhn", iban: "mod-97", bsn: "elfproef" };

// { shape, checksum, checksumName }: shape kept? checksum still valid?
export function formatCheck(kind, value) {
  const k = KINDS[kind];
  if (!k) throw new Error(`unknown kind: ${kind}`);
  return {
    shape: k.shape.test(String(value)),
    checksum: CHECKS[kind](value),
    checksumName: CHECK_NAMES[kind],
  };
}
