package metrics

import "expvar"

var (
	a2aInvokeTotal = expvar.NewInt("a2a_invoke_total")
	a2aRejectTotal = expvar.NewMap("a2a_reject_total")
)

func IncA2AInvoke() {
	a2aInvokeTotal.Add(1)
}

func IncA2AReject(reason string) {
	if reason == "" {
		reason = "unknown"
	}
	a2aRejectTotal.Add(reason, 1)
}
