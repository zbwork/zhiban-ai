package agent

// ConversationCapabilities contains only safe, client-facing runtime metadata.
type ConversationCapabilities struct {
	ExecutionLocus         string `json:"execution_locus"`
	LocalEngine            string `json:"local_engine,omitempty"`
	SupportsModelSelection bool   `json:"supports_model_selection"`
	ModelSource            string `json:"model_source"`
	ModelServiceModelID    string `json:"model_service_model_id,omitempty"`
}
