package downloadchannel

import "testing"

func TestMaskPhone(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want string
	}{
		{name: "mainland", in: "13800138000", want: "138****8000"},
		{name: "international", in: "+8613800138000", want: "+86****8000"},
		{name: "short", in: "12345", want: "*****"},
		{name: "empty", in: "", want: ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := maskPhone(tt.in); got != tt.want {
				t.Fatalf("maskPhone(%q) = %q, want %q", tt.in, got, tt.want)
			}
		})
	}
}
