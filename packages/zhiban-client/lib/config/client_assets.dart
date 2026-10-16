/// Shared resources have a single owner; App hosts load package assets.
class ClientAssets {
  ClientAssets._();

  static String? packageName = 'zhiban_client';

  static String path(String asset) =>
      packageName == null ? asset : 'packages/$packageName/$asset';
}
