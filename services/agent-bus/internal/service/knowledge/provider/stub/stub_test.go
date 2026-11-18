package stub

import (
	"slices"
	"strings"
	"testing"
)

func TestHanPhrasesFindsSharedTextInQuestion(t *testing.T) {
	phrases := hanPhrases("请问验收代号是什么？")
	if !slices.Equal(phrases, []string{"验收代号"}) {
		t.Fatalf("missing literal phrase: %v", phrases)
	}
	if got := hanPhrases("验收，代号 ABC"); len(got) != 0 {
		t.Fatalf("phrase crossed punctuation or Latin text: %v", got)
	}
	if got := len(hanPhrases(strings.Repeat("验收代号", 100))); got != 4 {
		t.Fatalf("expected four distinct phrases, got %d", got)
	}
}
