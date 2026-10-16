import { existsSync } from 'node:fs';
import { dirname, delimiter, join } from 'node:path';

/** Keep runtime discovery separate from credentials and caller-controlled PATH. */
export function desktopEnvironment(home: string): NodeJS.ProcessEnv {
  if (process.platform !== 'win32') return { PATH: `${dirname(process.execPath)}:/usr/bin:/bin`, HOME: home, TMPDIR: home, TMPPREFIX: join(home, '.zsh-tmp') };
  const root = process.env['SystemRoot'] ?? 'C:\\Windows';
  return { SystemRoot: root, WINDIR: root, PATH: [dirname(process.execPath), join(root, 'System32'), join(root, 'System32/WindowsPowerShell/v1.0')].join(delimiter),
    HOME: home, USERPROFILE: home, TEMP: home, TMP: home, TMPDIR: home, LOCALAPPDATA: home, APPDATA: home };
}

export function desktopShell(command: string): string[] {
  if (process.platform !== 'win32') return ['/bin/zsh', '-f', '-c', command];
  return [join(process.env['SystemRoot'] ?? 'C:\\Windows', 'System32/WindowsPowerShell/v1.0/powershell.exe'), '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', command];
}

/**
 * Paths whose contents keep running after the granting session ends.
 *
 * Full access is sold as a temporary, revocable widening of this session (it is never persisted and
 * drops back to assist on restart). Writing a launch agent or a shell rc file escapes that time
 * boundary: revoking the permission, restarting the helper, or logging out cannot undo it. These are
 * denied outright — there is no per-task approval path (product decision Q1, 2026-09-12).
 */
export function persistenceDenyPaths(home: string): string[] {
  if (process.platform === 'win32') {
    const appData = process.env['APPDATA'] ?? join(home, 'AppData/Roaming');
    return [
      join(appData, 'Microsoft/Windows/Start Menu/Programs/Startup'),
      join(home, 'Documents/WindowsPowerShell'),
      join(home, 'Documents/PowerShell'),
    ];
  }
  return [
    join(home, 'Library/LaunchAgents'),
    join(home, 'Library/LaunchDaemons'),
    join(home, '.config/autostart'),
    join(home, '.zshrc'), join(home, '.zprofile'), join(home, '.zshenv'), join(home, '.zlogin'),
    join(home, '.bashrc'), join(home, '.bash_profile'), join(home, '.profile'),
  ];
}

export function desktopBrowser(): string | undefined {
  const paths = process.platform === 'darwin' ? ['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'] :
    [process.env['ProgramFiles'], process.env['ProgramFiles(x86)'], process.env['LOCALAPPDATA']].filter((p): p is string => !!p)
      .flatMap(root => [join(root, 'Google/Chrome/Application/chrome.exe'), join(root, 'Microsoft/Edge/Application/msedge.exe')]);
  return paths.find(existsSync);
}
