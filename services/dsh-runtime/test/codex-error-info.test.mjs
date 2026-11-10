import test from 'node:test';
import assert from 'node:assert/strict';
import { errorInfo } from '../assets/bridge/codex-error-info.mjs';

test('Codex error diagnostics retain only known missing fields and fixed categories', () => {
  const result = errorInfo({codexErrorInfo:{responseStreamDisconnected:{httpStatusCode:502}},message:'stream disconnected parse missing field `id` and missing field "output" missing field `id` SECRET https://secret.example TOKEN'});
  assert.deepEqual(result,{missing_fields:['id','output'],kind:'responseStreamDisconnected',terms:['parse','missing','stream disconnected'],http_status:502,reason:'stream_response'});
  assert.equal(JSON.stringify(result).includes('SECRET'),false);
});

test('unknown fields and arbitrary errors cannot leak via diagnostics', () => {
  const result = errorInfo({codexErrorInfo:{sensitiveKind:{httpStatusCode:999}},message:'missing field `secret_token` missing field `user_email` SECRET'});
  assert.deepEqual(result,{kind:'other',terms:['missing'],reason:'unknown'});
  assert.equal(errorInfo(null).kind,'other');
});
