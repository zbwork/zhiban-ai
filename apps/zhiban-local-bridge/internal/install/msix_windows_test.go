//go:build windows

package install

import (
	"fmt"
	"testing"
)

func TestAppxManifestDetectsServiceElevation(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name, capabilities string
		want               bool
	}{
		{"old Codex", `<rescap:Capability Name="runFullTrust"/><Capability Name="internetClient"/>`, false},
		{"packaged service", `<rescap:Capability Name="packagedServices"/>`, true},
		{"local system service", `<rescap:Capability Name="localSystemServices"/>`, true},
		{"Codex sandbox service", `<rescap:Capability Name="packagedServices"/><rescap:Capability Name="localSystemServices"/>`, true},
		{"unrelated capability", `<rescap:Capability Name="unvirtualizedResources"/>`, false},
		{"similar name", `<rescap:Capability Name="packagedServicesOther"/>`, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			xml := fmt.Sprintf(`<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"><Identity Name="OpenAI.Codex" Publisher="CN=Publisher" Version="26.930.7945.0" ProcessorArchitecture="x64"/><Applications><Application Id="App"/></Applications><Capabilities>%s</Capabilities></Package>`, test.capabilities)
			identity, err := parseAppxManifest([]byte(xml))
			if err != nil {
				t.Fatal(err)
			}
			if identity.RequiresElevation != test.want {
				t.Fatalf("RequiresElevation = %v, want %v", identity.RequiresElevation, test.want)
			}
			if identity.Name != "OpenAI.Codex" || identity.Version != "26.930.7945.0" || identity.AppID != "App" {
				t.Fatalf("identity changed: %+v", identity)
			}
		})
	}
}
