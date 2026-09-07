package ids

import (
	"crypto/rand"
	"time"

	"github.com/oklog/ulid/v2"
)

// New returns a new ULID string.
func New() string {
	entropy := ulid.Monotonic(rand.Reader, 0)
	return ulid.MustNew(ulid.Timestamp(time.Now().UTC()), entropy).String()
}
