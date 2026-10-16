package metrics

import "expvar"

// 计费用量监控计数器（expvar，经 /debug/vars 暴露，与 a2a.go 同风格）。
// 不记录 prompt/response/api key，只记可计数的运营指标。
var (
	billingChargeFailed    = expvar.NewInt("billing_charge_failed_total") // 余额不足/透支超限等
	billingRTCChargeFailed = expvar.NewInt("billing_rtc_charge_failed_total")
	billingReconcile       = expvar.NewMap("billing_reconcile_total") // by outcome: processed/succeeded/failed/manual
)

// IncBillingChargeFailed 累计扣费失败（charge_failed）次数。
func IncBillingChargeFailed() { billingChargeFailed.Add(1) }

// IncRTCChargeFailed 累计 RTC 分钟扣费失败次数。
func IncRTCChargeFailed() { billingRTCChargeFailed.Add(1) }

// IncReconcile 按结果累计对账补偿处理次数（processed/succeeded/failed/manual）。
func IncReconcile(outcome string) {
	if outcome == "" {
		outcome = "processed"
	}
	billingReconcile.Add(outcome, 1)
}
