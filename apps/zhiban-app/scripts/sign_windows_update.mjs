// Windows Ed25519 update signatures; uses only the bundled Node crypto library.
import { createPrivateKey, createPublicKey, sign, verify } from 'node:crypto';
import { readFileSync } from 'node:fs';
try {
  const [artifact, keyFile, publicKeyFile] = process.argv.slice(2);
  if (!artifact || !keyFile || !publicKeyFile) throw new Error('Expected artifact, private key and public key paths');
  const privateKey = createPrivateKey(readFileSync(keyFile));
  if (privateKey.asymmetricKeyType !== 'ed25519') throw new Error('An Ed25519 private key is required');
  const publicKey = createPublicKey(privateKey);
  const rawPublic = publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('base64');
  if (rawPublic !== readFileSync(publicKeyFile, 'utf8').trim()) throw new Error('Signing key does not match the Windows client public key');
  const bytes = readFileSync(artifact);
  const signature = sign(null, bytes, privateKey);
  if (!verify(null, bytes, publicKey, signature)) throw new Error('Signature verification failed');
  console.log(`sparkle:edSignature="${signature.toString('base64')}" length="${bytes.length}"`);
} catch (error) {
  // Never print key contents or crypto parser stacks.
  console.error(`Windows update signing failed: ${error.code ?? error.message}`);
  process.exitCode = 1;
}
