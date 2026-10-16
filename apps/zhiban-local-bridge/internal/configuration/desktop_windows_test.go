//go:build windows

package configuration

import "testing"

// Windows 12016 真机：Codex 桌面端是 ChatGPT 的 MSIX 包，包内二进制不能直接执行
// （普通用户 exec 报「拒绝访问」），所以切换不跑内嵌内核探针，也不能因为「找不到
// 内核」把切换判成 INSTALLATION_CHANGED——CLI 切换已成功，用户却看到报错。
func TestCodexDesktopSkipsTheBundledCoreOnWindows(t *testing.T) {
	t.Parallel()
	if core, required := desktopCodexCore(`C:\Program Files\WindowsApps\OpenAI.Codex_26.908.4834.0_x64__2p2nqsd0c76g0`); core != "" || required {
		t.Fatalf("desktopCodexCore = %q, %v", core, required)
	}
	installation, err := desktopProbeInstallation(Installation{
		TargetID:   TargetCodexDesktop,
		Executable: `C:\Program Files\WindowsApps\OpenAI.Codex_26.908.4834.0_x64__2p2nqsd0c76g0`,
	})
	if err != nil || installation.Executable != "" {
		t.Fatalf("desktopProbeInstallation = %+v, %v", installation, err)
	}
	if err := (&Manager{}).probeGlobal(nil, installation); err != nil {
		t.Fatalf("probeGlobal with nothing to run = %v", err)
	}
}
