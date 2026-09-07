package hashutil

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"io"
	"os"
)

// SHA256File returns hex-encoded SHA-256 of a file.
func SHA256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	return SHA256Reader(f)
}

// SHA256Reader streams SHA-256 from r.
func SHA256Reader(r io.Reader) (string, error) {
	h := sha256.New()
	if _, err := io.Copy(h, r); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// SHA256String hashes a string to hex.
func SHA256String(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

// RandomToken returns a URL-safe random token (nbytes random).
func RandomToken(nbytes int) (string, error) {
	b := make([]byte, nbytes)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// ShortHash returns first n hex chars of a hash (default 12).
func ShortHash(hexHash string, n int) string {
	if n <= 0 {
		n = 12
	}
	if len(hexHash) < n {
		return hexHash
	}
	return hexHash[:n]
}
