// Package beebridge defines Zhiban's BeeBridge migration contracts.
package beebridge

import (
	"errors"
	"math/big"
	"regexp"
)

const MaxQuota int64 = 9007199254740991
const DefaultQuotaPerUSD int64 = 500000
const MaxQuotaPerUSD int64 = 1000000000

var ErrConversionConfig = errors.New("beebridge: CNY quota conversion is not configured")
var ErrGrantAmount = errors.New("beebridge: converted quota is outside supported range")
var ErrGrantCurrency = errors.New("beebridge: only CNY paid orders are supported")

// Conversion freezes the effective pricing and exact quota-per-CNY-cent ratio
// in an order. Old snapshots without pricing fields remain valid for recovery.
type Conversion struct {
	Version     string `json:"conversion_version"`
	Numerator   int64  `json:"quota_per_cent_numerator"`
	Denominator int64  `json:"quota_per_cent_denominator"`
	PricingID   int64  `json:"pricing_id,omitempty"`
	USDCNYRate  string `json:"usd_cny_rate,omitempty"`
	QuotaPerUSD int64  `json:"quota_per_usd,omitempty"`
}

type TopupPricing struct {
	ID          int64
	USDCNYRate  string
	QuotaPerUSD int64
}

var pricingRate = regexp.MustCompile(`^(0|[1-9]\d*)(\.\d{1,6})?$`)

func (p TopupPricing) Conversion() (Conversion, error) {
	rate, ok := new(big.Rat).SetString(p.USDCNYRate)
	if p.ID <= 0 || !pricingRate.MatchString(p.USDCNYRate) || !ok || rate.Sign() <= 0 || rate.Cmp(big.NewRat(1000, 1)) > 0 || p.QuotaPerUSD <= 0 || p.QuotaPerUSD > MaxQuotaPerUSD {
		return Conversion{}, ErrConversionConfig
	}
	ratio := new(big.Rat).Quo(big.NewRat(p.QuotaPerUSD, 100), rate)
	if !ratio.Num().IsInt64() || !ratio.Denom().IsInt64() {
		return Conversion{}, ErrConversionConfig
	}
	return Conversion{Version: "billing_pricing_v1", Numerator: ratio.Num().Int64(), Denominator: ratio.Denom().Int64(), PricingID: p.ID, USDCNYRate: p.USDCNYRate, QuotaPerUSD: p.QuotaPerUSD}, nil
}

type Grant struct {
	Rule            string `json:"rule"`
	EquivalentCents int64  `json:"equivalent_cents"`
	Conversion
	Rounding string `json:"rounding"`
}

// PaymentGrant keeps eligibility tied to the actual payment while allowing a
// subscription/upgrade to grant the configured display monthly amount once.
// A nil display amount preserves the paid-value rule; explicit zero grants nothing.
func PaymentGrant(amountCents int64, currency, orderType string, displayMonthlyCents *int64, conversion Conversion) (quota int64, grant Grant, eligible bool, err error) {
	if amountCents <= 0 || displayMonthlyCents == nil || (orderType != "subscription" && orderType != "upgrade") {
		return OriginalValueGrant(amountCents, currency, orderType, conversion)
	}
	quota, grant, eligible, err = OriginalValueGrant(*displayMonthlyCents, currency, orderType, conversion)
	if eligible {
		grant.Rule = "paid_display_monthly_v1"
	}
	return
}

// OriginalValueGrant grants 100% of the paid amount, rounded down only when
// converting to indivisible upstream quota. Zero/free or unsupported product
// orders are not eligible. Existing orders are never enrolled by this helper.
func OriginalValueGrant(amountCents int64, currency, orderType string, conversion Conversion) (quota int64, grant Grant, eligible bool, err error) {
	if amountCents < 0 {
		return 0, grant, false, ErrGrantAmount
	}
	if amountCents == 0 {
		return 0, grant, false, nil
	}
	switch orderType {
	case "subscription", "upgrade", "credit_pack":
	default:
		return 0, grant, false, nil
	}
	if currency != "CNY" {
		return 0, grant, false, ErrGrantCurrency
	}
	if conversion.Version == "" || conversion.Numerator <= 0 || conversion.Denominator <= 0 {
		return 0, grant, false, ErrConversionConfig
	}
	// Use big integers so an intermediate amount * ratio cannot overflow.
	q := new(big.Int).Mul(big.NewInt(amountCents), big.NewInt(conversion.Numerator))
	q.Quo(q, big.NewInt(conversion.Denominator))
	if !q.IsInt64() || q.Sign() <= 0 || q.Int64() > MaxQuota {
		return 0, grant, false, ErrGrantAmount
	}
	grant = Grant{Rule: "paid_original_value_v1", EquivalentCents: amountCents, Conversion: conversion, Rounding: "floor"}
	return q.Int64(), grant, true, nil
}
