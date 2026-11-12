package localcodingcatalog

import (
	"archive/zip"
	"encoding/binary"
	"encoding/xml"
	"errors"
	"io"
	"strings"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localcodingcatalog"
	"howett.net/plist"
)

func desktopZipMember(z *zip.Reader, name string) (*zip.File, error) {
	var found *zip.File
	for _, f := range z.File {
		if f.Name == name {
			if found != nil {
				return nil, errors.New("安装包包含重复元数据")
			}
			found = f
		}
	}
	if found == nil || !found.Mode().IsRegular() {
		return nil, errors.New("安装包缺少有效元数据文件")
	}
	return found, nil
}

func desktopZipBytes(z *zip.Reader, name string) ([]byte, error) {
	f, err := desktopZipMember(z, name)
	if err != nil {
		return nil, err
	}
	if f.UncompressedSize64 > uint64(desktopMetadataMax) {
		return nil, errors.New("安装包元数据过大")
	}
	r, err := f.Open()
	if err != nil {
		return nil, err
	}
	defer r.Close()
	b, err := io.ReadAll(io.LimitReader(r, desktopMetadataMax+1))
	if err != nil || int64(len(b)) > desktopMetadataMax {
		return nil, errors.New("安装包元数据不完整或校验失败")
	}
	return b, nil
}

func desktopMSIXVersion(z *zip.Reader, target, arch string) (string, error) {
	b, err := desktopZipBytes(z, "AppxManifest.xml")
	if err != nil {
		return "", err
	}
	var doc struct {
		XMLName    xml.Name `xml:"http://schemas.microsoft.com/appx/manifest/foundation/windows10 Package"`
		Identities []struct {
			Name    string `xml:"Name,attr"`
			Version string `xml:"Version,attr"`
			Arch    string `xml:"ProcessorArchitecture,attr"`
		} `xml:"http://schemas.microsoft.com/appx/manifest/foundation/windows10 Identity"`
	}
	if xml.Unmarshal(b, &doc) != nil || len(doc.Identities) != 1 {
		return "", errors.New("MSIX 包清单无效")
	}
	id := doc.Identities[0]
	name := "OpenAI.Codex"
	if target == dom.TargetClaudeDesktop {
		name = "Claude"
	}
	parts := strings.Split(id.Version, ".")
	if id.Name != name || id.Arch != arch || len(parts) != 4 || parts[3] != "0" {
		return "", errors.New("MSIX 身份、架构或版本 revision 不符合要求")
	}
	v := strings.Join(parts[:3], ".")
	if !releaseVersionPattern.MatchString(v) {
		return "", errors.New("MSIX 版本无效")
	}
	return v, nil
}

func inspectDesktopArchive(d *downloaded, p *DesktopPackage) error {
	z, err := zip.NewReader(d.file, d.size)
	if err != nil {
		return errors.New("安装包不是有效 ZIP/MSIX")
	}
	return inspectDesktopZip(z, p)
}

func inspectDesktopZip(z *zip.Reader, p *DesktopPackage) error {
	if len(z.File) > 200000 {
		return errors.New("安装包文件条目过多")
	}
	if p.Platform == dom.PlatformWindows {
		version, err := desktopMSIXVersion(z, p.TargetID, p.Arch)
		if err != nil {
			return err
		}
		if version != p.Version {
			return errors.New("MSIX 实际版本与发现版本不一致")
		}
		return nil
	}
	var infoName string
	for _, f := range z.File {
		if strings.HasSuffix(f.Name, ".app/Contents/Info.plist") && strings.Count(f.Name, "/") == 2 {
			if infoName != "" {
				return errors.New("Mac 安装包包含多个主应用")
			}
			infoName = f.Name
		}
	}
	b, err := desktopZipBytes(z, infoName)
	if err != nil {
		return err
	}
	var info struct {
		BundleID   string `plist:"CFBundleIdentifier"`
		Version    string `plist:"CFBundleShortVersionString"`
		Executable string `plist:"CFBundleExecutable"`
	}
	if _, err := plist.Unmarshal(b, &info); err != nil {
		return errors.New("Mac Info.plist 无效")
	}
	if info.BundleID != p.BundleIdentifier || info.Version != p.Version || info.Executable == "" || strings.ContainsAny(info.Executable, "/\\:") || info.Executable == "." || info.Executable == ".." {
		return errors.New("Mac 安装包身份、版本或程序名不匹配")
	}
	f, err := desktopZipMember(z, strings.TrimSuffix(infoName, "Info.plist")+"MacOS/"+info.Executable)
	if err != nil {
		return err
	}
	r, err := f.Open()
	if err != nil {
		return err
	}
	defer r.Close()
	header := make([]byte, 4096)
	n, err := io.ReadFull(r, header)
	if err != nil && err != io.ErrUnexpectedEOF {
		return errors.New("无法读取 Mac 程序架构")
	}
	if !desktopMachOSupports(header[:n], p.Arch) {
		return errors.New("Mac 程序不支持目录声明的架构")
	}
	return nil
}

func desktopMachOSupports(b []byte, arch string) bool {
	if len(b) < 8 {
		return false
	}
	want := uint32(0x0100000c)
	if arch == dom.ArchX64 {
		want = 0x01000007
	} else if arch != dom.ArchArm64 {
		return false
	}
	magic := binary.BigEndian.Uint32(b)
	switch magic {
	case 0xcffaedfe:
		return binary.LittleEndian.Uint32(b[4:]) == want
	case 0xfeedfacf:
		return binary.BigEndian.Uint32(b[4:]) == want
	case 0xcafebabe, 0xcafebabf:
		count := binary.BigEndian.Uint32(b[4:])
		step := 20
		if magic == 0xcafebabf {
			step = 32
		}
		if count > 32 || len(b) < 8+int(count)*step {
			return false
		}
		for i := 0; i < int(count); i++ {
			if binary.BigEndian.Uint32(b[8+i*step:]) == want {
				return true
			}
		}
	}
	return false
}
