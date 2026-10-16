// config.go — F03 v0.9.1 §11 环境变量。
//
// 集中读取 F03 需要的可调参数，缺省值与 spec 一致。
// 仅在进程启动时调用一次 LoadConfig()；运行期通过 svc.Config() 拿快照。
package skill

import (
	"os"
	"strconv"
	"strings"
	"time"
)

// Config — F03 v0.9.1 §11 配置快照。
type Config struct {
	// bus 进程
	SkillRailConfigTTL         time.Duration // AGBUS_SKILL_RAIL_CONFIG_TTL
	SkillParamsMaxBytes        int           // AGBUS_SKILL_PARAMS_MAX_BYTES
	BuiltinHandshakeTTL        time.Duration // AGBUS_BUILTIN_SKILL_HANDSHAKE_TTL
	SkillRailConfigSSEDebounce time.Duration // AGBUS_SKILL_RAIL_CONFIG_SSE_DEBOUNCE

	// admin / 共享
	SkillPackageMaxBytes      int64         // AGBUS_SKILL_PACKAGE_MAX_BYTES
	SkillPackageCDNURLTTL     time.Duration // AGBUS_SKILL_PACKAGE_CDN_URL_TTL
	SkillPackageScanTimeout   time.Duration // AGBUS_SKILL_PACKAGE_UPLOAD_SCAN_TIMEOUT
	PublishGrayscaleDefault   int           // AGBUS_SKILL_PUBLISH_GRAYSCALE_DEFAULT
	InstallCountWorkerBatchIv time.Duration // AGBUS_INSTALL_COUNT_WORKER_BATCH_INTERVAL
}

// LoadConfig 从 env 读取 F03 配置；空值走 spec §11 默认。
func LoadConfig() Config {
	return Config{
		SkillRailConfigTTL:         envDuration("AGBUS_SKILL_RAIL_CONFIG_TTL", 5*time.Minute),
		SkillParamsMaxBytes:        envInt("AGBUS_SKILL_PARAMS_MAX_BYTES", 16*1024),
		BuiltinHandshakeTTL:        envDuration("AGBUS_BUILTIN_SKILL_HANDSHAKE_TTL", 24*time.Hour),
		SkillRailConfigSSEDebounce: envDuration("AGBUS_SKILL_RAIL_CONFIG_SSE_DEBOUNCE", 500*time.Millisecond),
		SkillPackageMaxBytes:       int64(envInt("AGBUS_SKILL_PACKAGE_MAX_BYTES", 50*1024*1024)),
		SkillPackageCDNURLTTL:      envDuration("AGBUS_SKILL_PACKAGE_CDN_URL_TTL", time.Hour),
		SkillPackageScanTimeout:    envDuration("AGBUS_SKILL_PACKAGE_UPLOAD_SCAN_TIMEOUT", 30*time.Second),
		PublishGrayscaleDefault:    envInt("AGBUS_SKILL_PUBLISH_GRAYSCALE_DEFAULT", 100),
		InstallCountWorkerBatchIv:  envDuration("AGBUS_INSTALL_COUNT_WORKER_BATCH_INTERVAL", 60*time.Second),
	}
}

func envInt(key string, def int) int {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func envDuration(key string, def time.Duration) time.Duration {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return def
}

// SetConfig / Config 让 Service 持有一份只读快照。
func (s *Service) SetConfig(c Config) { s.cfg = c }
func (s *Service) Config() Config     { return s.cfg }
