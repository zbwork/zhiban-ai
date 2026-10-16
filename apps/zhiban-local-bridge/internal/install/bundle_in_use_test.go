package install

import (
	"errors"
	"path/filepath"
	"reflect"
	"testing"
)

// 2026-09-20 回归:Windows 桌面端是应用包,资产没有 BundleName。按"应用名逐个检查"
// (7baae83e,为 macOS 的 Codex.app / ChatGPT.app 而改)拼出来的路径成了整个
// WindowsApps 目录,任何在跑的商店应用(终端、记事本、小组件)都被算成"目标正在使用",
// 经知办安装 / 升级桌面端在 Windows 上必报 TARGET_IN_USE。
func TestBundleInUseChecksOnlyTheTargetItself(t *testing.T) {
	t.Parallel()
	apps := filepath.Join(t.TempDir(), "WindowsApps")
	applications := filepath.Join(t.TempDir(), "Applications")
	tests := []struct {
		name  string
		asset Asset
		paths layout
		want  []string
	}{
		{
			name:  "a Windows package has no bundle name: its registered folder, never the folder of every Store app",
			asset: Asset{TargetID: TargetClaudeDesktop, PackageName: "Claude", PackagePublisherID: "pzs8sxrjxfjjc"},
			paths: layout{baseDir: apps, fileName: "Claude_1.49585.0.0_x64__pzs8sxrjxfjjc", bundle: true},
			want:  []string{filepath.Join(apps, "Claude_1.49585.0.0_x64__pzs8sxrjxfjjc")},
		},
		{
			name:  "a macOS bundle is checked under every name it may carry",
			asset: Asset{TargetID: TargetCodexDesktop, BundleName: "Codex.app", BundleAliases: []string{"ChatGPT.app"}},
			paths: layout{baseDir: applications, fileName: "Codex.app", bundle: true},
			want:  []string{filepath.Join(applications, "Codex.app"), filepath.Join(applications, "ChatGPT.app")},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var checked []string
			m := &Manager{bundleTools: BundleTools{BundleInUse: func(path string) (bool, error) {
				checked = append(checked, path)
				return false, nil
			}}}
			if err := m.bundleInUse(test.asset, test.paths); err != nil {
				t.Fatalf("bundleInUse() error = %v", err)
			}
			if !reflect.DeepEqual(checked, test.want) {
				t.Fatalf("checked %v, want %v", checked, test.want)
			}
		})
	}
}

// 检查本身没做成(PowerShell 超时、被安全软件拦)不等于"正在运行":用户会去找一个
// 不存在的进程。仍然不放行安装,但要如实报。
func TestBundleInUseTellsAFailedCheckFromARunningTarget(t *testing.T) {
	t.Parallel()
	asset := Asset{TargetID: TargetClaudeDesktop, BundleName: "Claude.app"}
	paths := layout{baseDir: filepath.Join(t.TempDir(), "Applications"), fileName: "Claude.app", bundle: true}

	running := &Manager{bundleTools: BundleTools{BundleInUse: func(string) (bool, error) { return true, nil }}}
	if err := running.bundleInUse(asset, paths); !errors.Is(err, errTargetInUse) || errors.Is(err, errRunningCheckFailed) {
		t.Fatalf("running target error = %v", err)
	}
	broken := &Manager{bundleTools: BundleTools{BundleInUse: func(string) (bool, error) { return false, errors.New("process enumeration timed out") }}}
	if err := broken.bundleInUse(asset, paths); !errors.Is(err, errRunningCheckFailed) || errors.Is(err, errTargetInUse) {
		t.Fatalf("failed check error = %v", err)
	}
}
