// Sealing for things the app holds but only this PC can read: AES-256-GCM with TOKEN_KEY (.env).
// "v1." + base64url(iv 12 | tag 16 | ciphertext). Used for Spotify's refresh token and for the
// app key that opens the routes endpoints.
'use strict';

const crypto = require('crypto');

function seal(plain, key) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const body = Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()]);
  return 'v1.' + Buffer.concat([iv, cipher.getAuthTag(), body]).toString('base64url');
}

/** The plain text, or null if it isn't one of ours (or was tampered with). */
function open(sealed, key) {
  if (typeof sealed !== 'string' || !sealed.startsWith('v1.') || !key) return null;
  const raw = Buffer.from(sealed.slice(3), 'base64url');
  if (raw.length < 29) return null;
  try {
    const decipher = crypto.createDecipheriv('aes-256-gcm', key, raw.subarray(0, 12));
    decipher.setAuthTag(raw.subarray(12, 28));
    return Buffer.concat([decipher.update(raw.subarray(28)), decipher.final()]).toString('utf8');
  } catch {
    return null;
  }
}

module.exports = { seal, open };
