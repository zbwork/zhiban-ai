package install

import "context"

// packageRegistration retains one consent for exactly one verified MSIX.
// Closing it must also release the waiting elevated worker on failed downloads.
type packageRegistration interface {
	Register(context.Context) error
	Close()
}
