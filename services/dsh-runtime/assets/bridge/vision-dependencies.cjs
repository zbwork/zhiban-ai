// Shared by the host grants and the fixed Windows image decoder only.
// Revalidate transitive dependencies when upgrading the locked image packages.
module.exports = ['image-size', 'queue', 'inherits', '@napi-rs/canvas', `@napi-rs/canvas-win32-${process.arch}-msvc`];
