package runtime

import (
	"context"
	"sync"
)

// StreamEvent 是 Runtime 向 Bus 推送的增量事件。
type StreamEvent struct {
	Kind   string // delta / block / final / error / tool_call / tool_result
	Blocks []map[string]any
	Text   string
	Final  bool
	Err    error
}

// StreamRequest 是 Bus 发给 Runtime 的请求。
type StreamRequest struct {
	StreamID       string
	TenantID       int64
	AccountID      int64
	AgentUUID      string
	ConversationID int64
	SystemPrompt   string
	UserMessage    string
	UserBlocks     []map[string]any
	History        []HistoryMessage
	ModelHint      string
	ToolsAllowed   []string
	Metadata       map[string]any
}

// HistoryMessage 简化历史。
type HistoryMessage struct {
	Role   string
	Text   string
	Blocks []map[string]any
}

// Stream 是 Runtime 返回的事件流。close 时 channel 关闭。
type Stream interface {
	Recv() (StreamEvent, error)
	Close() error
}

// Adapter 是所有 Agent Runtime（OpenClaw / Hermes / 自建 / mock）的统一抽象。
type Adapter interface {
	Name() string
	HealthCheck(ctx context.Context) error
	Stream(ctx context.Context, req StreamRequest) (Stream, error)
}

// Manager 多 adapter 路由。
type Manager struct {
	mu          sync.RWMutex
	adapters    map[string]Adapter
	defaultName string
}

func NewManager(defaultName string) *Manager {
	return &Manager{adapters: map[string]Adapter{}, defaultName: defaultName}
}

func (m *Manager) Register(a Adapter) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.adapters[a.Name()] = a
}

func (m *Manager) Get(name string) (Adapter, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if name == "" {
		name = m.defaultName
	}
	a, ok := m.adapters[name]
	return a, ok
}

func (m *Manager) GetOrDefault(name string) Adapter {
	if a, ok := m.Get(name); ok {
		return a
	}
	a, _ := m.Get(m.defaultName)
	return a
}

func (m *Manager) List() []string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make([]string, 0, len(m.adapters))
	for k := range m.adapters {
		out = append(out, k)
	}
	return out
}
