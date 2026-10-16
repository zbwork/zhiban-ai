'use strict';
// AppContainer has no loopback/network exemption. Route only the authenticated
// local broker socket through its ACL-protected named pipe; OS denies other I/O.
const net = require('node:net');
const original = net.Socket.prototype.connect;
const pipe = process.env.LOCAL_AGENT_BROKER_PIPE;
const port = Number(process.env.LOCAL_AGENT_BROKER_PORT);
if (process.platform === 'win32' && pipe && pipe.startsWith('\\\\.\\pipe\\LOCAL\\ZhiBan-') && port > 0 && port <= 65535) {
  const fs = require('node:fs');
  const fsp = require('node:fs/promises');
  const { URL, fileURLToPath, pathToFileURL } = require('node:url');
  const { Buffer } = require('node:buffer');
  const { resolve, toNamespacedPath } = require('node:path');
  const native = require('../../native/zhiban-windows-path.node');
  const canonical = (path, options) => {
    const input = path instanceof URL ? fileURLToPath(path) : Buffer.isBuffer(path) ? path.toString() : path;
    if (typeof input !== 'string') throw new TypeError('path must be a string, Buffer or file URL');
    const value = native.realpath(toNamespacedPath(resolve(input)));
    const encoding = typeof options === 'string' ? options : options?.encoding;
    return encoding === 'buffer' ? Buffer.from(value) : encoding && encoding !== 'utf8' ? Buffer.from(value).toString(encoding) : value;
  };
  const fallback = (error, path, options) => {
    if (!['EPERM', 'EACCES'].includes(error.code)) throw error;
    return canonical(path, options);
  };
  const originalSync = fs.realpathSync;
  const originalNative = fs.realpathSync.native;
  fs.realpathSync = (path, options) => { try { return originalSync(path, options); } catch (error) { return fallback(error, path, options); } };
  fs.realpathSync.native = (path, options) => { try { return originalNative(path, options); } catch (error) { return fallback(error, path, options); } };
  const wrapCallback = (original) => (path, options, callback) => {
    if (typeof options === 'function') { callback = options; options = undefined; }
    if (typeof callback !== 'function') throw new TypeError('callback must be a function');
    original(path, options, (error, value) => {
      if (!error) return callback(null, value);
      let result;
      try { result = fallback(error, path, options); } catch (failure) { return callback(failure); }
      callback(null, result);
    });
  };
  const originalCallback = fs.realpath;
  fs.realpath = wrapCallback(originalCallback);
  fs.realpath.native = wrapCallback(originalCallback.native);
  const originalPromise = fsp.realpath;
  fsp.realpath = async (path, options) => {
    try { return await originalPromise(path, options); } catch (error) { return fallback(error, path, options); }
  };
  require('node:module').syncBuiltinESMExports();
  // Use Node's public synchronous loader hook to restore canonical module
  // identity after bootstrapping with preserve-symlinks. CJS dependencies must
  // resolve from the real package tree, including dev/cache junction layouts.
  require('node:module').registerHooks({ resolve(specifier, context, nextResolve) {
    const result = nextResolve(specifier, context);
    if (result.url.startsWith('file:')) {
      const source = new URL(result.url);
      const target = pathToFileURL(fs.realpathSync.native(source));
      target.search = source.search; target.hash = source.hash;
      return { ...result, url: target.href };
    }
    return result;
  } });
  net.Socket.prototype.connect = function (...args) {
    // net.connect uses Node's normalized [options, callback] tuple.
    const tuple = Array.isArray(args[0]) ? args[0] : args;
    const option = tuple[0];
    const host = typeof option === 'object' ? option.host : typeof tuple[1] === 'string' ? tuple[1] : 'localhost';
    const requested = Number(typeof option === 'object' ? option.port : option);
    if (requested === port && ['127.0.0.1', 'localhost', '::1'].includes(host || 'localhost')) {
      const callback = tuple.find(value => typeof value === 'function');
      return original.call(this, { path: pipe }, ...(callback ? [callback] : []));
    }
    return original.apply(this, args);
  };
}
