const CLIENT_RELEASE_VERSION = /^(0|[1-9][0-9]*)\.[0-9]\.[0-9]$/

export function clientReleaseVersionError(version: string): string | null {
  if (CLIENT_RELEASE_VERSION.test(version.trim())) return null
  return '版本号须为 X.Y.Z，次版本和修订版本各只能为 0–9，例如 1.4.9；不可填写 1.4.10'
}
