package clientim

import (
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/im/wukong"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/imconnection"
)

type Handlers struct {
	WuKongCred           *wukong.CredentialIssuer
	IMConnectionMetadata *imconnection.MetadataReporter
}
