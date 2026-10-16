package catalog

// Trusted catalog signing keys per environment, keyed by kid. The private
// seed lives only in the Bus of that environment
// (AGBUS_LOCAL_CODING_CATALOG_SIGNING_KEY / _KEY_ID); rotating a key means
// adding the new public key here under a new kid, shipping the Bridge, and
// only then switching the Bus to the new seed. A kid that is not listed is
// never trusted, so a catalog signed by the wrong environment is ignored.
var trustedKeys = map[string]map[string]string{
	// Test Bus (aigc-chat-web.yixin.com). Generated 2026-09-10 for the F31
	// version catalog acceptance; the dev environment (a developer's own Bus)
	// shares it.
	EnvironmentTest: {
		"lc-catalog-test": "/KOB1uhcUYejDylsvVRfGaYMjxL0AE37ZovSPmrV9jI=",
	},
	EnvironmentDev: {
		"lc-catalog-test": "/KOB1uhcUYejDylsvVRfGaYMjxL0AE37ZovSPmrV9jI=",
	},
	// Production: no key has been provisioned yet, so a production App gets
	// no catalog and installs the built-in manifest versions.
	EnvironmentProd: {
		// 2026-09-11 生成；私钥种子只在 Bus 生产环境变量 AGBUS_LOCAL_CODING_CATALOG_SIGNING_KEY。
		"lc-catalog-prod": "+nuHiIH14glor72cYVQSzUxKgTYvPMrSnAgEYIBZx9M=",
	},
}

// PublicKeys returns the trusted keys (kid → base64 public key) for an
// environment; nil for an unknown environment. The map is a copy.
func PublicKeys(environment string) map[string]string {
	keys, ok := trustedKeys[environment]
	if !ok {
		return nil
	}
	copied := make(map[string]string, len(keys))
	for kid, key := range keys {
		copied[kid] = key
	}
	return copied
}
